import 'dart:io';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
// 🛠️ INYECTADO: Backend FFI Nativo
import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;
import 'pipeline_provider.dart';
import 'db_provider.dart'; // 🛠️ FIX: Enlace al controlador de ISAR

final dspWorkerProvider = Provider((ref) => DspWorker(ref));

class DspWorker {
  final Ref ref;
  DspWorker(this.ref);

  // 🛠️ PARSER BINARIO ID3v2 (Alta Velocidad - Sin dependencias externas)
  Future<double> _extractBpmFromID3(String filePath) async {
    try {
      final file = File(filePath);
      final raf = await file.open();
      final header = await raf.read(10);

      if (header.length < 10 ||
          header[0] != 0x49 ||
          header[1] != 0x44 ||
          header[2] != 0x33) {
        await raf.close();
        return 0.0;
      }

      final size =
          (header[6] << 21) | (header[7] << 14) | (header[8] << 7) | header[9];
      final tagData = await raf.read(size);
      await raf.close();

      for (int i = 0; i < tagData.length - 10; i++) {
        if (tagData[i] == 0x54 &&
            tagData[i + 1] == 0x42 &&
            tagData[i + 2] == 0x50 &&
            tagData[i + 3] == 0x4D) {
          // 'TBPM'
          final frameSize =
              (tagData[i + 4] << 24) |
              (tagData[i + 5] << 16) |
              (tagData[i + 6] << 8) |
              tagData[i + 7];
          if (frameSize > 0 && i + 10 + frameSize <= tagData.length) {
            final bpmStringBytes = tagData.sublist(i + 11, i + 10 + frameSize);
            final rawString = String.fromCharCodes(
              bpmStringBytes,
            ).replaceAll(RegExp(r'[^\d.]'), '');
            return double.tryParse(rawString) ?? 0.0;
          }
        }
      }
      return 0.0;
    } catch (e) {
      return 0.0;
    }
  }

  // 🛠️ GENERADOR DE CACHÉ ESTÁTICO (Escritura Atómica basada en Timestamps)
  Future<void> generateStaticBpmCache(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final cacheFile = File(
      '$directoryPath${Platform.pathSeparator}_dj_metadata.json',
    );
    final tempCache = File(
      '$directoryPath${Platform.pathSeparator}_dj_metadata.tmp',
    );
    final timeFile = File(
      '$directoryPath${Platform.pathSeparator}_dj_timestamps.json',
    );
    final tempTime = File(
      '$directoryPath${Platform.pathSeparator}_dj_timestamps.tmp',
    );

    Map<String, double> cacheData = {};
    Map<String, int> timestamps = {};

    if (cacheFile.existsSync()) {
      try {
        final content = await cacheFile.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        decoded.forEach((k, v) => cacheData[k] = (v as num).toDouble());
      } catch (_) {}
    }

    if (timeFile.existsSync()) {
      try {
        final content = await timeFile.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        decoded.forEach((k, v) => timestamps[k] = (v as num).toInt());
      } catch (_) {}
    }

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .toList();
    bool hasChanges = false;

    for (var file in files) {
      final filename = file.uri.pathSegments.last;
      final modified = file.lastModifiedSync().millisecondsSinceEpoch;

      // Evalúa si el archivo es nuevo o modificado antes de procesarlo
      if (!timestamps.containsKey(filename) ||
          timestamps[filename] != modified) {
        debugPrint("⚙️ [DSP Cache] Escaneando binario ID3: $filename");
        final bpm = await _extractBpmFromID3(file.path);

        if (bpm > 0) {
          cacheData[filename] = bpm;
        } else {
          final match = RegExp(
            r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
            caseSensitive: false,
          ).firstMatch(filename);
          if (match != null) {
            cacheData[filename] = double.parse(match.group(1)!);
          }
        }

        timestamps[filename] = modified;
        hasChanges = true;
      }
    }

    // Patrón Transaccional: Renombrado atómico para evitar corrupción si el sistema colapsa
    if (hasChanges) {
      await tempCache.writeAsString(jsonEncode(cacheData));
      await tempCache.rename(cacheFile.path);

      await tempTime.writeAsString(jsonEncode(timestamps));
      await tempTime.rename(timeFile.path);
      debugPrint("🟢 [DSP Cache] Caché estático actualizado atómicamente.");
    } else {
      debugPrint("🟢 [DSP Cache] Sin cambios físicos. Caché mantenido.");
    }
  }

  // 🛠️ MOTOR DE PROCESAMIENTO MÚLTIPLE (Orquestador Rust)
  Future<void> _runRustBatch(
    String directoryPath,
    String moduleName,
    Future<bool> Function(String) rustTask, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .toList();

    int total = files.length;
    final pipe = ref.read(pipelineProvider.notifier);

    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [DSP Worker] Proceso abortado.");
        break;
      }

      final file = files[i];
      final filename = file.uri.pathSegments.last;
      pipe.updateProgress(i + 1, total, filename, moduleName);

      try {
        final success = await rustTask(file.path);
        if (!success) {
          pipe.addQuarantine(filename);
        }
      } catch (e) {
        pipe.updateProgress(i + 1, total, "⚠️ Error DSP", moduleName);
        pipe.addQuarantine(filename);
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
    }
    // 🛠️ FIX ARQUITECTURA: Se mantiene la regla original, sin pipe.reset()
  }

  Future<void> processEBU(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    await _runRustBatch(
      directoryPath,
      "Master LUFS",
      (path) => rust_dsp.normalizeLufs(inputPath: path),
      isCancelled: isCancelled,
    );
  }

  Future<void> processTrim(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    await _runRustBatch(
      directoryPath,
      "DSP Trim",
      (path) => rust_dsp.processAutoTrim(inputPath: path),
      isCancelled: isCancelled,
    );
  }

  // 🛠️ MOTOR DE PURGA 1: Exclusivo para Infraestructura Física (Metadatos ID3)
  Future<void> clearPipelineWatermarks(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    await _runRustBatch(
      directoryPath,
      "♻️ Reset Watermark",
      (path) => rust_dsp.clearWatermark(inputPath: path),
      isCancelled: isCancelled,
    );
    debugPrint("🟢 [DSP Worker] Sellos físicos eliminados en C++.");
  }

  // 🛠️ MOTOR DE PURGA 2: Exclusivo para Base de Datos (Curvas, Set In/Out)
  Future<void> clearIsarDspData(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .toList();

    int total = files.length;
    final pipe = ref.read(pipelineProvider.notifier);

    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [DSP Worker] Purga ISAR abortada.");
        break;
      }

      final file = files[i];
      final filename = file.uri.pathSegments.last;
      pipe.updateProgress(i + 1, total, filename, "🗑️ Purgando DB ISAR");

      try {
        // Borrado atómico aislado a la Base de Datos
        await ref.read(dbServiceProvider).deleteTrackMetadata(file.path);
      } catch (_) {
        pipe.addQuarantine(filename);
        continue;
      }
    }
    debugPrint("🟢 [DSP Worker] Base de datos ISAR purgada exitosamente.");
  }

  Future<String> processSingleFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync() || Platform.isAndroid || Platform.isIOS) {
      return filePath;
    }

    try {
      await rust_dsp.processFullPipeline(inputPath: filePath);
    } catch (_) {}

    return filePath;
  }
}

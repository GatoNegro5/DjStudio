import 'dart:io';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart'; // 🛠️ INYECTADO: Motor C++ Multiplataforma
import 'package:ffmpeg_kit_flutter_audio/return_code.dart';
import 'pipeline_provider.dart';
import 'package:flutter/foundation.dart';

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

  Future<void> processTrim(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    // Algoritmo matemático para amputar silencios estáticos a -45dB
    await _runFFmpegBatch(directoryPath, "DSP Trim", [
      '-af',
      'silenceremove=start_periods=1:start_duration=0:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_duration=0:start_threshold=-45dB,areverse',
    ], isCancelled: isCancelled);
  }

  Future<void> processEBU(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    // Pipeline EBU R128 para nivelación universal LUFS
    await _runFFmpegBatch(directoryPath, "Master LUFS", [
      '-af',
      'loudnorm=I=-14:LRA=11:TP=-1',
    ], isCancelled: isCancelled);
  }

  // 🛠️ INYECCIÓN: Motor Asíncrono C++ para procesamientos por lotes Multiplataforma
  Future<void> _runFFmpegBatch(
    String directoryPath,
    String moduleName,
    List<String> audioFilters, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    // Escaneo recursivo activado para coincidir con la UI
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .toList();
    int total = files.length;
    final pipe = ref.read(pipelineProvider.notifier);

    for (int i = 0; i < total; i++) {
      // FRENO DE EMERGENCIA ATÓMICO
      if (isCancelled != null && isCancelled()) {
        debugPrint(
          "🔴 [DSP Worker] Proceso abortado por el usuario en módulo: $moduleName.",
        );
        break;
      }

      final file = files[i];
      final filename = file.uri.pathSegments.last;
      pipe.updateProgress(i + 1, total, filename, moduleName);

      final outPath = file.path.replaceAll(
        RegExp(r'\.mp3$', caseSensitive: false),
        '_R.mp3',
      );

      try {
        final command =
            "-y -i \"${file.path}\" ${audioFilters.join(' ')} -c:a libmp3lame -b:a 320k \"$outPath\"";

        // Ejecución nativa puenteada, sin requerir binario de consola
        final session = await FFmpegKit.execute(command);
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          // Reemplazo atómico
          await file.delete();
          await File(outPath).rename(file.path);
        } else {
          // Failsafe activo ante errores de codificación
          final log = await session.getLogsAsString();
          debugPrint("🔴 [FFmpeg Error]: $log");
        }
      } catch (e) {
        pipe.updateProgress(
          i + 1,
          total,
          "⚠️ Error en conversión DSP",
          moduleName,
        );
        await Future.delayed(const Duration(seconds: 2));
        break;
      }
    }
    pipe.reset();
  }

  Future<String> processSingleFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return filePath;

    final outPath = filePath.replaceAll(
      RegExp(r'\.mp3$', caseSensitive: false),
      '_R.mp3',
    );
    try {
      // Encadenamiento DSP (Trim In/Out + LUFS EBU R128) en 1 solo pase
      final command =
          "-y -i \"$filePath\" -af silenceremove=start_periods=1:start_duration=0:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_duration=0:start_threshold=-45dB,areverse,loudnorm=I=-14:LRA=11:TP=-1 -c:a libmp3lame -b:a 320k \"$outPath\"";

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        await file.delete();
        await File(outPath).rename(filePath);
      }
    } catch (_) {}

    return filePath; // El archivo final conserva el nombre original de entrada
  }
}

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_audio/return_code.dart';

class DspEngine {
  /// M2: AutoTrim - Recorte de silencios y ruido analógico
  Future<void> autoTrim(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception("Archivo no encontrado en I/O.");

    final tempFilePath =
        "${file.parent.path}${Platform.pathSeparator}temp_dsp_trim.mp3";
    final afFilter =
        "silenceremove=start_periods=1:start_threshold=-35dB,areverse,silenceremove=start_periods=1:start_threshold=-35dB,areverse";

    debugPrint("⏳ [M2] Aplicando Auto-Trim: ${file.uri.pathSegments.last}");
    bool success = await _runFFmpeg(filePath, tempFilePath, afFilter);

    if (success) {
      await _atomicReplace(file, File(tempFilePath));
      debugPrint("🟢 [M2 ÉXITO] Archivo truncado.");
    }
  }

  /// M3: Normalización LUFS de Doble Pasada (Dual-Pass EBU R128)
  Future<void> normalizeLUFS(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception("Archivo no encontrado en I/O.");

    debugPrint(
      "⏳ [M3] Iniciando Doble Pasada LUFS: ${file.uri.pathSegments.last}",
    );

    String? i, lra, tp, thresh;

    // PASO 1: Análisis Diferencial
    if (Platform.isWindows || Platform.isLinux) {
      final pass1Result = await Process.run('ffmpeg', [
        '-i',
        filePath,
        '-af',
        'loudnorm=I=-14:LRA=11:TP=-1.5:print_format=json',
        '-f',
        'null',
        'NUL',
      ]);
      final log = pass1Result.stderr.toString();
      i = RegExp(r'"input_i" : "([-0-9.]+)"').firstMatch(log)?.group(1);
      lra = RegExp(r'"input_lra" : "([-0-9.]+)"').firstMatch(log)?.group(1);
      tp = RegExp(r'"input_tp" : "([-0-9.]+)"').firstMatch(log)?.group(1);
      thresh = RegExp(
        r'"input_thresh" : "([-0-9.]+)"',
      ).firstMatch(log)?.group(1);
    } else {
      final session = await FFmpegKit.execute(
        '-i "$filePath" -af loudnorm=I=-14:LRA=11:TP=-1.5:print_format=json -f null /dev/null',
      );
      final log = await session.getLogsAsString();
      i = RegExp(r'"input_i" : "([-0-9.]+)"').firstMatch(log)?.group(1);
      lra = RegExp(r'"input_lra" : "([-0-9.]+)"').firstMatch(log)?.group(1);
      tp = RegExp(r'"input_tp" : "([-0-9.]+)"').firstMatch(log)?.group(1);
      thresh = RegExp(
        r'"input_thresh" : "([-0-9.]+)"',
      ).firstMatch(log)?.group(1);
    }

    if (i == null || lra == null || tp == null || thresh == null) {
      debugPrint(
        "🔴 [M3 FATAL] Fallo en Paso 1: Extracción de matriz acústica fallida.",
      );
      return;
    }

    // PASO 2: Inyección de Ganancia
    final tempFilePath =
        "${file.parent.path}${Platform.pathSeparator}temp_dsp_norm.mp3";
    final pass2Filter =
        "loudnorm=I=-14:LRA=11:TP=-1.5:measured_I=$i:measured_LRA=$lra:measured_TP=$tp:measured_thresh=$thresh:linear=true";

    bool success = await _runFFmpeg(filePath, tempFilePath, pass2Filter);

    if (success) {
      await _atomicReplace(file, File(tempFilePath));
      debugPrint("🟢 [M3 ÉXITO] Volumen estandarizado a -14 LUFS.");
    }
  }

  /// PRE-CHECK: Valida si la pista ya pasó por el pipeline
  Future<bool> checkWatermark(String filePath) async {
    if (Platform.isWindows || Platform.isLinux) {
      final process = await Process.run('ffmpeg', [
        '-i',
        filePath,
        '-f',
        'ffmetadata',
        '-',
      ]);
      final log = process.stderr.toString() + process.stdout.toString();
      return log.contains('DjStudio_M3=Verified');
    } else {
      final session = await FFmpegKit.execute('-i "$filePath" -f ffmetadata -');
      final log = await session.getLogsAsString();
      return log.contains('DjStudio_M3=Verified');
    }
  }

  /// INYECCIÓN: Sella el archivo atómicamente
  Future<void> injectWatermark(String filePath) async {
    final file = File(filePath);
    final tempFilePath =
        "${file.parent.path}${Platform.pathSeparator}temp_watermark.mp3";

    final success = await _runFFmpeg(
      filePath,
      tempFilePath,
      "", // Sin filtro de audio
    );

    if (success) {
      await _atomicReplace(file, File(tempFilePath));
      debugPrint("🟢 [WATERMARK] Firma inyectada en ID3v2.");
    }
  }

  // ==========================================
  // CAPA DE INFRAESTRUCTURA (Helpers)
  // ==========================================
  Future<bool> _runFFmpeg(String input, String output, String filter) async {
    List<String> args;
    String cmdMobile;

    if (filter.isEmpty) {
      args = [
        '-y',
        '-i',
        input,
        '-map',
        '0',
        '-c',
        'copy',
        '-metadata',
        'DjStudio_M3=Verified',
        output,
      ];
      cmdMobile =
          '-y -i "$input" -map 0 -c copy -metadata DjStudio_M3=Verified "$output"';
    } else {
      args = [
        '-y',
        '-i',
        input,
        '-af',
        filter,
        '-c:a',
        'libmp3lame',
        '-q:a',
        '2',
        output,
      ];
      cmdMobile =
          '-y -i "$input" -af "$filter" -c:a libmp3lame -q:a 2 "$output"';
    }

    if (Platform.isWindows || Platform.isLinux) {
      final process = await Process.run('ffmpeg', args);
      if (process.exitCode != 0) {
        debugPrint("🔴 [FFMPEG NATIVO] ${process.stderr}");
      }
      return process.exitCode == 0;
    } else {
      final session = await FFmpegKit.execute(cmdMobile);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        debugPrint("🔴 [FFMPEG MOBILE] ${await session.getLogsAsString()}");
      }
      return ReturnCode.isSuccess(returnCode);
    }
  }

  Future<void> _atomicReplace(File original, File temp) async {
    final originalPath = original.path;
    await original.delete();
    await temp.rename(originalPath);
  }
}

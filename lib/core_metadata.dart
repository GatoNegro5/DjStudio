import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_audio/return_code.dart';

class MetadataEngine {
  final garbageRegex = RegExp(
    r'\s*[\(\[\{][^\)\]\}]*(official|music video|video|audio|lyric|lyrics|letra|letras|hq|hd|4k|remastered|remaster|visualizer|en vivo|en directo|live)[^\)\]\}]*(?:[\)\]\}]|$)\s*',
    caseSensitive: false,
  );
  final spacesRegex = RegExp(r'\s{2,}');
  final dashRegex = RegExp(r'\s*-\s*-+\s*');
  final invalidCharsRegex = RegExp(r'[<>:"/\\|?*]');

  Future<void> processFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception("Archivo no encontrado en I/O.");

    final filename = file.uri.pathSegments.last;
    final result = _parseAndClean(filename);

    final newFilename = result[0];
    final artist = result[1];
    final title = result[2];

    debugPrint("⏳ [M1] Inyectando tags: $artist - $title");

    final newFilePath = file.parent.path + Platform.pathSeparator + newFilename;
    final tempFilePath =
        "${file.parent.path}${Platform.pathSeparator}temp_meta.mp3";

    bool success = false;

    // Enrutamiento Arquitectónico Híbrido (Adapter Pattern)
    if (Platform.isWindows || Platform.isLinux) {
      // Bypass Nativo Desktop: Ejecución directa en consola OS
      final commandArgs = [
        '-y',
        '-i',
        filePath,
        '-c',
        'copy',
        '-metadata',
        'title=$title',
        '-metadata',
        'artist=$artist',
        '-metadata',
        'album=ReGenial Master',
        tempFilePath,
      ];

      try {
        final process = await Process.run('ffmpeg', commandArgs);
        if (process.exitCode == 0) {
          success = true;
        } else {
          debugPrint(
            "🔴 [M1 FATAL] Motor FFmpeg Windows Falló: ${process.stderr}",
          );
        }
      } catch (e) {
        debugPrint(
          "🔴 [M1 FATAL] FFMPEG no detectado en el PATH de Windows: $e",
        );
      }
    } else {
      // Motor FFmpegKit Mobile: Ejecución aislada en Celulares (Android/iOS)
      final commandString =
          '-y -i "$filePath" -c copy -metadata title="$title" -metadata artist="$artist" -metadata album="ReGenial Master" "$tempFilePath"';
      final session = await FFmpegKit.execute(commandString);
      final returnCode = await session.getReturnCode();

      success = ReturnCode.isSuccess(returnCode);
      if (!success) {
        final logs = await session.getLogsAsString();
        debugPrint("🔴 [M1 FATAL] Motor FFmpeg Celular Falló: $logs");
      }
    }

    // Transacción I/O Atómica
    if (success) {
      final tempFile = File(tempFilePath);
      if (filePath != newFilePath) {
        await file.delete();
        await tempFile.rename(newFilePath);
        debugPrint(
          "🟢 [M1 ÉXITO] Archivo renombrado y masterizado a: $newFilename",
        );
      } else {
        await file.delete();
        await tempFile.rename(filePath);
        debugPrint(
          "🟢 [M1 ÉXITO] Tags ID3v2 inyectados (Nomenclatura ya estaba limpia).",
        );
      }
    } else {
      if (File(tempFilePath).existsSync()) File(tempFilePath).deleteSync();
    }
  }

  List<String> _parseAndClean(String filename) {
    String name = filename;
    String ext = '';
    int extIndex = filename.lastIndexOf('.');
    if (extIndex != -1) {
      name = filename.substring(0, extIndex);
      ext = filename.substring(extIndex);
    }
    if (name.endsWith('_R') || name.endsWith(' R')) {
      name = name.substring(0, name.length - 2);
    }
    String cleanName = name.replaceAll(garbageRegex, ' ').trim();
    cleanName = cleanName.replaceAll(dashRegex, ' - ');
    cleanName = cleanName.replaceAll('_', ' ');
    cleanName = cleanName.replaceAll(spacesRegex, ' ');

    List<String> parts = cleanName.split(' - ');
    String artist = 'Unknown';
    String title = cleanName.trim();
    if (parts.length >= 2) {
      artist = parts[0].trim();
      title = parts.sublist(1).join(' - ').trim();
    }
    artist = _toTitleCase(artist);
    title = _toTitleCase(title);
    title = title.replaceAll(RegExp(r'[\.\-_]+$'), '');
    String finalFilename = artist != 'Unknown'
        ? '$artist - $title$ext'
        : '$title$ext';
    return [finalFilename.replaceAll(invalidCharsRegex, ''), artist, title];
  }

  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join(' ');
  }
}

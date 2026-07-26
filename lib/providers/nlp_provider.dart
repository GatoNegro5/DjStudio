import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pipeline_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

final nlpWorkerProvider = Provider((ref) => NlpWorker(ref));

class NlpWorker {
  final Ref ref;

  final Map<String, String> _headers = {
    'User-Agent': 'DJStudioPlayer/1.0.0 (Custom Build)',
  };

  NlpWorker(this.ref);

  Future<http.Response> _resilientGet(String targetUrl) async {
    final directUri = Uri.parse(targetUrl);
    try {
      final res = await http
          .get(directUri, headers: _headers)
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) return res;
      if (res.statusCode >= 500) {
        return res;
      }
    } catch (e) {
      debugPrint(
        "🟡 [NLP Circuit Breaker] Conexión directa falló. Intentando Proxy...",
      );
    }

    final proxyUri = Uri.parse(
      'https://api.allorigins.win/raw?url=${Uri.encodeComponent(targetUrl)}',
    );
    return await http.get(proxyUri).timeout(const Duration(seconds: 8));
  }

  // 🛠️ INYECCIÓN: Extracción Nativa de Duración Local
  Future<int> _getLocalDurationSec(String filePath) async {
    try {
      final result = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        filePath,
      ]);
      if (result.exitCode == 0) {
        return (double.tryParse(result.stdout.toString().trim()) ?? 0.0)
            .toInt();
      }
    } catch (_) {}
    return 0;
  }

  Future<void> processDirectory(
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
        debugPrint("🔴 [NLP Worker] Scraping abortado por el usuario.");
        break;
      }

      final file = files[i];
      final filename = file.uri.pathSegments.last;
      pipe.updateProgress(i + 1, total, filename, "Scraping LRC");

      await processSingleFile(file.path);

      await Future.delayed(const Duration(milliseconds: 150));
    }
    pipe.reset();
  }

  Future<List<dynamic>> searchLyricCandidates(
    String query, {
    String? badLyric,
  }) async {
    List<dynamic> allResults = [];
    bool isServerError = false;
    String errorMessage = "No se encontraron resultados.";

    Future<void> fetchTarget(String url) async {
      try {
        final response = await _resilientGet(url);
        if (response.statusCode == 200) {
          final parsed = jsonDecode(response.body);
          if (parsed is List) allResults.addAll(parsed);
        } else if (response.statusCode >= 500) {
          isServerError = true;
          errorMessage =
              "Error ${response.statusCode}: El servidor de letras reporta una caída crítica (Bad Gateway).";
        }
      } catch (e) {
        isServerError = true;
        errorMessage = "El servidor no responde (Tiempo de espera agotado).";
      }
    }

    final globalUrl =
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(query.trim())}';
    await fetchTarget(globalUrl);

    if (query.contains('-')) {
      final parts = query.split('-');
      if (parts.length >= 2) {
        final artist = parts[0].trim();
        final track = parts.sublist(1).join(' ').trim();
        final advancedUrl =
            'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(artist)}&track_name=${Uri.encodeComponent(track)}';
        await fetchTarget(advancedUrl);
      }
    }

    if (allResults.isEmpty && isServerError) throw Exception(errorMessage);

    final uniqueResults = <int, dynamic>{};
    for (var item in allResults) {
      if (item['id'] != null) uniqueResults[item['id']] = item;
    }
    final combinedData = uniqueResults.values.toList();

    return combinedData.where((item) {
      final synced = item['syncedLyrics'];
      if (synced == null || synced.toString().trim().isEmpty) return false;

      if (badLyric != null && badLyric.isNotEmpty) {
        String apiText = synced
            .toString()
            .replaceAll(RegExp(r'\[.*?\]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        String badText = badLyric
            .replaceAll(RegExp(r'\[.*?\]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        String apiSnippet = apiText.length > 40
            ? apiText.substring(0, 40)
            : apiText;
        String badSnippet = badText.length > 40
            ? badText.substring(0, 40)
            : badText;

        if (apiSnippet.isNotEmpty &&
            badSnippet.isNotEmpty &&
            apiSnippet == badSnippet) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Future<void> writeManualLyric(String audioPath, String syncedLyrics) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    await File(lrcPath).writeAsString(syncedLyrics);
    debugPrint("🟢 [NLP Tracker] LRC manual sobreescrito con éxito.");
  }

  Future<void> _fetchAndSaveLrc(String audioPath, String lrcPath) async {
    try {
      final filename = audioPath
          .split(RegExp(r'[\\/]'))
          .last
          .replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '');
      final parts = filename.split(' - ');
      final localSec = await _getLocalDurationSec(
        audioPath,
      ); // 🛠️ Lectura Nativa

      if (parts.length >= 2) {
        final artist = parts[0].trim();
        final originalTrack = parts[1].trim();
        List<String> trackWords = originalTrack.split(' ');

        while (trackWords.isNotEmpty) {
          final currentTrackAttempt = trackWords.join(' ');
          final url =
              'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(artist)}&track_name=${Uri.encodeComponent(currentTrackAttempt)}';

          try {
            final response = await _resilientGet(url);
            if (response.statusCode == 200) {
              final parsed = jsonDecode(response.body);
              if (parsed is List && parsed.isNotEmpty) {
                // 🛠️ ALGORITMO DELTA: Batch
                parsed.sort((a, b) {
                  final aSync =
                      a['syncedLyrics']?.toString().isNotEmpty ?? false;
                  final bSync =
                      b['syncedLyrics']?.toString().isNotEmpty ?? false;
                  if (aSync && !bSync) return -1;
                  if (!aSync && bSync) return 1;
                  if (localSec > 0) {
                    final aDur = (a['duration'] as num?)?.toInt() ?? 0;
                    final bDur = (b['duration'] as num?)?.toInt() ?? 0;
                    return (aDur - localSec).abs().compareTo(
                      (bDur - localSec).abs(),
                    );
                  }
                  return 0;
                });

                for (var item in parsed) {
                  final syncedLyrics = item['syncedLyrics'];
                  if (syncedLyrics != null &&
                      syncedLyrics.toString().trim().isNotEmpty) {
                    await File(lrcPath).writeAsString(syncedLyrics);
                    debugPrint(
                      "🟢 [NLP Tracker] LRC consolidado con Delta O(1): $currentTrackAttempt",
                    );
                    return;
                  }
                }
              }
            }
          } catch (e) {
            debugPrint("🟡 [NLP Tracker] Pipeline iterativo evadió error: $e");
          }
          trackWords.removeLast();
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

      final fallbackUrl =
          'https://lrclib.net/api/search?q=${Uri.encodeComponent(filename)}';
      try {
        final fallbackResponse = await _resilientGet(fallbackUrl);
        if (fallbackResponse.statusCode == 200) {
          final parsed = jsonDecode(fallbackResponse.body);
          if (parsed is List && parsed.isNotEmpty) {
            parsed.sort((a, b) {
              final aSync = a['syncedLyrics']?.toString().isNotEmpty ?? false;
              final bSync = b['syncedLyrics']?.toString().isNotEmpty ?? false;
              if (aSync && !bSync) return -1;
              if (!aSync && bSync) return 1;
              if (localSec > 0) {
                final aDur = (a['duration'] as num?)?.toInt() ?? 0;
                final bDur = (b['duration'] as num?)?.toInt() ?? 0;
                return (aDur - localSec).abs().compareTo(
                  (bDur - localSec).abs(),
                );
              }
              return 0;
            });

            for (var item in parsed) {
              final syncedLyrics = item['syncedLyrics'];
              if (syncedLyrics != null &&
                  syncedLyrics.toString().trim().isNotEmpty) {
                await File(lrcPath).writeAsString(syncedLyrics);
                debugPrint("🟢 [NLP Tracker] LRC salvado vía Failsafe Delta.");
                return;
              }
            }
          }
        }
      } catch (e) {
        debugPrint("🟡 [NLP Tracker] Failsafe evadió error: $e");
      }
    } catch (e) {
      debugPrint("🔴 [NLP Tracker] Excepción crítica de I/O: $e");
    }
  }

  Future<void> processSingleFile(String filePath) async {
    final audioFile = File(filePath);
    final originalFilename = audioFile.uri.pathSegments.last;
    final lrcPath = filePath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);
    final pipe = ref.read(pipelineProvider.notifier);

    if (file.existsSync()) {
      final content = await file.readAsString();
      if (content.contains('Letra no encontrada') ||
          content.contains('Error de conexión') ||
          content.contains('Error Auto-Healing')) {
        await file.delete();
      } else if (file.lengthSync() > 20) {
        return;
      }
    }

    try {
      await _fetchAndSaveLrc(filePath, lrcPath);

      if (!file.existsSync() || file.lengthSync() < 10) {
        pipe.updateProgress(
          ref.read(pipelineProvider).current,
          ref.read(pipelineProvider).total,
          originalFilename,
          "⚠️ Auto-Healing YT...",
        );
        final yt = YoutubeExplode();
        final cleanBase = originalFilename.replaceAll(
          RegExp(r'\.mp3$', caseSensitive: false),
          '',
        );

        try {
          final searchResult = await yt.search.search(
            '$cleanBase official audio track',
          );
          if (searchResult.isNotEmpty) {
            final topVideo = searchResult.first;
            final officialTitle = topVideo.title
                .replaceAll(
                  RegExp(r'[\[\(\{].*?[\]\)\}]|[^a-zA-Z0-9 -ñÑáéíóúÁÉÍÓÚ]'),
                  '',
                )
                .trim();
            final newAudioPath =
                '${audioFile.parent.path}${Platform.pathSeparator}$officialTitle.mp3';
            final newLrcPath =
                '${audioFile.parent.path}${Platform.pathSeparator}$officialTitle.lrc';

            if (!File(newAudioPath).existsSync() &&
                newAudioPath.toLowerCase() != filePath.toLowerCase()) {
              await audioFile.rename(newAudioPath);
              await _fetchAndSaveLrc(newAudioPath, newLrcPath);

              final newLrcFile = File(newLrcPath);
              if (!newLrcFile.existsSync() || newLrcFile.lengthSync() < 10) {
                await newLrcFile.writeAsString(
                  '[00:00.00] 🎵 Letra no encontrada\n',
                );
                pipe.addQuarantine(newAudioPath);
              }
            } else {
              pipe.addQuarantine(filePath);
            }
          } else {
            await file.writeAsString(
              '[00:00.00] 🎵 Letra no encontrada en la base de datos API\n',
            );
            pipe.addQuarantine(filePath);
          }
        } catch (e) {
          await file.writeAsString('[00:00.00] ❌ Error Auto-Healing\n');
          pipe.addQuarantine(filePath);
        } finally {
          yt.close();
        }
      }
    } catch (e) {
      await file.writeAsString(
        '[00:00.00] ❌ Error de conexión al buscar letra\n',
      );
    }
  }
}

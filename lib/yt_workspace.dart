import 'dart:io';
import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:http/http.dart' as http;

// =====================================================================
// MÓDULO 2: BÚSQUEDA Y EXTRACCIÓN YT
// =====================================================================
class YoutubeSearchAndDownloadWorkspace extends StatefulWidget {
  const YoutubeSearchAndDownloadWorkspace({super.key});

  @override
  State<YoutubeSearchAndDownloadWorkspace> createState() =>
      _YoutubeSearchAndDownloadWorkspaceState();
}

class _YoutubeSearchAndDownloadWorkspaceState
    extends State<YoutubeSearchAndDownloadWorkspace> {
  late String _downloadPath;
  final TextEditingController _searchController = TextEditingController();
  final YoutubeExplode _yt = YoutubeExplode();

  List<Video> _results = [];
  bool _isProcessing = false;
  String _statusText =
      "Sistemas en línea. Busca un artista o pega URL directa.";

  @override
  void initState() {
    super.initState();
    _downloadPath = _resolveNativeMusicPath();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _yt.close();
    super.dispose();
  }

  String _resolveNativeMusicPath() {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      return userProfile != null
          ? '$userProfile\\Music\\Descargas'
          : 'C:\\Music\\Descargas';
    }
    return '/Descargas';
  }

  Future<void> _handleInput(String input) async {
    if (input.isEmpty) return;
    if (input.startsWith('http')) {
      await _executeDirectDownload(input);
    } else {
      await _executeSearch(input);
    }
  }

  Future<void> _executeSearch(String query) async {
    setState(() {
      _isProcessing = true;
      _statusText = "Buscando '$query' en los servidores de YouTube...";
      _results.clear();
    });

    try {
      final searchResult = await _yt.search.search('$query official audio');
      setState(() {
        _results = searchResult.take(15).toList();
        _statusText = "Resultados listos. Clic en 'Ingestar' para descargar.";
      });
    } catch (e) {
      setState(() => _statusText = "🔴 ERROR de Búsqueda: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _executeDirectDownload(String targetUrl) async {
    setState(() {
      _isProcessing = true;
      _statusText = "Resolviendo firmas DRM e iniciando extracción...";
    });

    try {
      final tempDir = Directory.systemTemp;
      final ytdlpPath = '${tempDir.path}${Platform.pathSeparator}yt-dlp.exe';

      if (!Directory(_downloadPath).existsSync()) {
        Directory(_downloadPath).createSync(recursive: true);
      }

      if (Platform.isWindows && !File(ytdlpPath).existsSync()) {
        setState(
          () => _statusText = "Descargando motor extractor (yt-dlp.exe)...",
        );
        final url = Uri.parse(
          'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        );
        final response = await http.get(url);
        await File(ytdlpPath).writeAsBytes(response.bodyBytes);
      }

      final process = await Process.start(ytdlpPath, [
        '-f',
        'bestaudio',
        '-x',
        '--audio-format',
        'mp3',
        '--audio-quality',
        '320K',
        '-o',
        '$_downloadPath${Platform.pathSeparator}%(title)s.%(ext)s',
        targetUrl,
      ]);

      process.stdout.transform(const SystemEncoding().decoder).listen((data) {
        if (data.contains('[download]')) {
          final cleanData = data
              .replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '')
              .trim();
          setState(() => _statusText = cleanData);
        }
      });

      final exitCode = await process.exitCode;
      if (exitCode == 0) {
        setState(() {
          _statusText = "✅ ¡Extracción Completada! MP3 sellado en disco.";
          _searchController.clear();
        });
      } else {
        throw Exception("El binario CLI colapsó con código $exitCode.");
      }
    } catch (e) {
      setState(() => _statusText = "🔴 ERROR FATAL: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(30.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Buscador Global & Extracción",
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF00FFFF),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            "Busca pistas en la red o pega una URL para inyectarla directamente al disco duro en formato MP3 (320kbps).",
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  enabled: !_isProcessing,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText:
                        "Nombre de canción o https://www.youtube.com/watch?v=...",
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.black,
                    border: OutlineInputBorder(
                      borderSide: const BorderSide(color: Color(0xFF00FFFF)),
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search, color: Color(0xFF00FFFF)),
                      onPressed: _isProcessing
                          ? null
                          : () => _handleInput(_searchController.text.trim()),
                    ),
                  ),
                  onSubmitted: _isProcessing
                      ? null
                      : (val) => _handleInput(val.trim()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(color: const Color(0xFF333333)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _statusText,
              style: TextStyle(
                color: _statusText.contains("ERROR")
                    ? Colors.redAccent
                    : const Color(0xFF39FF14),
                fontFamily: 'Consolas',
                fontSize: 13,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 20),
          if (_results.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final video = _results[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: ListTile(
                      leading: const Icon(
                        Icons.youtube_searched_for,
                        color: Color(0xFF00FFFF),
                      ),
                      title: Text(
                        video.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        "${video.author} • ${video.duration?.inMinutes ?? 0}:${((video.duration?.inSeconds ?? 0) % 60).toString().padLeft(2, '0')}",
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      trailing: ElevatedButton.icon(
                        icon: const Icon(Icons.download),
                        label: const Text("Ingestar"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00FFFF),
                          foregroundColor: Colors.black,
                        ),
                        onPressed: _isProcessing
                            ? null
                            : () => _executeDirectDownload(
                                'https://youtube.com/watch?v=${video.id.value}',
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

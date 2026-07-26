import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ffmpeg_kit_flutter_audio/ffprobe_kit.dart';

import 'providers/directory_provider.dart';
import 'providers/pipeline_provider.dart';
import 'providers/metadata_provider.dart';
import 'providers/nlp_provider.dart';
import 'providers/dsp_provider.dart';
import 'providers/db_provider.dart';

// =====================================================================
// MÓDULO 1: VISTA DE DSP / NLP
// =====================================================================
class DspNlpWorkspace extends ConsumerWidget {
  const DspNlpWorkspace({super.key});

  Future<void> _executeAutoPipeline(WidgetRef ref, String targetPath) async {
    final pipe = ref.read(pipelineProvider.notifier);
    ref.read(directoryProvider.notifier).scanPath(targetPath);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    try {
      if (checkAbort()) return;
      await ref
          .read(metadataWorkerProvider)
          .processDirectory(
            targetPath,
            (current, total, file) => pipe.updateProgress(
              current,
              total,
              file,
              "Fase 1: Limpieza Metadatos",
            ),
            onCorrupt: (query) => pipe.addQuarantine(query),
            isCancelled: checkAbort,
          );

      if (checkAbort()) return;
      pipe.updateProgress(1, 3, "", "Fase 2: Masterización EBU R128");
      await ref
          .read(dspWorkerProvider)
          .processEBU(targetPath, isCancelled: checkAbort);

      if (checkAbort()) return;
      pipe.updateProgress(2, 3, "", "Fase 3: Render DSP (BPM & Trim)");
      await ref
          .read(dspWorkerProvider)
          .processTrim(targetPath, isCancelled: checkAbort);
    } catch (e) {
      debugPrint("🔴 [PIPELINE ERROR FATAL]: $e");
    } finally {
      pipe.reset();
      ref.read(directoryProvider.notifier).scanPath(targetPath);
    }
  }

  // 🛠️ INYECCIÓN: Motor de Análisis Masivo Desacoplado (Multiplataforma)
  Future<void> _executeBatchDSP(WidgetRef ref, String targetPath) async {
    final pipe = ref.read(pipelineProvider.notifier);
    final dir = Directory(targetPath);

    if (!dir.existsSync()) return;
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    try {
      pipe.updateProgress(0, 1, "", "Fase DSP: Escaneando archivos .mp3...");

      // Búsqueda recursiva de todos los MP3 en la carpeta y subcarpetas
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mp3'))
          .toList();

      final int total = files.length;
      if (total == 0) {
        pipe.reset();
        return;
      }

      final Map<String, Map<String, dynamic>> mixProfiles = {
        'reggaeton': {'curve': 'eq_kill', 'durationMs': 4000},
        'salsa': {'curve': 'sharp', 'durationMs': 2000},
        'merengue': {'curve': 'sharp', 'durationMs': 2500},
        'balada': {'curve': 'linear', 'durationMs': 8000},
        'rock': {'curve': 'constant_power', 'durationMs': 3500},
        'cumbia': {'curve': 'constant_power', 'durationMs': 3000},
        'electro': {'curve': 'eq_kill', 'durationMs': 7000},
        'latin': {'curve': 'constant_power', 'durationMs': 4500},
        'pop': {'curve': 'constant_power', 'durationMs': 4000},
      };

      for (int i = 0; i < total; i++) {
        if (checkAbort()) break;

        final path = files[i].path;
        final filename = path.split(Platform.pathSeparator).last;
        pipe.updateProgress(
          i + 1,
          total,
          filename,
          "Fase DSP: Analizando Tags ID3 (FFprobeKit)",
        );

        // Desacoplamiento de shell nativa: Uso de API C++ JNI/Objective-C
        final session = await FFprobeKit.getMediaInformation(path);
        final returnCode = await session.getReturnCode();

        if (returnCode == null || !returnCode.isValueSuccess()) continue;

        final info = await session.getMediaInformation();
        if (info == null) continue;

        final tags = info.getTags();

        String assignedProfile = 'constant_power';
        int assignedDuration = 6000;
        String rawGenre = 'desconocido';

        if (tags != null) {
          final genreTagKey = tags.keys.firstWhere(
            (k) => k.toString().toLowerCase() == 'genre',
            orElse: () => '',
          );
          if (genreTagKey.toString().isNotEmpty) {
            rawGenre = tags[genreTagKey].toString().toLowerCase();
            for (final key in mixProfiles.keys) {
              if (rawGenre.contains(key)) {
                assignedProfile = mixProfiles[key]!['curve'] as String;
                assignedDuration = mixProfiles[key]!['durationMs'] as int;
                break;
              }
            }
          }
        }

        // Transacción atómica a DB Embebida (Sandboxed)
        await ref
            .read(dbServiceProvider)
            .saveTrackMetadata(
              path: path,
              mixProfile: assignedProfile,
              durationMs: assignedDuration,
              genre: rawGenre,
            );
      }
    } catch (e) {
      debugPrint("🔴 [DSP BATCH ERROR FATAL]: $e");
    } finally {
      pipe.reset();
    }
  }

  void _showQuickFolderMenu(
    BuildContext context,
    WidgetRef ref,
    String currentPath,
  ) {
    Directory baseDir;
    if (currentPath.isNotEmpty) {
      baseDir = Directory(currentPath).parent;
    } else {
      baseDir = Directory('C:\\Users\\ASUS\\Music\\ReGenial');
    }

    List<FileSystemEntity> subFolders = [];
    if (baseDir.existsSync()) {
      subFolders = baseDir.listSync().whereType<Directory>().toList();
      subFolders.sort((a, b) => a.path.compareTo(b.path));
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFFF007F)),
          ),
          title: const Text(
            "Selección Rápida (Auto-Pipeline)",
            style: TextStyle(
              color: Color(0xFFFF007F),
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: 500,
            height: 400,
            child: subFolders.isEmpty
                ? const Text(
                    "No se encontraron subcarpetas.",
                    style: TextStyle(color: Colors.white54),
                  )
                : ListView.builder(
                    itemCount: subFolders.length,
                    itemBuilder: (context, index) {
                      final folder = subFolders[index];
                      final folderName = folder.path
                          .split(Platform.pathSeparator)
                          .last;
                      return ListTile(
                        leading: const Icon(
                          Icons.folder_special,
                          color: Color(0xFF39FF14),
                        ),
                        title: Text(
                          folderName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          folder.path,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                        hoverColor: Colors.white10,
                        onTap: () {
                          Navigator.pop(context);
                          _executeAutoPipeline(ref, folder.path);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Abortar",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                ref.read(directoryProvider.notifier).loadDirectory();
              },
              child: const Text(
                "Usar Explorador de Windows",
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(directoryProvider);
    final pipeState = ref.watch(pipelineProvider);
    final bool isBusy = !pipeState.isIdle;

    return Padding(
      padding: const EdgeInsets.all(30.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Laboratorio DSP & NLP",
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFFFF007F),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            "Procesamiento masivo de metadatos, espectro y extracción semántica.",
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 30),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: Colors.black45,
              border: Border.all(
                color: pipeState.isAborted
                    ? Colors.redAccent
                    : const Color(0xFFFF007F),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.folder_open,
                  color: pipeState.isAborted
                      ? Colors.redAccent
                      : const Color(0xFFFF007F),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Directorio Objetivo:",
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        dirState.currentPath.isEmpty
                            ? "NINGUNA CARPETA SELECCIONADA"
                            : dirState.currentPath,
                        style: TextStyle(
                          color: dirState.currentPath.isEmpty
                              ? Colors.redAccent
                              : (pipeState.isAborted
                                    ? Colors.redAccent
                                    : const Color(0xFFFF007F)),
                          fontFamily: 'Consolas',
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isBusy)
                  ElevatedButton.icon(
                    onPressed: () => _showQuickFolderMenu(
                      context,
                      ref,
                      dirState.currentPath,
                    ),
                    icon: const Icon(Icons.flash_on),
                    label: const Text("Menú Rápido"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A1A1A),
                      foregroundColor: const Color(0xFF39FF14),
                      side: const BorderSide(color: Color(0xFF39FF14)),
                    ),
                  ),
                if (isBusy)
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                "[${pipeState.current}/${pipeState.total}] ${pipeState.moduleStatus}",
                                style: TextStyle(
                                  color: pipeState.isAborted
                                      ? Colors.redAccent
                                      : const Color(0xFF39FF14),
                                  fontFamily: 'Consolas',
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 5),
                              LinearProgressIndicator(
                                value: pipeState.total == 0
                                    ? 0
                                    : pipeState.current / pipeState.total,
                                backgroundColor: Colors.white10,
                                color: pipeState.isAborted
                                    ? Colors.redAccent
                                    : const Color(0xFF39FF14),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 15),
                        IconButton(
                          onPressed: pipeState.isAborted
                              ? null
                              : () =>
                                    ref.read(pipelineProvider.notifier).abort(),
                          icon: const Icon(
                            Icons.cancel,
                            color: Colors.redAccent,
                            size: 35,
                          ),
                          tooltip: "Freno de Emergencia",
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 15, // 🛠️ Espaciado reducido
              mainAxisSpacing: 15, // 🛠️ Espaciado reducido
              childAspectRatio:
                  4.0, // 🛠️ FACTOR CRÍTICO: Aplasta las tarjetas para hacerlas horizontales
              children: [
                _buildActionCard(
                  title: "1. Pipeline Maestro (Audio + Nomenclatura)",
                  description:
                      "Ejecución atómica: Limpieza Regex, EBU R128 y Render BPM.",
                  icon: Icons.auto_awesome,
                  color: const Color(0xFF39FF14),
                  onTap: (dirState.currentPath.isEmpty || isBusy)
                      ? null
                      : () => _executeAutoPipeline(ref, dirState.currentPath),
                ),
                _buildActionCard(
                  title: "2. Motor NLP (Letras)",
                  description: "Scraping masivo de .lrc para Mezcla Semántica.",
                  icon: Icons.lyrics,
                  color: const Color(0xFFFFD700),
                  onTap: (dirState.currentPath.isEmpty || isBusy)
                      ? null
                      : () => ref
                            .read(nlpWorkerProvider)
                            .processDirectory(
                              dirState.currentPath,
                              isCancelled: () =>
                                  ref.read(pipelineProvider).isAborted,
                            ),
                ),
                _buildActionCard(
                  title: "3. Motor DSP (Géneros y Curvas)",
                  description:
                      "Escaneo FFprobe para inyectar curvas de crossfade y timing.",
                  icon: Icons.graphic_eq,
                  color: const Color(0xFF00FFFF),
                  onTap: (dirState.currentPath.isEmpty || isBusy)
                      ? null
                      : () => _executeBatchDSP(ref, dirState.currentPath),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    final bool isDisabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(15), // 🛠️ Padding compacto
        decoration: BoxDecoration(
          color: isDisabled ? Colors.black26 : const Color(0xFF1A1A1A),
          border: Border.all(
            color: isDisabled ? Colors.white10 : color.withOpacity(0.5),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 30,
              color: isDisabled ? Colors.white24 : color,
            ), // 🛠️ Icono escalado
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14, // 🛠️ Fuente optimizada
                      fontWeight: FontWeight.bold,
                      color: isDisabled ? Colors.white38 : Colors.white,
                    ),
                    maxLines: 1, // 🛠️ Blindaje contra desbordamientos
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 11, // 🛠️ Fuente optimizada
                      color: isDisabled ? Colors.white24 : Colors.white70,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

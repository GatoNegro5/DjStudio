import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// 🛠️ INYECTADO: Backend FFI Nativo (Reemplazo de FFprobeKit)
import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;

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

  void _showSummaryDialog(
    BuildContext context,
    String title,
    int total,
    List<String> failedTracks,
  ) {
    final successCount = total - failedTracks.length;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFF39FF14)),
          borderRadius: BorderRadius.circular(8),
        ),
        title: Row(
          children: [
            const Icon(Icons.fact_check, color: Color(0xFF39FF14)),
            const SizedBox(width: 10),
            Text(
              "Reporte: $title",
              style: const TextStyle(
                color: Color(0xFF39FF14),
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: failedTracks.isEmpty ? 100 : 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "✅ Procesados con éxito: $successCount / $total",
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              if (failedTracks.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  "❌ Archivos con error o saltados (Cuarentena):",
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      border: Border.all(color: Colors.white10),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ListView.builder(
                      itemCount: failedTracks.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            "• ${failedTracks[index]}",
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontFamily: 'Consolas',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF39FF14),
              foregroundColor: Colors.black,
            ),
            child: const Text(
              "Entendido",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _executeAutoPipeline(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
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
      final state = ref.read(pipelineProvider);
      if (context.mounted && state.total > 0) {
        _showSummaryDialog(
          context,
          "Pipeline Maestro",
          state.total,
          state.quarantinedTracks,
        );
      }
      pipe.reset();
      ref.read(directoryProvider.notifier).scanPath(targetPath);
    }
  }

  Future<void> _executeBatchDSP(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    // Veto Técnico: Arquitectura Móvil carece de binarios de inyección directa
    if (Platform.isAndroid || Platform.isIOS) {
      debugPrint(
        "⚠️ [DSP WORKSPACE BYPASS] Análisis bloqueado en Sandbox móvil.",
      );
      return;
    }

    final pipe = ref.read(pipelineProvider.notifier);
    final dir = Directory(targetPath);

    if (!dir.existsSync()) return;
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    try {
      pipe.updateProgress(0, 1, "", "Fase DSP: Escaneando archivos .mp3...");
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mp3'))
          .toList();
      final int total = files.length;

      if (total == 0) return;

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
          "Fase DSP: Analizando Tags ID3 (Rust FFI)",
        );

        String assignedProfile = 'constant_power';
        int assignedDuration = 6000;

        // 🛠️ FIX: Llamada directa al puente de memoria C++
        final rawGenre = await rust_dsp.readAudioGenre(inputPath: path);

        if (rawGenre.isNotEmpty && rawGenre != 'desconocido') {
          for (final key in mixProfiles.keys) {
            if (rawGenre.contains(key)) {
              assignedProfile = mixProfiles[key]!['curve'] as String;
              assignedDuration = mixProfiles[key]!['durationMs'] as int;
              break;
            }
          }
        }

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
      final state = ref.read(pipelineProvider);
      if (context.mounted && state.total > 0) {
        _showSummaryDialog(
          context,
          "Motor DSP (Géneros y Curvas)",
          state.total,
          state.quarantinedTracks,
        );
      }
      pipe.reset();
    }
  }

  // 🛠️ SEPARACIÓN: Purga de Infraestructura (Audio)
  Future<void> _executePurgePipeline(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    try {
      await ref
          .read(dspWorkerProvider)
          .clearPipelineWatermarks(targetPath, isCancelled: checkAbort);
    } catch (e) {
      debugPrint("🔴 [PURGE PIPELINE ERROR]: $e");
    } finally {
      final state = ref.read(pipelineProvider);
      if (context.mounted && state.total > 0) {
        _showSummaryDialog(
          context,
          "Purga de Audio (Reset Firmas)",
          state.total,
          state.quarantinedTracks,
        );
      }
      pipe.reset();
    }
  }

  // 🛠️ SEPARACIÓN: Purga de Base de Datos (ISAR)
  Future<void> _executePurgeISAR(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    try {
      await ref
          .read(dspWorkerProvider)
          .clearIsarDspData(targetPath, isCancelled: checkAbort);
    } catch (e) {
      debugPrint("🔴 [PURGE ISAR ERROR]: $e");
    } finally {
      final state = ref.read(pipelineProvider);
      if (context.mounted && state.total > 0) {
        _showSummaryDialog(
          context,
          "Purga de Base de Datos ISAR",
          state.total,
          state.quarantinedTracks,
        );
      }
      pipe.reset();
    }
  }

  Future<void> _executeNLP(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    try {
      await ref
          .read(nlpWorkerProvider)
          .processDirectory(targetPath, isCancelled: checkAbort);
    } catch (e) {
      debugPrint("🔴 [NLP ERROR FATAL]: $e");
    } finally {
      final state = ref.read(pipelineProvider);
      if (context.mounted && state.total > 0) {
        _showSummaryDialog(
          context,
          "Motor NLP (Letras)",
          state.total,
          state.quarantinedTracks,
        );
      }
      pipe.reset();
    }
  }

  void _showQuickFolderMenu(
    BuildContext rootContext,
    WidgetRef ref,
    String currentPath,
  ) {
    Directory baseDir;
    if (currentPath.isNotEmpty) {
      baseDir = Directory(currentPath).parent;
    } else {
      if (Platform.isWindows) {
        baseDir = Directory('${Platform.environment['USERPROFILE']}\\Music');
      } else if (Platform.isMacOS || Platform.isLinux) {
        baseDir = Directory('${Platform.environment['HOME']}/Music');
      } else {
        baseDir = Directory('/storage/emulated/0/Music');
      }
    }

    List<FileSystemEntity> subFolders = [];
    if (baseDir.existsSync()) {
      subFolders = baseDir.listSync().whereType<Directory>().toList();
      subFolders.sort((a, b) => a.path.compareTo(b.path));
    }

    showDialog(
      context: rootContext,
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
                          _executeAutoPipeline(rootContext, ref, folder.path);
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
                "Usar Explorador de Sistema",
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
              crossAxisSpacing: 15,
              mainAxisSpacing: 15,
              childAspectRatio: 4.0,
              children: [
                _buildActionCard(
                  title: "1. Pipeline Maestro (Audio + Nomenclatura)",
                  description:
                      "Ejecución atómica: Limpieza Regex, EBU R128 y Render BPM.",
                  icon: Icons.auto_awesome,
                  color: const Color(0xFF39FF14),
                  onTap: (dirState.currentPath.isEmpty || isBusy)
                      ? null
                      : () => _executeAutoPipeline(
                          context,
                          ref,
                          dirState.currentPath,
                        ),
                ),
                _buildActionCard(
                  title: "2. Motor NLP (Letras)",
                  description: "Scraping masivo de .lrc para Mezcla Semántica.",
                  icon: Icons.lyrics,
                  color: const Color(0xFFFFD700),
                  onTap: (dirState.currentPath.isEmpty || isBusy)
                      ? null
                      : () => _executeNLP(context, ref, dirState.currentPath),
                ),
                _buildActionCard(
                  title: "3. Motor DSP (Géneros y Curvas)",
                  description:
                      "Escaneo nativo C++ para inyectar curvas de crossfade y timing.",
                  icon: Icons.graphic_eq,
                  color: const Color(0xFF00FFFF),
                  onTap: (dirState.currentPath.isEmpty || isBusy)
                      ? null
                      : () => _executeBatchDSP(
                          context,
                          ref,
                          dirState.currentPath,
                        ),
                ),
                _buildActionCard(
                  title: "4. Purgar Pipeline (Audio)",
                  description:
                      "Destruye atómicamente la firma ID3v2 para forzar el reprocesamiento físico.",
                  icon: Icons.recycling,
                  color: Colors.redAccent,
                  onTap: (dirState.currentPath.isEmpty || isBusy)
                      ? null
                      : () => _executePurgePipeline(
                          context,
                          ref,
                          dirState.currentPath,
                        ),
                ),
                _buildActionCard(
                  title: "5. Purgar Curvas DSP (Base de Datos)",
                  description:
                      "Elimina los Cues y curvas de mezcla guardados en ISAR.",
                  icon: Icons.delete_forever,
                  color: Colors.orangeAccent,
                  onTap: (dirState.currentPath.isEmpty || isBusy)
                      ? null
                      : () => _executePurgeISAR(
                          context,
                          ref,
                          dirState.currentPath,
                        ),
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
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: isDisabled ? Colors.black26 : const Color(0xFF1A1A1A),
          border: Border.all(
            color: isDisabled ? Colors.white10 : color.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 30, color: isDisabled ? Colors.white24 : color),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isDisabled ? Colors.white38 : Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 11,
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

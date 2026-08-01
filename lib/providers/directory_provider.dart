import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'cache_provider.dart';
import 'package:flutter/foundation.dart';

class DirectoryState {
  final String currentPath;
  final List<File> files;
  final bool isProcessing;

  DirectoryState({
    this.currentPath = '',
    this.files = const [],
    this.isProcessing = false,
  });

  DirectoryState copyWith({
    String? currentPath,
    List<File>? files,
    bool? isProcessing,
  }) {
    return DirectoryState(
      currentPath: currentPath ?? this.currentPath,
      files: files ?? this.files,
      isProcessing: isProcessing ?? this.isProcessing,
    );
  }
}

class DirectoryNotifier extends Notifier<DirectoryState> {
  @override
  DirectoryState build() {
    _initPersistence();
    return DirectoryState();
  }

  // Lectura del Caché en el Bootloader de Riverpod
  Future<void> _initPersistence() async {
    final cache = await StaticCache.load();
    final lastDir = cache['directory'] as String?;

    // Solo carga si la ruta sigue existiendo físicamente en NTFS
    if (lastDir != null && Directory(lastDir).existsSync()) {
      await scanPath(lastDir);
    }
  }

  // Intervención del Selector Nativo con guardado Atómico
  Future<void> loadDirectory() async {
    if (state.isProcessing) return;

    final String? selectedDirectory = await getDirectoryPath();

    if (selectedDirectory != null) {
      await StaticCache.save(directory: selectedDirectory);
      await scanPath(selectedDirectory);
    }
  }

  // Refresco silencioso de I/O (Sin disparar ventana modal)
  Future<void> refreshCurrentPath() async {
    if (state.currentPath.isNotEmpty) {
      await scanPath(state.currentPath);
    }
  }

  // Motor de Escaneo I/O Estricto y Garbage Collector (Público)
  Future<void> scanPath(String path) async {
    state = state.copyWith(isProcessing: true, currentPath: path);

    try {
      final dir = Directory(path);
      final List<File> targetFiles = [];
      final Set<String> validAudioBases = {};
      final List<File> lrcFiles = [];

      // 🛠️ FIX: Scoped Storage Crash Bypass.
      final stream = dir.list(recursive: true, followLinks: false).handleError((
        e,
      ) {
        debugPrint("⚠️ [I/O Ignorado en Scoped Storage]: $e");
      });

      await for (final entity in stream) {
        if (entity is File) {
          final lowerPath = entity.path.toLowerCase();
          // 🛠️ FIX: Expansión de extensiones (.m4a, .wav)
          if (lowerPath.endsWith('.mp3') ||
              lowerPath.endsWith('.webm') ||
              lowerPath.endsWith('.m4a') ||
              lowerPath.endsWith('.wav')) {
            targetFiles.add(entity);
            // Mapeo en RAM del nombre base para contrastar huérfanos
            validAudioBases.add(
              entity.path.replaceAll(
                RegExp(r'\.mp3$|\.webm$|\.m4a$|\.wav$', caseSensitive: false),
                '',
              ),
            );
          } else if (lowerPath.endsWith('.lrc')) {
            lrcFiles.add(entity);
          }
        }
      }

      // Garbage Collector: Purga atómica de letras huérfanas en NTFS / Scoped Storage
      for (final lrc in lrcFiles) {
        final baseName = lrc.path.replaceAll(
          RegExp(r'\.lrc$', caseSensitive: false),
          '',
        );
        if (!validAudioBases.contains(baseName)) {
          try {
            await lrc.delete();
            debugPrint(
              "🧹 [Garbage Collector] Archivo .lrc huérfano purgado: ${lrc.path}",
            );
          } catch (_) {}
        }
      }

      // Ordenamiento alfabético estricto para mantener la cohesión de los índices en el Deck
      targetFiles.sort(
        (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
      );
      state = state.copyWith(files: targetFiles, isProcessing: false);
    } catch (e) {
      debugPrint("🔴 [SCAN FATAL ERROR]: $e");
      state = state.copyWith(isProcessing: false, files: []);
    }
  }
}

final directoryProvider = NotifierProvider<DirectoryNotifier, DirectoryState>(
  DirectoryNotifier.new,
);

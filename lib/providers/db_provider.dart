import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import '../models/track_metadata.dart'; // Ajusta la ruta si es necesario

// 1. Proveedor Asíncrono: Inicializa la DB en el Sandbox del OS
final isarInitProvider = FutureProvider<Isar>((ref) async {
  // path_provider resuelve la ruta segura automáticamente en Win/Mac/iOS/Android
  final dir = await getApplicationDocumentsDirectory();

  if (Isar.instanceNames.isEmpty) {
    return await Isar.open([TrackMetadataSchema], directory: dir.path);
  }
  return Isar.getInstance()!;
});

// 2. Proveedor de Servicio: Inyecta los métodos CRUD al resto de la App
final dbServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService(ref);
});

// 3. Capa Lógica (Operaciones Atómicas NoSQL)
class DatabaseService {
  final Ref ref;
  DatabaseService(this.ref);

  // Implementación de Patrón UPSERT (Update or Insert)
  Future<void> saveTrackMetadata({
    required String path,
    String? mixProfile,
    int? durationMs,
    String? genre,
    int? cueInMs,
    int? mixOutMs,
    bool clearCues = false,
  }) async {
    final isar = await ref.read(isarInitProvider.future);

    await isar.writeTxn(() async {
      final existing = await isar.trackMetadatas.getByFilePath(path);

      final track = TrackMetadata()
        ..filePath = path
        ..mixProfile = mixProfile ?? existing?.mixProfile ?? 'constant_power'
        ..mixDurationMs = durationMs ?? existing?.mixDurationMs ?? 6000
        ..genreAssigned = genre ?? existing?.genreAssigned ?? 'desconocido'
        ..cueInMs = clearCues ? null : (cueInMs ?? existing?.cueInMs)
        ..mixOutMs = clearCues ? null : (mixOutMs ?? existing?.mixOutMs);

      await isar.trackMetadatas.putByFilePath(track);
    });
  }

  Future<TrackMetadata?> getTrackMetadata(String path) async {
    final isar = await ref.read(isarInitProvider.future);
    return await isar.trackMetadatas.getByFilePath(path);
  }

  // 🛠️ INYECCIÓN: Borrado Atómico Nuclear (Limpieza de I/O)
  Future<void> deleteTrackMetadata(String path) async {
    final isar = await ref.read(isarInitProvider.future);
    await isar.writeTxn(() async {
      await isar.trackMetadatas.deleteByFilePath(path);
    });
  }
}

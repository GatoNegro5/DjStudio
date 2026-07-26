import 'dart:io';
import 'dart:convert';

// 1. Diccionario de Perfiles (Engine Config)
final Map<String, Map<String, dynamic>> mixProfiles = {
  'reggaeton': {'curve': 'eq_kill', 'durationMs': 4000},
  'salsa': {'curve': 'sharp', 'durationMs': 2000},
  'merengue': {'curve': 'sharp', 'durationMs': 2500},
  'balada': {'curve': 'linear', 'durationMs': 8000},
  'rock': {'curve': 'constant_power', 'durationMs': 3500},
  'cumbia': {'curve': 'constant_power', 'durationMs': 3000},
  'default': {'curve': 'constant_power', 'durationMs': 6000},
};

Future<void> main() async {
  // 🛠️ RUTA DE PRUEBA: Cambia esto por un MP3 real en tu disco
  final testFile =
      r"C:\Users\ASUS\Music\ReGenial\80s Espanol\Vilma Palma E Vampiros - Mojada.mp3";

  print("🟢 [SANDBOX] Iniciando escaneo FFprobe en: $testFile");

  final file = File(testFile);
  if (!file.existsSync()) {
    print("🔴 [FATAL]: El archivo físico no existe. Revisa la ruta.");
    return;
  }

  try {
    // Disparamos FFprobe por debajo de la mesa pidiendo salida JSON pura
    final result = await Process.run('ffprobe', [
      '-v',
      'quiet',
      '-print_format',
      'json',
      '-show_format',
      testFile,
    ]);

    if (result.exitCode != 0) {
      print("🔴 [ERROR FFPROBE]: ${result.stderr}");
      return;
    }

    final data = jsonDecode(result.stdout);
    final tags = data['format']['tags'] as Map<String, dynamic>?;

    String genreAssigned = 'default';

    if (tags != null) {
      // Búsqueda insensible a mayúsculas del tag de género
      final genreTagKey = tags.keys.firstWhere(
        (k) => k.toLowerCase() == 'genre',
        orElse: () => '',
      );

      if (genreTagKey.isNotEmpty) {
        final rawGenre = tags[genreTagKey].toString().toLowerCase();
        print("🟡 [METADATA] Género crudo extraído del ID3: $rawGenre");

        // Heurística de emparejamiento (Fuzzy Matching)
        for (final key in mixProfiles.keys) {
          if (rawGenre.contains(key)) {
            genreAssigned = key;
            break;
          }
        }
      } else {
        print(
          "🟡 [METADATA] El archivo no tiene tag de Género. Se aplicará Default.",
        );
      }
    }

    print("✅ [PERFIL ASIGNADO]: $genreAssigned");
    print("⚙️  [PARÁMETROS MATEMÁTICOS]: ${mixProfiles[genreAssigned]}");
  } catch (e) {
    print("🔴 [FATAL]: Error en tiempo de ejecución: $e");
  }
}

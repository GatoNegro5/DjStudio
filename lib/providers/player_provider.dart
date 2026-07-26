import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'cache_provider.dart';
import 'db_provider.dart'; // 🛠️ INYECCIÓN ISAR
import 'package:flutter/foundation.dart';

enum MixStrategy { sequential, random }

class LyricLine {
  final Duration timestamp;
  final String text;
  LyricLine({required this.timestamp, required this.text});
}

class PlayerState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final List<String> playlist;
  final int currentIndex;

  final String? currentTrackPath;

  final List<LyricLine> lyrics;
  final int activeLyricIndex;

  final String? nextTrackPath;
  final int triggerRemainingMs;
  final MixStrategy mixStrategy;

  final int customCueInMs;
  final int customMixOutMs;
  final bool autoMixArmed;

  PlayerState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playlist = const [],
    this.currentIndex = -1,
    this.currentTrackPath,
    this.lyrics = const [],
    this.activeLyricIndex = -1,
    this.nextTrackPath,
    this.triggerRemainingMs = 4000,
    this.mixStrategy = MixStrategy.sequential,
    this.customCueInMs = -1,
    this.customMixOutMs = -1,
    this.autoMixArmed = true,
  });

  PlayerState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    List<String>? playlist,
    int? currentIndex,
    String? currentTrackPath,
    List<LyricLine>? lyrics,
    int? activeLyricIndex,
    String? nextTrackPath,
    int? triggerRemainingMs,
    MixStrategy? mixStrategy,
    int? customCueInMs,
    int? customMixOutMs,
    bool? autoMixArmed,
  }) {
    return PlayerState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playlist: playlist ?? this.playlist,
      currentIndex: currentIndex ?? this.currentIndex,
      currentTrackPath: currentTrackPath ?? this.currentTrackPath,
      lyrics: lyrics ?? this.lyrics,
      activeLyricIndex: activeLyricIndex ?? this.activeLyricIndex,
      nextTrackPath: nextTrackPath ?? this.nextTrackPath,
      triggerRemainingMs: triggerRemainingMs ?? this.triggerRemainingMs,
      mixStrategy: mixStrategy ?? this.mixStrategy,
      customCueInMs: customCueInMs ?? this.customCueInMs,
      customMixOutMs: customMixOutMs ?? this.customMixOutMs,
      autoMixArmed: autoMixArmed ?? this.autoMixArmed,
    );
  }
}

class PlayerNotifier extends Notifier<PlayerState> {
  late final Player _playerA;
  late final Player _playerB;
  bool _usePlayerA = true;

  Player get _activePlayer => _usePlayerA ? _playerA : _playerB;
  Player get _standbyPlayer => _usePlayerA ? _playerB : _playerA;

  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;

  bool _isCrossfading = false;
  int _triggerRemainingMs = 4000;

  bool _isPrepModeBypass = false;

  @override
  PlayerState build() {
    _playerA = Player();
    _playerB = Player();
    _attachListeners(_playerA);
    _initPersistence();

    ref.onDispose(() {
      _positionSub?.cancel();
      _durationSub?.cancel();
      _playingSub?.cancel();
      _playerA.dispose();
      _playerB.dispose();
    });

    return PlayerState();
  }

  void setMixStrategy(MixStrategy strategy) {
    state = state.copyWith(mixStrategy: strategy);
    _recalculateMixWindow();
  }

  void toggleAutoMixBypass() {
    state = state.copyWith(autoMixArmed: !state.autoMixArmed);
  }

  void syncDynamicPlaylist(List<String> newPlaylistOrdered) {
    if (listEquals(state.playlist, newPlaylistOrdered)) return;
    int newCurrentIndex = -1;
    if (state.currentTrackPath != null) {
      newCurrentIndex = newPlaylistOrdered.indexOf(state.currentTrackPath!);
    }
    state = state.copyWith(
      playlist: newPlaylistOrdered,
      currentIndex: newCurrentIndex,
    );
    _saveLastState(newPlaylistOrdered, newCurrentIndex);
    _recalculateMixWindow();
  }

  Future<List<Map<String, dynamic>>> searchLyrics(String query) async {
    List<Map<String, dynamic>> allResults = [];
    try {
      final uriGlobal = Uri.parse(
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(query.trim())}',
      );
      final resGlobal = await http
          .get(uriGlobal)
          .timeout(const Duration(seconds: 5));
      if (resGlobal.statusCode == 200) {
        allResults.addAll(
          List<Map<String, dynamic>>.from(jsonDecode(resGlobal.body)),
        );
      }

      if (!query.contains('-')) {
        final uriArtist = Uri.parse(
          'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(query.trim())}',
        );
        final resArtist = await http
            .get(uriArtist)
            .timeout(const Duration(seconds: 5));
        if (resArtist.statusCode == 200) {
          allResults.addAll(
            List<Map<String, dynamic>>.from(jsonDecode(resArtist.body)),
          );
        }
      } else {
        final parts = query.split('-');
        final artist = parts[0].trim();
        final track = parts.sublist(1).join(' ').trim();
        final uriAdvanced = Uri.parse(
          'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(artist)}&track_name=${Uri.encodeComponent(track)}',
        );
        final resAdvanced = await http
            .get(uriAdvanced)
            .timeout(const Duration(seconds: 5));
        if (resAdvanced.statusCode == 200) {
          allResults.addAll(
            List<Map<String, dynamic>>.from(jsonDecode(resAdvanced.body)),
          );
        }
      }

      final uniqueById = <int, Map<String, dynamic>>{};
      for (var item in allResults) {
        if (item['id'] != null) uniqueById[item['id']] = item;
      }
      return uniqueById.values.toList();
    } catch (_) {}
    return [];
  }

  Future<void> applyManualLyrics(String audioPath, String syncedLyrics) async {
    try {
      final lrcPath = audioPath.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      await File(lrcPath).writeAsString(syncedLyrics);
      if (state.currentTrackPath == audioPath) {
        await _loadLyrics(audioPath);
      }
    } catch (_) {}
  }

  // 🛠️ INYECCIÓN ISAR: Escritura Atómica DB
  Future<void> setMixPoint(String type) async {
    if (state.currentTrackPath == null) return;

    final currentPosMs = state.position.inMilliseconds;
    final db = ref.read(dbServiceProvider);

    if (type == 'IN') {
      await db.saveTrackMetadata(
        path: state.currentTrackPath!,
        cueInMs: currentPosMs,
      );
      state = state.copyWith(customCueInMs: currentPosMs);
    } else {
      await db.saveTrackMetadata(
        path: state.currentTrackPath!,
        mixOutMs: currentPosMs,
      );
      state = state.copyWith(customMixOutMs: currentPosMs, autoMixArmed: true);
      _recalculateMixWindow();

      if (!state.isPlaying) {
        _isPrepModeBypass = true;
      }
    }
  }

  // 🛠️ INYECCIÓN ISAR: Purga Atómica DB
  Future<void> clearMixPoints() async {
    if (state.currentTrackPath == null) return;

    await ref
        .read(dbServiceProvider)
        .saveTrackMetadata(path: state.currentTrackPath!, clearCues: true);

    state = state.copyWith(
      customCueInMs: -1,
      customMixOutMs: -1,
      autoMixArmed: true,
    );
    _recalculateMixWindow();
  }

  // 🛠️ INYECCIÓN ISAR: Lectura Submilisegundo DB
  Future<void> _loadTrackMetadata(String audioPath) async {
    final metadata = await ref
        .read(dbServiceProvider)
        .getTrackMetadata(audioPath);

    state = state.copyWith(
      customCueInMs: metadata?.cueInMs ?? -1,
      customMixOutMs: metadata?.mixOutMs ?? -1,
      autoMixArmed: true,
    );
    _recalculateMixWindow();
  }

  void _attachListeners(Player player) {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();

    _positionSub = player.stream.position.listen((pos) {
      int newLyricIndex = -1;
      if (state.lyrics.isNotEmpty) {
        for (int i = state.lyrics.length - 1; i >= 0; i--) {
          if (pos >= state.lyrics[i].timestamp) {
            newLyricIndex = i;
            break;
          }
        }
      }

      state = state.copyWith(
        position: pos,
        activeLyricIndex: newLyricIndex,
        triggerRemainingMs: _triggerRemainingMs,
      );

      if (state.autoMixArmed &&
          !_isCrossfading &&
          state.duration.inMilliseconds > 0 &&
          state.nextTrackPath != null) {
        int timeRemaining = state.duration.inMilliseconds - pos.inMilliseconds;

        if (timeRemaining > _triggerRemainingMs) {
          _isPrepModeBypass = false;
        }

        if (timeRemaining <= _triggerRemainingMs) {
          if (!_isPrepModeBypass) {
            _triggerCrossfade();
          }
        }
      }
    });

    _durationSub = player.stream.duration.listen((dur) {
      state = state.copyWith(duration: dur);
      _recalculateMixWindow();
    });

    _playingSub = player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });
  }

  Future<void> seek(Duration position) async {
    if (state.currentTrackPath == null || _isCrossfading) return;
    _isPrepModeBypass = false;
    await _activePlayer.seek(position);
  }

  Future<void> jumpToTrack(int index) async {
    if (index < 0 || index >= state.playlist.length) return;
    if (state.currentIndex == index && state.isPlaying) return;

    _isCrossfading = false;
    _isPrepModeBypass = false;

    final path = state.playlist[index];
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    state = state.copyWith(
      currentIndex: index,
      currentTrackPath: path,
      position: Duration.zero,
      duration: Duration.zero,
      customCueInMs: -1,
      customMixOutMs: -1,
    );
    await _saveLastState(state.playlist, index);
    await _loadLyrics(path);
    await _loadTrackMetadata(path);

    await incomingPlayer.setVolume(100.0);
    await incomingPlayer.open(Media(path), play: true);

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activePlayer);
    _executeQuickFadeOut(fadingPlayer);
  }

  Future<void> _executeQuickFadeOut(Player player) async {
    double vol = 100.0;
    for (int i = 0; i < 15; i++) {
      vol -= 6.6;
      await player.setVolume(vol.clamp(0.0, 100.0));
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await player.stop();
    await player.setVolume(100.0);
  }

  int _calculateNextIndex() {
    if (state.playlist.isEmpty) return -1;
    if (state.mixStrategy == MixStrategy.random)
      return Random().nextInt(state.playlist.length);
    return (state.currentIndex + 1) < state.playlist.length
        ? state.currentIndex + 1
        : (state.currentIndex == -1 ? 0 : -1);
  }

  Future<void> _loadLyrics(String audioPath) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);

    if (lrcFile.existsSync()) {
      try {
        final lines = await lrcFile.readAsLines();
        final List<LyricLine> parsedLyrics = [];
        final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

        for (var line in lines) {
          final match = regex.firstMatch(line);
          if (match != null) {
            final min = int.parse(match.group(1)!);
            final sec = int.parse(match.group(2)!);
            int ms = int.parse(match.group(3)!);
            if (match.group(3)!.length == 2) ms *= 10;
            final duration = Duration(
              minutes: min,
              seconds: sec,
              milliseconds: ms,
            );
            final text = match.group(4)!.trim();
            if (text.isNotEmpty)
              parsedLyrics.add(LyricLine(timestamp: duration, text: text));
          }
        }
        state = state.copyWith(lyrics: parsedLyrics, activeLyricIndex: -1);
      } catch (_) {
        state = state.copyWith(lyrics: [], activeLyricIndex: -1);
      }
    } else {
      state = state.copyWith(lyrics: [], activeLyricIndex: -1);
      _fetchLyricsAsync(audioPath, lrcPath);
    }
  }

  Future<void> _fetchLyricsAsync(String audioPath, String lrcPath) async {
    try {
      String rawFilename = audioPath.replaceAll('\\', '/').split('/').last;
      rawFilename = rawFilename.replaceAll(
        RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
        '',
      );

      String cleanQuery = rawFilename.replaceAll(
        RegExp(r'\[.*?\]|\(.*?\)', caseSensitive: false),
        '',
      );
      cleanQuery = cleanQuery.replaceAll(
        RegExp(
          r'\b(official|video|audio|lyric|lyrics|remix|live|kbps|hd|hq)\b',
          caseSensitive: false,
        ),
        '',
      );
      cleanQuery = cleanQuery.replaceAll(RegExp(r'\s+'), ' ').trim();

      if (cleanQuery.isEmpty) cleanQuery = rawFilename;

      final uri = Uri.parse(
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(cleanQuery)}',
      );
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        if (data.isNotEmpty) {
          data.sort((a, b) {
            final aSync = a['syncedLyrics']?.toString().isNotEmpty ?? false;
            final bSync = b['syncedLyrics']?.toString().isNotEmpty ?? false;
            if (aSync && !bSync) return -1;
            if (!aSync && bSync) return 1;
            return 0;
          });

          if (data[0]['syncedLyrics'] != null &&
              data[0]['syncedLyrics'].toString().isNotEmpty) {
            await File(lrcPath).writeAsString(data[0]['syncedLyrics']);
            if (state.currentTrackPath == audioPath)
              await _loadLyrics(audioPath);
          }
        }
      }
    } catch (_) {}
  }

  // 🛠️ INYECCIÓN ISAR: Cálculo predictivo refactorizado a Asíncrono
  Future<void> _recalculateMixWindow() async {
    if (state.duration.inMilliseconds == 0) return;

    final nextIdx = _calculateNextIndex();
    final nextPath = nextIdx != -1 ? state.playlist[nextIdx] : null;
    state = state.copyWith(nextTrackPath: nextPath);

    int dynamicMixDurationMs = 6000;
    if (nextPath != null) {
      final nextMeta = await ref
          .read(dbServiceProvider)
          .getTrackMetadata(nextPath);
      if (nextMeta != null) {
        dynamicMixDurationMs = nextMeta.mixDurationMs;
      }
    }

    if (state.customMixOutMs > 0) {
      _triggerRemainingMs =
          state.duration.inMilliseconds - state.customMixOutMs;
      if (_triggerRemainingMs < dynamicMixDurationMs)
        _triggerRemainingMs = dynamicMixDurationMs;
      state = state.copyWith(triggerRemainingMs: _triggerRemainingMs);
      return;
    }

    bool hasRealLyrics =
        state.lyrics.isNotEmpty &&
        !state.lyrics.any(
          (l) =>
              l.text.contains('Letra no encontrada') ||
              l.text.contains('Error de conexión'),
        );

    if (!hasRealLyrics) {
      _triggerRemainingMs = dynamicMixDurationMs + 2000;
      state = state.copyWith(triggerRemainingMs: _triggerRemainingMs);
      return;
    }

    final lastVocalMs = state.lyrics.last.timestamp.inMilliseconds;
    final idealTriggerPosition = lastVocalMs + 4000;
    _triggerRemainingMs = state.duration.inMilliseconds - idealTriggerPosition;

    if (_triggerRemainingMs < dynamicMixDurationMs)
      _triggerRemainingMs = dynamicMixDurationMs;
    state = state.copyWith(triggerRemainingMs: _triggerRemainingMs);
  }

  // 🛠️ INYECCIÓN ISAR: Motor DSP embebido
  Future<void> _triggerCrossfade() async {
    if (_isCrossfading || state.nextTrackPath == null) return;

    _isCrossfading = true;
    final int nextIndex = _calculateNextIndex();
    if (nextIndex == -1) {
      _isCrossfading = false;
      return;
    }

    final String nextTrack = state.playlist[nextIndex];
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    int cueInMs = 0;
    int mixDurationMs = 6000;
    String mixProfile = 'constant_power';
    bool hasCustomCueIn = false;

    final meta = await ref.read(dbServiceProvider).getTrackMetadata(nextTrack);
    if (meta != null) {
      if (meta.cueInMs != null) {
        cueInMs = meta.cueInMs!;
        hasCustomCueIn = true;
      }
      mixDurationMs = meta.mixDurationMs;
      mixProfile = meta.mixProfile;
    }

    if (!hasCustomCueIn) {
      final lrcFile = File(
        nextTrack.replaceAll(
          RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
          '.lrc',
        ),
      );
      if (lrcFile.existsSync()) {
        try {
          final lines = await lrcFile.readAsLines();
          final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
          for (var line in lines) {
            final match = regex.firstMatch(line);
            if (match != null) {
              final text = match.group(4)!.trim();
              final lowerText = text.toLowerCase();

              bool isGarbage = false;
              if (text.length < 4)
                isGarbage = true;
              else if (lowerText.contains('🎵') || lowerText.contains('♪'))
                isGarbage = true;
              else if (lowerText.startsWith('(') || lowerText.startsWith('['))
                isGarbage = true;
              else if (lowerText.contains('instrumental') ||
                  lowerText.contains('sync') ||
                  lowerText.contains('lyric'))
                isGarbage = true;
              else if (lowerText.contains('letra no encontrada') ||
                  lowerText.contains('error de conexión'))
                isGarbage = true;
              else if (lowerText.contains(' - '))
                isGarbage = true;

              if (!isGarbage) {
                final min = int.parse(match.group(1)!);
                final sec = int.parse(match.group(2)!);
                int ms = int.parse(match.group(3)!);
                if (match.group(3)!.length == 2) ms *= 10;

                int firstVocalMs = ((min * 60000) + (sec * 1000) + ms);
                cueInMs = firstVocalMs - 15000;
                break;
              }
            }
          }
        } catch (_) {}
      }
    }

    if (cueInMs < 0) cueInMs = 0;

    await incomingPlayer.setVolume(0.0);
    await incomingPlayer.open(Media(nextTrack), play: false);
    if (cueInMs > 0) {
      await incomingPlayer.seek(Duration(milliseconds: cueInMs));
    }
    await incomingPlayer.play();

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activePlayer);

    state = state.copyWith(
      currentIndex: nextIndex,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
      duration: Duration.zero,
    );

    await _loadLyrics(nextTrack);
    await _loadTrackMetadata(nextTrack);
    await _saveLastState(state.playlist, nextIndex);

    int steps = mixDurationMs ~/ 100;
    if (steps < 10) steps = 10;
    final int stepTimeMs = mixDurationMs ~/ steps;

    for (int i = 0; i < steps; i++) {
      double progress = i / steps;
      double volOut = 100.0;
      double volIn = 100.0;

      if (mixProfile == 'linear') {
        volOut = (1.0 - progress) * 100.0;
        volIn = progress * 100.0;
      } else if (mixProfile == 'sharp') {
        volOut = progress < 0.9
            ? 100.0
            : (1.0 - (progress - 0.9) * 10.0) * 100.0;
        volIn = progress > 0.1 ? 100.0 : (progress * 10.0) * 100.0;
      } else if (mixProfile == 'eq_kill') {
        volOut = pow(1.0 - progress, 2.5) * 100.0;
        volIn = 70.0 + (progress * 30.0);
      } else {
        volOut = cos(progress * (pi / 2)) * 100.0;
        volIn = sin(progress * (pi / 2)) * 100.0;
      }

      await fadingPlayer.setVolume(volOut.clamp(0.0, 100.0));
      await incomingPlayer.setVolume(volIn.clamp(0.0, 100.0));
      await Future.delayed(Duration(milliseconds: stepTimeMs));
    }

    await fadingPlayer.stop();
    await fadingPlayer.setVolume(100.0);
    await incomingPlayer.setVolume(100.0);
    _isCrossfading = false;
  }

  Future<void> _initPersistence() async {
    final cache = await StaticCache.load();
    final playlist = (cache['playlist'] as List?)?.cast<String>();
    final index = cache['trackIndex'] as int?;
    final positionMs = cache['positionMs'] as int?;

    if (playlist != null &&
        playlist.isNotEmpty &&
        index != null &&
        index >= 0) {
      state = state.copyWith(
        playlist: playlist,
        currentIndex: index,
        currentTrackPath: playlist[index],
      );
      await _loadLyrics(playlist[index]);
      await _loadTrackMetadata(playlist[index]);

      await _activePlayer.open(Media(playlist[index]), play: false);

      if (positionMs != null && positionMs > 0) {
        await _activePlayer.seek(Duration(milliseconds: positionMs));
      }
    }
  }

  Future<void> _saveLastState(List<String> playlist, int index) async {
    await StaticCache.save(
      playlist: playlist,
      trackIndex: index,
      positionMs: state.position.inMilliseconds,
    );
  }

  Future<void> loadContextAndPlay(List<String> playlist, int startIndex) async {
    _isPrepModeBypass = false;
    state = state.copyWith(
      playlist: playlist,
      currentIndex: startIndex,
      currentTrackPath: playlist[startIndex],
      customCueInMs: -1,
      customMixOutMs: -1,
      autoMixArmed: true,
    );
    await _saveLastState(playlist, startIndex);
    final path = playlist[startIndex];
    await _loadLyrics(path);
    await _loadTrackMetadata(path);
    await _activePlayer.setVolume(100.0);
    await _activePlayer.open(Media(path), play: true);
  }

  Future<void> togglePlayPause() async {
    if (state.currentTrackPath == null) return;
    _isPrepModeBypass = false;
    await _activePlayer.playOrPause();
    if (!state.isPlaying) {
      await StaticCache.save(positionMs: state.position.inMilliseconds);
    }
  }

  Future<void> pause() async {
    if (state.isPlaying) {
      await _activePlayer.pause();
      await StaticCache.save(positionMs: state.position.inMilliseconds);
    }
  }

  Future<void> updateCurrentTrackAndPlay(String newPath) async {
    if (state.currentIndex < 0) return;
    _isPrepModeBypass = false;

    final currentList = List<String>.from(state.playlist);
    currentList[state.currentIndex] = newPath;

    state = state.copyWith(
      playlist: currentList,
      currentTrackPath: newPath,
      nextTrackPath: null,
      customCueInMs: -1,
      customMixOutMs: -1,
      autoMixArmed: true,
    );
    await _saveLastState(currentList, state.currentIndex);
    await _loadLyrics(newPath);
    await _loadTrackMetadata(newPath);

    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    await incomingPlayer.setVolume(100.0);
    await incomingPlayer.open(Media(newPath), play: true);

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activePlayer);
    _executeQuickFadeOut(fadingPlayer);
  }

  Future<void> stopAndRelease() async {
    try {
      await _playerA.stop();
    } catch (_) {}
    try {
      await _playerB.stop();
    } catch (_) {}
    _isCrossfading = false;
    await Future.delayed(const Duration(milliseconds: 600));
  }

  Future<void> autoSyncFirstLyric() async {
    if (state.currentTrackPath == null || state.lyrics.isEmpty) return;

    final firstLyric = state.lyrics.firstWhere(
      (l) =>
          !l.text.contains('Letra no encontrada') && !l.text.contains('Error'),
      orElse: () => LyricLine(timestamp: Duration.zero, text: ''),
    );

    if (firstLyric.text.isEmpty) return;

    final int originalStartMs = firstLyric.timestamp.inMilliseconds;
    final int currentAudioMs = state.position.inMilliseconds;
    final int calculatedOffsetMs = currentAudioMs - originalStartMs;
    await shiftLyrics(calculatedOffsetMs);
  }

  Future<void> shiftLyrics(int offsetMs) async {
    if (state.currentTrackPath == null) return;

    final lrcPath = state.currentTrackPath!.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);
    if (!file.existsSync()) return;

    try {
      final lines = await file.readAsLines();
      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      final newLines = <String>[];

      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final min = int.parse(match.group(1)!);
          final sec = int.parse(match.group(2)!);
          int ms = int.parse(match.group(3)!);
          if (match.group(3)!.length == 2) ms *= 10;

          int totalMs = (min * 60000) + (sec * 1000) + ms + offsetMs;
          if (totalMs < 0) totalMs = 0;

          final newMin = (totalMs ~/ 60000).toString().padLeft(2, '0');
          final newSec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
          final newMs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
          final text = match.group(4)!;
          newLines.add('[$newMin:$newSec.$newMs]$text');
        } else {
          newLines.add(line);
        }
      }
      await file.writeAsString(newLines.join('\n'));
      await _loadLyrics(state.currentTrackPath!);
    } catch (_) {}
  }
}

final playerProvider = NotifierProvider<PlayerNotifier, PlayerState>(
  PlayerNotifier.new,
);

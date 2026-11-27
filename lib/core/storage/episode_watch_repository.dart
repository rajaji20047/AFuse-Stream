import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/entity/multimedia_item.dart';
import 'history_repository.dart';
import 'storage_service.dart';

final episodeWatchRevisionProvider =
    NotifierProvider<EpisodeWatchRevision, int>(EpisodeWatchRevision.new);

class EpisodeWatchRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() {
    state++;
  }
}

final episodeWatchRepositoryProvider = Provider<EpisodeWatchRepository>((ref) {
  return EpisodeWatchRepository(
    ref.watch(storageServiceProvider),
    ref.watch(historyRepositoryProvider),
    () => ref.read(episodeWatchRevisionProvider.notifier).bump(),
  );
});

class EpisodeWatchRepository {
  EpisodeWatchRepository(
    this._storageService,
    this._historyRepository,
    this._notifyChanged,
  );

  final StorageService _storageService;
  final HistoryRepository _historyRepository;
  final void Function() _notifyChanged;

  static const String _storageKey = 'episode_watch_overrides_v1';

  Map<String, bool>? _cachedOverrides;

  /// The profile [_cachedOverrides] belongs to (M4): the cache is only
  /// valid for the profile that filled it — a switch must re-read.
  String? _cachedProfileId;

  /// Whether the last read parsed cleanly. False when the stored value
  /// would not parse: the next persist must not overwrite it (M5).
  bool _readGood = true;

  /// Serialises read-modify-write (M5): two concurrent ticks must not
  /// interleave at the await and lose one.
  Future<void> _writeChain = Future.value();

  Future<void> _enqueue(Future<void> Function() work) {
    final task = _writeChain.then((_) => work());
    _writeChain = task.then((_) {}, onError: (_) {});
    return task;
  }

  String _episodeKey(String mainUrl, Episode episode) {
    final stableEpisodeId = episode.episode > 0
        ? [episode.season, episode.episode, episode.dubStatus.name].join(':')
        : [episode.url, episode.name, episode.dubStatus.name].join(':');

    return sha256.convert(utf8.encode('$mainUrl|$stableEpisodeId')).toString();
  }

  /// The key for the active profile's overrides (M4): the old single
  /// key was shared by every profile, so a tick in one showed in all.
  /// The bare key stays the logged-out (legacy) store.
  String _overridesKey() {
    final profileId = _storageService.activeFuseProfileId;
    return profileId == null ? _storageKey : '${_storageKey}_$profileId';
  }

  /// Parses the stored overrides under [key]: an empty map when nothing
  /// is stored, null when the stored value will not parse.
  Map<String, bool>? _readStoredMap(String key) {
    final raw = _storageService.getString(key);
    if (raw == null || raw.isEmpty) return <String, bool>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.map<String, bool>(
        (key, value) => MapEntry(key.toString(), value == true),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, bool> _readOverrides() {
    final profileId = _storageService.activeFuseProfileId;
    final cached = _cachedOverrides;
    if (cached != null && _cachedProfileId == profileId) {
      return cached;
    }

    final key = _overridesKey();
    final raw = _storageService.getString(key);
    if ((raw == null || raw.isEmpty) && profileId != null) {
      // A profile that never had its own overrides yet adopts the shared
      // (global) ones once, instead of losing them (M4 migration). A
      // profile whose own key exists — even as an empty map — keeps its
      // own (possibly cleared) state and does not re-adopt.
      final shared = _readStoredMap(_storageKey);
      if (shared != null && shared.isNotEmpty) {
        _readGood = true;
        _cachedProfileId = profileId;
        return _cachedOverrides = shared;
      }
    }
    final stored = _readStoredMap(key);
    if (stored == null) {
      // Unparseable stored value: do not cache the empty map (M5) — a
      // later read must re-read the stored value, not the empty
      // stand-in — and the next persist must not overwrite it.
      _readGood = false;
      return <String, bool>{};
    }
    _readGood = true;
    _cachedProfileId = profileId;
    return _cachedOverrides = stored;
  }

  Future<void> _persist(Map<String, bool> overrides) async {
    // Assign the cache only after the write succeeds (M4): a failed
    // write must not report success in memory. And when the last read
    // would not parse, do not overwrite the stored value with a map
    // built from nothing (M5) — the tick stays in memory for the
    // session, and the stored value survives for a later recovery.
    if (_readGood) {
      await _storageService.setString(_overridesKey(), jsonEncode(overrides));
    }
    _cachedOverrides = overrides;
    _cachedProfileId = _storageService.activeFuseProfileId;
    _notifyChanged();
  }

  bool? getExplicitState(String mainUrl, Episode episode) {
    return _readOverrides()[_episodeKey(mainUrl, episode)];
  }

  bool isWatched(String mainUrl, Episode episode) {
    final explicit = getExplicitState(mainUrl, episode);
    if (explicit != null) {
      return explicit;
    }

    final position = _historyRepository.getEpisodePosition(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    final duration = _historyRepository.getEpisodeDuration(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );

    return duration > 0 && position / duration >= 0.90;
  }

  Future<void> setWatched(String mainUrl, Episode episode, bool watched) {
    return _enqueue(() async {
      final overrides = Map<String, bool>.from(_readOverrides());
      overrides[_episodeKey(mainUrl, episode)] = watched;
      await _persist(overrides);
    });
  }

  Future<void> setManyWatched(
    String mainUrl,
    Iterable<Episode> episodes,
    bool watched,
  ) {
    return _enqueue(() async {
      final overrides = Map<String, bool>.from(_readOverrides());

      for (final episode in episodes) {
        overrides[_episodeKey(mainUrl, episode)] = watched;
      }

      await _persist(overrides);
    });
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../network/clearance/challenge_triage.dart';
import '../../network/clearance/clearance_interceptor.dart';
import '../../network/dio_client_provider.dart';
import '../models/addon_manifest.dart';
import '../models/addon_meta.dart';
import '../models/addon_stream_source.dart';

part 'addon_client.g.dart';

@Riverpod(keepAlive: true)
AddonClient addonClient(Ref ref) => AddonClient(ref.watch(dioClientProvider));

class AddonException implements Exception {
  final String message;
  const AddonException(this.message);
  @override
  String toString() => message;
}

/// An add-on's site refused the connection outright (a Cloudflare block
/// page): no bot check clears it.
class AddonBlockedException extends AddonException {
  AddonBlockedException(this.host)
    : super(
        '$host blocked this connection. VPNs and some networks are often '
        'blocked; try without one.',
      );

  final String host;
}

/// An add-on's site wants a bot check the app couldn't clear by itself:
/// Verify, on the add-on's page, clears it.
class AddonCheckException extends AddonException {
  AddonCheckException(this.host) : super('$host needs a quick check');

  final String host;
}

/// TTL cache with single-flight coalescing.
///
/// Add-on endpoints are pure GETs, so caching them is what makes the tab feel
/// instant on revisits; coalescing means ten widgets asking for the same
/// catalog issue exactly one request.
class _Cache {
  final Map<String, _Entry> _entries = {};
  final Map<String, Future<Object?>> _inFlight = {};
  static const int _maxEntries = 120;

  T? read<T>(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (entry.expiresAt.isBefore(DateTime.now())) {
      _entries.remove(key);
      return null;
    }
    final value = entry.value;
    return value is T ? value : null;
  }

  Future<T> run<T>(String key, Duration ttl, Future<T> Function() task) async {
    final cached = read<T>(key);
    if (cached != null) return cached;

    final pending = _inFlight[key];
    if (pending != null) {
      final value = await pending;
      if (value is T) return value;
    }

    final future = task();
    _inFlight[key] = future;
    try {
      final value = await future;
      if (_entries.length >= _maxEntries) {
        for (final k in _entries.keys.take(_maxEntries ~/ 4).toList()) {
          _entries.remove(k);
        }
      }
      _entries[key] = _Entry(value, DateTime.now().add(ttl));
      return value;
    } finally {
      _inFlight.remove(key)?.ignore();
    }
  }

  void invalidatePrefix(String prefix) =>
      _entries.removeWhere((key, _) => key.startsWith(prefix));

  void clear() => _entries.clear();
}

class _Entry {
  final Object? value;
  final DateTime expiresAt;
  const _Entry(this.value, this.expiresAt);
}

/// Signatures of add-ons that trade in pirate streams. The community
/// directory is largely subtitles/metadata/catalog utilities, but p2p and
/// torrent catalog add-ons do appear in it; Raja does not surface those
/// — they are the copyright problems that get unofficial directories and
/// their users in trouble. (Note these are dropped from Discover only;
/// nothing is blocked server-side, and anything already installed keeps
/// working.)
final RegExp _copyrightRiskPattern = RegExp(
  r'(?:torrent|magnet|p2p|pirate(?:bay)?|yify|rarbg|1337x|1377x|kickass|eztv|limetorrent|h33t|iptv)',
  caseSensitive: false,
);

bool _looksCopyrightRisky(AddonManifest manifest) {
  if (manifest.behaviorHints.p2p) return true;
  final haystack = '${manifest.id} ${manifest.name} ${manifest.description}';
  return _copyrightRiskPattern.hasMatch(haystack);
}

/// Community add-on entry from the stremio-addons.net directory.
class CommunityAddon {
  final String transportUrl;
  final AddonManifest manifest;

  /// Category display names the directory files this add-on under
  /// (e.g. 'Movies', 'Subtitles'); empty when the directory says none.
  final List<String> categories;

  /// Directory stars, shown on the Discover tile's freshness line.
  final int stars;

  /// When the directory last saw this add-on change; null when it did
  /// not say, or the date did not parse.
  final DateTime? updatedAt;

  /// The add-on's own configure page, when the directory lists one;
  /// the Discover tile prefers it over deriving '/configure' itself.
  final String? configureUrl;

  const CommunityAddon({
    required this.transportUrl,
    required this.manifest,
    this.categories = const [],
    this.stars = 0,
    this.updatedAt,
    this.configureUrl,
  });
}

/// One page of the stremio-addons.net directory: the entries on the page
/// plus the cursor for the next page, null on the last page.
///
/// Pure: takes a decoded JSON page and returns entries, so tests can feed
/// it a hand-written payload without Dio.
class StremioAddonsNetPage {
  final List<CommunityAddon> entries;
  final String? nextCursor;

  const StremioAddonsNetPage({required this.entries, this.nextCursor});
}

/// Parses one decoded page of `GET /api/v0/addons`.
///
/// `{"addons": [...], "pagination": {"hasNextPage": bool,
/// "nextCursor": string?}}`. Junk entries are skipped, never fatal — one
/// bad manifest must not sink the whole page.
StremioAddonsNetPage parseStremioAddonsNetPage(Map<String, dynamic> json) {
  final entries = <CommunityAddon>[];
  final rawAddons = json['addons'];
  if (rawAddons is List) {
    for (final raw in rawAddons) {
      if (raw is! Map) continue;
      try {
        final entry = _parseDirectoryEntry(Map<String, dynamic>.from(raw));
        if (entry != null) entries.add(entry);
      } catch (error) {
        // One junk entry must not sink the whole page.
        if (kDebugMode) {
          debugPrint('[AddonClient] directory entry skipped: $error');
        }
      }
    }
  }
  // The cursor only means anything while the server says there is a next
  // page; a stale cursor on the last page is ignored.
  String? nextCursor;
  final rawPagination = json['pagination'];
  if (rawPagination is Map) {
    final pagination = Map<String, dynamic>.from(rawPagination);
    if (pagination['hasNextPage'] == true) {
      final cursor = pagination['nextCursor'] as String?;
      if (cursor != null && cursor.isNotEmpty) nextCursor = cursor;
    }
  }
  return StremioAddonsNetPage(entries: entries, nextCursor: nextCursor);
}

/// One directory entry: the manifest plus the directory's own metadata.
/// Null when the entry is unusable — no manifest URL, no manifest, or an
/// id/name too empty to show.
CommunityAddon? _parseDirectoryEntry(Map<String, dynamic> map) {
  final transportUrl = map['manifestUrl'] as String?;
  final manifest = map['manifest'];
  if (transportUrl == null || transportUrl.isEmpty || manifest is! Map) {
    return null;
  }
  final parsed = AddonManifest.fromJson(Map<String, dynamic>.from(manifest));
  if (parsed.id.isEmpty || parsed.name.isEmpty) return null;
  final categories = <String>[];
  final rawCategories = map['categories'];
  if (rawCategories is List) {
    for (final raw in rawCategories) {
      if (raw is Map) {
        final name = (raw['name'] as String?)?.trim();
        if (name != null && name.isNotEmpty) categories.add(name);
      }
    }
  }
  final configureUrl = (map['configureUrl'] as String?)?.trim();
  return CommunityAddon(
    transportUrl: transportUrl,
    manifest: parsed,
    categories: categories,
    stars: (map['stars'] as num?)?.toInt() ?? 0,
    updatedAt: DateTime.tryParse((map['updatedAt'] as String?) ?? ''),
    configureUrl: configureUrl == null || configureUrl.isEmpty
        ? null
        : configureUrl,
  );
}

/// HTTP layer for the Stremio add-on protocol.
class AddonClient {
  AddonClient(this._dio);

  final Dio _dio;
  final _Cache _cache = _Cache();

  static const Duration manifestTtl = Duration(hours: 6);
  static const Duration catalogTtl = Duration(minutes: 15);
  static const Duration metaTtl = Duration(minutes: 45);
  static const Duration streamTtl = Duration(minutes: 5);
  static const Duration subtitleTtl = Duration(minutes: 30);

  static const Duration _fast = Duration(seconds: 12);
  static const Duration _slow = Duration(seconds: 20);

  /// Scraping bridges (CNCVerse, multi-provider profiles) routinely take
  /// 20–30 s to assemble /stream answers. The generic [_slow] ceiling was
  /// clipping them mid-scrape and the sheet only ever showed
  /// "TimeoutException after 0:00:18". Streams get their own budget.
  static const Duration _stream = Duration(seconds: 45);

  /// How long a bridge may take to scrape a /meta answer together. CNCVerse
  /// took 9 to 29 s to describe titles its own search had listed.
  static const Duration scrapeTimeout = Duration(seconds: 40);

  /// [source] files a bot check the request meets under its add-on;
  /// [personWaiting] opens the check sheet when the check wants a click.
  Options _options(
    Duration timeout, {
    String? source,
    bool personWaiting = false,
  }) => Options(
    receiveTimeout: timeout,
    sendTimeout: timeout,
    headers: const {'Accept': 'application/json'},
    validateStatus: (status) => status != null && status < 500,
    extra: {
      ClearanceExtra.source: ?source,
      if (personWaiting) ClearanceExtra.personWaiting: true,
    },
  );

  static String sourceFor(ManagedAddon addon) => 'addon:${addon.id}';

  Future<Map<String, dynamic>?> _getJson(
    String url, {
    Duration timeout = _fast,
    CancelToken? cancelToken,
    String? source,
    bool personWaiting = false,
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        url,
        options: _options(
          timeout,
          source: source,
          personWaiting: personWaiting,
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      final failed = e.response;
      if (e.type != DioExceptionType.badResponse || failed == null) rethrow;
      _throwFor(failed, url);
    }
    final status = response.statusCode ?? 0;
    // 404 is the protocol's "nothing for this id".
    if (status == 404) return null;
    if (status < 200 || status >= 300) _throwFor(response, url);

    var data = response.data;
    if (data is String) {
      final trimmed = data.trimLeft();
      if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
        throw const AddonException(
          'Add-on returned a non-JSON response (blocked or offline?).',
        );
      }
      try {
        data = jsonDecode(data);
      } catch (_) {
        throw const AddonException('Add-on returned malformed JSON.');
      }
    }
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// The bot check a failed [response] met, if any, else its status.
  Never _throwFor(Response<dynamic> response, String url) {
    final host = Uri.parse(url).host;
    final status = response.statusCode ?? 0;
    var triage = triageHeaders(status, response.headers.value);
    if (triage == Triage.unsure) {
      final data = response.data;
      triage = triageBody(data is String ? data : '');
    }
    if (triage == Triage.block) throw AddonBlockedException(host);
    if (triage == Triage.challenge) throw AddonCheckException(host);
    throw AddonException('HTTP $status from $host');
  }

  Future<AddonManifest> fetchManifest(
    String manifestUrl, {
    bool forceRefresh = false,
    bool personWaiting = false,
  }) async {
    final url = AddonTransport.normalizeManifestUrl(manifestUrl);
    final key = 'manifest:$url';
    if (forceRefresh) _cache.invalidatePrefix(key);

    return _cache.run(key, manifestTtl, () async {
      final json = await _getJson(
        url,
        timeout: _slow,
        source: 'addon:$url',
        personWaiting: personWaiting,
      );
      if (json == null) {
        throw const AddonException('No manifest found at that URL.');
      }
      final manifest = AddonManifest.fromJson(json);
      if (manifest.id.isEmpty && manifest.resources.isEmpty) {
        throw const AddonException(
          'That URL does not look like a Stremio add-on manifest.',
        );
      }
      return manifest;
    });
  }

  Future<List<AddonMetaPreview>> catalog(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final url = AddonTransport.resourceUrl(
      addon.manifestUrl,
      resource: 'catalog',
      type: type,
      id: id,
      extra: extra,
    );
    if (forceRefresh) _cache.invalidatePrefix('catalog:$url');

    return _cache.run('catalog:$url', catalogTtl, () async {
      final json = await _getJson(
        url,
        cancelToken: cancelToken,
        source: sourceFor(addon),
      );
      final metas = json?['metas'];
      if (metas is! List) return const <AddonMetaPreview>[];
      final out = <AddonMetaPreview>[];
      for (final entry in metas) {
        if (entry is Map) {
          final preview = AddonMetaPreview.fromJson(
            Map<String, dynamic>.from(entry),
            addonId: addon.id,
            addonName: addon.displayName,
          );
          if (preview.id.isNotEmpty && preview.name.isNotEmpty) {
            out.add(preview);
          }
        }
      }
      return out;
    });
  }

  Future<AddonMeta?> meta(
    ManagedAddon addon, {
    required String type,

    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
    bool personWaiting = false,
  }) async {
    final url = AddonTransport.resourceUrl(
      addon.manifestUrl,
      resource: 'meta',
      type: type,
      id: id,
    );
    if (forceRefresh) _cache.invalidatePrefix('meta:$url');

    return _cache.run('meta:$url', metaTtl, () async {
      // The caller decides how long it waits, up to [scrapeTimeout]. The
      // request itself runs a little past that, so it is always the caller's
      // ceiling that ends the wait, and a slow answer still lands in the
      // cache for the next attempt.
      final json = await _getJson(
        url,
        timeout: _stream,
        cancelToken: cancelToken,
        source: sourceFor(addon),
        personWaiting: personWaiting,
      );
      final meta = json?['meta'];
      if (meta is! Map) return null;
      return AddonMeta.fromJson(
        Map<String, dynamic>.from(meta),
        addonId: addon.id,
        addonName: addon.displayName,
      );
    });
  }

  Future<List<AddonStreamSource>> streams(
    ManagedAddon addon, {
    required String type,
    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
    bool personWaiting = false,
  }) async {
    final url = AddonTransport.resourceUrl(
      addon.manifestUrl,
      resource: 'stream',
      type: type,
      id: id,
    );
    if (forceRefresh) _cache.invalidatePrefix('stream:$url');

    return _cache.run('stream:$url', streamTtl, () async {
      final json = await _getJson(
        url,
        timeout: _stream,
        cancelToken: cancelToken,
        source: sourceFor(addon),
        personWaiting: personWaiting,
      );
      final streams = json?['streams'];
      if (streams is! List) return const <AddonStreamSource>[];
      final out = <AddonStreamSource>[];
      for (final entry in streams) {
        if (entry is Map) {
          final stream = AddonStreamSource.fromJson(
            Map<String, dynamic>.from(entry),
            addonId: addon.id,
            addonName: addon.displayName,
          );
          if (stream.kind != AddonStreamKind.unknown) out.add(stream);
        }
      }
      return out;
    });
  }

  /// Resolve a title to an IMDb id via Cinemeta search.
  ///
  /// Scraper bridges (CNCVerse Multimovies, …) identify titles with opaque
  /// `cnc:…` ids that often return empty `/stream` lists. Stremio and Nuvio
  /// still show links because they also query by IMDb. We look the title up
  /// once (cached) and feed `tt…` into the stream id-candidate list.
  Future<String?> resolveImdbId({
    required String title,
    String? type,
    int? year,
    CancelToken? cancelToken,
  }) async {
    final cleaned = title.trim();
    if (cleaned.isEmpty) return null;

    final cacheKey =
        'imdb:${cleaned.toLowerCase()}|${(type ?? '').toLowerCase()}|${year ?? ''}';
    return _cache.run(cacheKey, const Duration(hours: 12), () async {
      // Prefer the matching content type; fall back across movie/series.
      final types = <String>[];
      final t = (type ?? '').toLowerCase();
      if (t == 'series' || t == 'tv' || t == 'show') {
        types.addAll(const ['series', 'movie']);
      } else if (t == 'movie' || t == 'film' || t == 'other') {
        types.addAll(const ['movie', 'series']);
      } else {
        types.addAll(const ['movie', 'series']);
      }

      String? best;
      var bestScore = -1;

      for (final catalogType in types) {
        final url =
            'https://v3-cinemeta.strem.io/catalog/$catalogType/top/search='
            '${Uri.encodeComponent(cleaned)}.json';
        final json = await _getJson(
          url,
          timeout: _fast,
          cancelToken: cancelToken,
        );
        final metas = json?['metas'];
        if (metas is! List) continue;

        final needle = cleaned.toLowerCase();
        for (final entry in metas) {
          if (entry is! Map) continue;
          final map = Map<String, dynamic>.from(entry);
          final name = (map['name'] as String?)?.trim() ?? '';
          if (name.isEmpty) continue;
          final id = (map['imdb_id'] as String?)?.trim() ??
              (map['id'] as String?)?.trim() ??
              '';
          final match = RegExp(r'tt\d{5,}', caseSensitive: false).firstMatch(id);
          if (match == null) continue;
          final imdb = match.group(0)!.toLowerCase();

          var score = 0;
          final lower = name.toLowerCase();
          if (lower == needle) {
            score = 100;
          } else if (lower.contains(needle) || needle.contains(lower)) {
            score = 60;
          } else {
            // Token overlap
            final a = needle.split(RegExp(r'[^a-z0-9]+')).where((s) => s.length > 2).toSet();
            final b = lower.split(RegExp(r'[^a-z0-9]+')).where((s) => s.length > 2).toSet();
            if (a.isEmpty || b.isEmpty) continue;
            final overlap = a.intersection(b).length;
            score = ((overlap / a.length) * 50).round();
            if (score < 25) continue;
          }

          if (year != null) {
            final info = '${map['releaseInfo'] ?? map['year'] ?? ''}';
            if (info.contains('$year')) score += 20;
          }
          if (score > bestScore) {
            bestScore = score;
            best = imdb;
          }
        }
        if (bestScore >= 100) break; // exact name match
      }
      return best;
    });
  }

  Future<List<AddonSubtitleTrack>> subtitles(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    CancelToken? cancelToken,
  }) async {
    final url = AddonTransport.resourceUrl(
      addon.manifestUrl,
      resource: 'subtitles',
      type: type,
      id: id,
      extra: extra,
    );

    return _cache.run('subs:$url', subtitleTtl, () async {
      final json = await _getJson(
        url,
        cancelToken: cancelToken,
        source: sourceFor(addon),
      );
      final subs = json?['subtitles'];
      if (subs is! List) return const <AddonSubtitleTrack>[];
      final out = <AddonSubtitleTrack>[];
      for (var i = 0; i < subs.length; i++) {
        final entry = subs[i];
        if (entry is Map) {
          final sub = AddonSubtitleTrack.fromJson(
            Map<String, dynamic>.from(entry),
            addonName: addon.displayName,
            index: i,
          );
          if (sub != null) out.add(sub);
        }
      }
      return out;
    });
  }

  /// The Discover tab's add-on directory.
  ///
  /// The Discover tab's directory: stremio-addons.net's public listing
  /// (`GET /api/v0/addons`, newest first), which replaced Stremio's own
  /// `api.strem.io/addonscollection.json` — the official collection is a
  /// frozen ~95 entries with no categories, while this one lists every
  /// approved add-on (~600) with its categories, stars and last update.
  /// Pages are followed by cursor until the server says there is no next
  /// page; 10 pages is a safety valve against a runaway cursor loop,
  /// not a target.
  ///
  /// Failure handling is deliberate: a failed request throws (the Discover
  /// tab shows an error row with a retry) and, because it throws, it is NOT
  /// cached — the old code swallowed errors into an empty list and cached
  /// that for three hours, leaving the directory dead for hours after a
  /// single offline blip. Individual broken entries are skipped instead,
  /// with duplicates by manifest id folded (the server occasionally lists
  /// the same add-on twice, e.g. community.trakt-tv).
  Future<List<CommunityAddon>> communityAddons({
    bool forceRefresh = false,
  }) async {
    const key = 'community';
    if (forceRefresh) _cache.invalidatePrefix(key);

    return _cache.run(key, const Duration(hours: 3), () async {
      const base =
          'https://stremio-addons.net/api/v0/addons?limit=100&sort_by=createdAt&order=desc';
      final out = <CommunityAddon>[];
      final seenIds = <String>{};
      String? cursor;
      for (var page = 0; page < 10; page++) {
        final url = cursor == null
            ? base
            : '$base&cursor=${Uri.encodeComponent(cursor)}';
        final response = await _dio.get<dynamic>(
          url,
          options: _options(_slow),
        );
        final data = response.data;
        if (data is! Map) {
          throw const AddonException(
            'The add-on directory returned an unexpected response.',
          );
        }
        final parsed = parseStremioAddonsNetPage(
          Map<String, dynamic>.from(data),
        );
        for (final entry in parsed.entries) {
          if (!seenIds.add(entry.manifest.id)) continue; // server duplicate
          if (_looksCopyrightRisky(entry.manifest)) {
            if (kDebugMode) {
              debugPrint(
                '[AddonClient] copyright-risk add-on hidden: ${entry.manifest.id}',
              );
            }
            continue;
          }
          out.add(entry);
        }
        cursor = parsed.nextCursor;
        if (cursor == null) break;
      }
      if (out.isEmpty) {
        throw const AddonException('The add-on directory returned nothing.');
      }
      return out;
    });
  }

  void invalidate(ManagedAddon addon) {
    final base = AddonTransport.baseUrl(addon.manifestUrl);
    for (final prefix in const ['catalog:', 'meta:', 'stream:', 'subs:']) {
      _cache.invalidatePrefix('$prefix$base');
    }
  }

  void clearCache() => _cache.clear();
}

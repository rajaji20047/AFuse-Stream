import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/addons/data/addon_client.dart';

/// The Discover tab renders the stremio-addons.net directory —
/// https://stremio-addons.net/api/v0/addons, newest first, paged by cursor.
/// These tests pin the behaviours that broke it in the past:
///
/// * one junk entry must not sink the whole directory;
/// * duplicate ids from the server are folded, first occurrence wins;
/// * `configurationRequired` survives into the manifest, because that flag
///   drives the "Set up on website" affordance shown for half the directory;
/// * a network failure throws (so the UI can offer a retry) and is NOT
///   cached — it used to be swallowed into an empty list cached for 3h;
/// * pages are followed by cursor until the server says there is no next
///   page, and a stale cursor on the last page is ignored.
void main() {
  group('AddonClient.communityAddons', () {
    test(
      'parses entries and folds server-side duplicates by manifest id',
      () async {
        final adapter = _StubAdapter(
          pages: {
            null: _page([
              _entry(id: 'com.example.one', name: 'One'),
              _entry(id: 'com.example.one', name: 'One clone'),
              _entry(id: 'com.example.trakt-clone', name: 'Trakt Clone'),
              // Junk shapes the parser must survive.
              'not a map at all',
              {
                'manifestUrl': '',
                'manifest': {'id': '', 'name': ''},
              },
              {
                'manifest': {'id': 'com.example.missing-url', 'name': 'No URL'},
              },
              {
                'manifestUrl': 'https://x.example/manifest.json',
                'manifest': 42,
              },
              // One that must win over the junk around it.
              _entry(id: 'com.example.two', name: 'Two'),
            ]),
          },
        );
        final client = _client(adapter);

        final entries = await client.communityAddons();

        expect(entries.map((e) => e.manifest.id), [
          'com.example.one',
          'com.example.trakt-clone',
          'com.example.two',
        ], reason: 'exactly one of each id, in server order, junk skipped');
        expect(
          entries.first.manifest.name,
          'One',
          reason: 'the first server occurrence is the one that wins',
        );
      },
    );

    test('keeps configurationRequired from behaviorHints', () async {
      final adapter = _StubAdapter(
        pages: {
          null: _page([
            _entry(
              id: 'org.example.configurable',
              name: 'Configurable',
              behaviorHints: {
                'configurable': true,
                'configurationRequired': true,
              },
            ),
          ]),
        },
      );
      final client = _client(adapter);

      final entries = await client.communityAddons();

      expect(entries.single.manifest.behaviorHints.configurationRequired, true);
      expect(entries.single.manifest.behaviorHints.configurable, true);
    });

    test(
      'a failure throws, and is never cached as an empty directory',
      () async {
        final adapter = _StubAdapter(
          pages: {
            null: _page([
              _entry(id: 'org.example.alive', name: 'Alive'),
            ]),
          },
          failing: true,
        );
        final client = _client(adapter);

        await expectLater(client.communityAddons(), throwsA(anything));

        // Recovery must be immediate, not after a three-hour empty-list cache.
        adapter.failing = false;
        final entries = await client.communityAddons();
        expect(entries.single.manifest.id, 'org.example.alive');

        // …while a real result IS cached, so the TTL still does its job.
        adapter.requestCount = 0;
        await client.communityAddons();
        expect(adapter.requestCount, 0);
      },
    );

    test('a healthy response with no usable entries throws', () async {
      final adapter = _StubAdapter(
        pages: {
          null: _page(['garbage']),
        },
      );
      final client = _client(adapter);

      expect(client.communityAddons(), throwsA(isA<AddonException>()));
    });

    test('hides p2p and pirate catalog add-ons — copyright risk', () async {
      // The live directory really ships entries like "Top Seeded Torrent
      // Catalogs"; Discover must never surface them, whatever the server
      // does. Everything else passes through untouched.
      final adapter = _StubAdapter(
        pages: {
          null: _page([
            _entry(id: 'com.stremio.opensubtitlesv3', name: 'OpenSubtitles v3'),
            _entry(
              id: 'org.tornet.catalogs',
              name: 'Torrent Catalogs',
              behaviorHints: {'p2p': true, 'configurable': false},
            ),
            _entry(id: 'io.strem.seeded', name: 'Top Seeded Torrent Catalogs'),
            _entry(id: 'club.magnet.indexer', name: 'Magnet Indexer'),
            _entry(
              id: 'com.example.p2p-flag',
              name: 'Innocent Name',
              behaviorHints: {'p2p': true},
            ),
            _entry(id: 'com.example.trakt-tv', name: 'Trakt Tv'),
          ]),
        },
      );
      final client = _client(adapter);

      final entries = await client.communityAddons();

      expect(
        entries.map((e) => e.manifest.id),
        ['com.stremio.opensubtitlesv3', 'com.example.trakt-tv'],
        reason:
            'p2p flag and torrent/pirate naming are dropped, safe '
            'entries (Trakt, OpenSubtitles) survive',
      );
    });

    test('follows cursors across pages, folding duplicates', () async {
      final adapter = _StubAdapter(
        pages: {
          null: _page(
            [_entry(id: 'com.example.one', name: 'One')],
            nextCursor: 'c1',
          ),
          'c1': _page([
            _entry(id: 'com.example.two', name: 'Two'),
            _entry(id: 'com.example.one', name: 'One again'),
          ]),
        },
      );
      final client = _client(adapter);

      final entries = await client.communityAddons();

      expect(entries.map((e) => e.manifest.id), [
        'com.example.one',
        'com.example.two',
      ]);
      expect(adapter.requestCount, 2);
      expect(adapter.cursorsSeen, ['c1']);
    });
  });

  group('parseStremioAddonsNetPage', () {
    test('keeps the directory metadata on a full entry', () {
      final page = parseStremioAddonsNetPage(
        _page([
          _entry(
            id: 'com.stremio.torrentio.addon',
            name: 'Torrentio',
            categories: ['Torrents', 'Debrid support'],
            stars: 2480,
            updatedAt: '2026-07-07T19:10:31.388Z',
            configureUrl: 'https://torrentio.strem.fun/configure',
          ),
        ]),
      );

      final entry = page.entries.single;
      expect(entry.transportUrl, 'https://example.com/com.stremio.torrentio.addon/manifest.json');
      expect(entry.manifest.id, 'com.stremio.torrentio.addon');
      expect(entry.categories, ['Torrents', 'Debrid support']);
      expect(entry.stars, 2480);
      expect(entry.updatedAt, DateTime.utc(2026, 7, 7, 19, 10, 31, 388));
      expect(entry.configureUrl, 'https://torrentio.strem.fun/configure');
      expect(page.nextCursor, isNull);
    });

    test('missing optional fields fall back to empty defaults', () {
      final page = parseStremioAddonsNetPage(
        _page([_entry(id: 'com.example.bare', name: 'Bare')]),
      );

      final entry = page.entries.single;
      expect(entry.categories, isEmpty);
      expect(entry.stars, 0);
      expect(entry.updatedAt, isNull);
      expect(entry.configureUrl, isNull);
    });

    test('junk entries are skipped, good ones survive', () {
      final page = parseStremioAddonsNetPage(
        _page([
          'not a map at all',
          {'manifestUrl': '', 'manifest': {'id': '', 'name': ''}},
          {'manifest': {'id': 'com.example.missing-url', 'name': 'No URL'}},
          {'manifestUrl': 'https://x.example/manifest.json', 'manifest': 42},
          _entry(id: 'com.example.good', name: 'Good'),
        ]),
      );

      expect(page.entries.map((e) => e.manifest.id), ['com.example.good']);
    });

    test('nextCursor only counts while hasNextPage is true', () {
      final withNext = parseStremioAddonsNetPage(
        _page([], nextCursor: 'abc'),
      );
      expect(withNext.nextCursor, 'abc');

      // A stale cursor on the last page is ignored.
      final last = parseStremioAddonsNetPage({
        'addons': const [],
        'pagination': {
          'page': 2,
          'limit': 100,
          'total': 1,
          'totalPages': 2,
          'hasNextPage': false,
          'hasPreviousPage': true,
          'nextCursor': 'stale',
        },
      });
      expect(last.nextCursor, isNull);

      final noPagination = parseStremioAddonsNetPage({'addons': const []});
      expect(noPagination.nextCursor, isNull);
    });
  });
}

/// One directory entry in the stremio-addons.net shape. Optional
/// directory fields are only sent when given, so a bare call really
/// exercises the missing-field defaults.
Map<String, dynamic> _entry({
  required String id,
  required String name,
  Map<String, dynamic>? behaviorHints,
  List<String>? categories,
  int? stars,
  String? updatedAt,
  String? configureUrl,
}) {
  return {
    'uuid': 'uuid-$id',
    'url': 'https://stremio-addons.net/addons/$id',
    'manifestUrl': 'https://example.com/$id/manifest.json',
    'manifest': {
      'id': id,
      'name': name,
      'version': '1.0.0',
      'description': 'Test add-on $name',
      'types': const ['movie'],
      'resources': const ['catalog'],
      'catalogs': const [
        {'type': 'movie', 'id': 'top', 'name': 'Top'},
      ],
      'behaviorHints': ?behaviorHints,
    },
    'slug': id,
    'nsfw': false,
    if (categories != null)
      'categories': [
        for (final category in categories)
          {'name': category, 'slug': category.toLowerCase()},
      ],
    if (stars != null) 'stars': stars,
    if (updatedAt != null) 'updatedAt': updatedAt,
    if (configureUrl != null) 'configureUrl': configureUrl,
    'createdAt': '2024-01-01T00:00:00.000Z',
  };
}

/// One directory page: `{"addons": [...], "pagination": {...}}`.
Map<String, dynamic> _page(List<Object?> addons, {String? nextCursor}) {
  return {
    'addons': addons,
    'pagination': {
      'page': 1,
      'limit': 100,
      'total': addons.length,
      'totalPages': nextCursor == null ? 1 : 2,
      'hasNextPage': nextCursor != null,
      'hasPreviousPage': false,
      if (nextCursor != null) 'nextCursor': nextCursor,
    },
  };
}

/// The add-on directory is the only endpoint the adapter answers. [pages]
/// maps a request cursor (null = the first page) to its page payload.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({required this.pages, this.failing = false});

  Map<String?, Map<String, dynamic>> pages;
  bool failing;
  var requestCount = 0;
  final cursorsSeen = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    if (failing) {
      throw DioException(requestOptions: options);
    }
    final cursor = options.uri.queryParameters['cursor'];
    if (cursor != null) cursorsSeen.add(cursor);
    final page = pages[cursor] ?? _page(const []);
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(page)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

AddonClient _client(_StubAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return AddonClient(dio);
}

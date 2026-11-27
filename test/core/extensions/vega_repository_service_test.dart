import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/extensions/models/vega_models.dart';
import 'package:raja/core/extensions/services/vega_repository_service.dart';

/// The web as Dio sees it: [routes] by address, anything else a 404. Records
/// every request.
class _Net implements HttpClientAdapter {
  _Net(this.routes);

  final Map<String, ResponseBody Function()> routes;
  final List<String> requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    return routes[url]?.call() ?? ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

String _stamped(String value, String version, [String body = '']) =>
    '// @vega-provider $value\n// @vega-version $version\n$body';

void main() {
  group('resolveSource', () {
    final service = VegaRepositoryService(Dio());

    test('bare username → vega-providers on main', () {
      final source = service.resolveSource('Zenda-Cross');
      expect(
        source.manifestUrl,
        'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/main/manifest.json',
      );
      expect(source.label, 'Zenda-Cross');
    });

    test('user/repo → that repo on main', () {
      final source = service.resolveSource('Zenda-Cross/vega-providers');
      expect(
        source.manifestUrl,
        'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/main/manifest.json',
      );
      expect(source.label, 'Zenda-Cross/vega-providers');
    });

    test('github.com URL with /tree/<branch> → that branch', () {
      final source = service.resolveSource(
        'https://github.com/Zenda-Cross/vega-providers/tree/dev',
      );
      expect(
        source.manifestUrl,
        'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/dev/manifest.json',
      );
      expect(source.label, 'Zenda-Cross/vega-providers');
    });

    test('github.com blob manifest URL converts to raw', () {
      final source = service.resolveSource(
        'https://github.com/Zenda-Cross/vega-providers/blob/main/manifest.json',
      );
      expect(
        source.manifestUrl,
        'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/main/manifest.json',
      );
    });

    test('full manifest URL is used as-is', () {
      const url =
          'https://cdn.jsdelivr.net/gh/Zenda-Cross/vega-providers@main/manifest.json';
      final source = service.resolveSource(url);
      expect(source.manifestUrl, url);
      expect(source.label, 'Zenda-Cross/vega-providers');
    });

    test('http:// dev-server sources are rejected', () {
      expect(
        () => service.resolveSource('http://192.168.1.2:3001'),
        throwsException,
      );
    });

    test('empty input and garbage are rejected', () {
      expect(() => service.resolveSource(''), throwsException);
      expect(() => service.resolveSource('not a url at all'), throwsException);
    });

    test('labelForManifestUrl', () {
      expect(
        VegaRepositoryService.labelForManifestUrl(
          'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/main/manifest.json',
        ),
        'Zenda-Cross/vega-providers',
      );
      expect(
        VegaRepositoryService.labelForManifestUrl('https://example.com/x.json'),
        'example.com',
      );
    });
  });

  group('compareVegaVersions', () {
    test('numeric segments compare numerically', () {
      expect(compareVegaVersions('2.52', '2.5'), greaterThan(0));
      expect(compareVegaVersions('2.30', '2.9'), greaterThan(0));
      expect(compareVegaVersions('1.0', '1.0.1'), lessThan(0));
      expect(compareVegaVersions('1.2.3', '1.2.3'), 0);
      expect(compareVegaVersions('10.0', '9.9'), greaterThan(0));
    });

    test('non-numeric segments compare lexicographically', () {
      expect(compareVegaVersions('1.0-beta', '1.0-alpha'), greaterThan(0));
    });
  });

  group('hasValidStamp', () {
    test('accepts the stamped header', () {
      expect(
        VegaRepositoryService.hasValidStamp(
          _stamped('drive', '2.30', 'module.exports = {};'),
          'drive',
          '2.30',
        ),
        isTrue,
      );
    });

    test('leading blank lines are skipped', () {
      expect(
        VegaRepositoryService.hasValidStamp(
          '\n\n${_stamped('drive', '2.30')}',
          'drive',
          '2.30',
        ),
        isTrue,
      );
    });

    test('rejects a missing stamp', () {
      expect(
        VegaRepositoryService.hasValidStamp(
          'module.exports = {};',
          'drive',
          '2.30',
        ),
        isFalse,
      );
    });

    test('rejects a mismatched provider or version', () {
      expect(
        VegaRepositoryService.hasValidStamp(
          _stamped('drive', '2.30'),
          'other',
          '2.30',
        ),
        isFalse,
      );
      expect(
        VegaRepositoryService.hasValidStamp(
          _stamped('drive', '2.30'),
          'drive',
          '2.31',
        ),
        isFalse,
      );
    });
  });

  group('fetchManifest over a fake net', () {
    late _Net net;
    late VegaRepositoryService web;

    setUp(() {
      net = _Net({
        'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/main/manifest.json':
            () => ResponseBody.fromString(
              jsonEncode([
                {
                  'display_name': 'Internet Archive',
                  'value': 'archive',
                  'version': '1.0.0',
                },
                {
                  'display_name': 'Disabled One',
                  'value': 'disabled-one',
                  'version': '1.0.0',
                  'disabled': true,
                },
                // Unsafe value: would escape the install directory.
                {
                  'display_name': 'Escape',
                  'value': '../escape',
                  'version': '1.0.0',
                },
                // No value at all.
                {'display_name': 'Broken'},
                // Not an object.
                'just a string',
              ]),
              200,
            ),
      });
      web = VegaRepositoryService(Dio()..httpClientAdapter = net);
    });

    test('parses the good entries and skips the bad ones', () async {
      final entries = await web.fetchManifest(
        'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/main/manifest.json',
      );
      expect(entries.map((e) => e.value), ['archive', 'disabled-one']);
      expect(entries.first.displayName, 'Internet Archive');
      expect(entries.last.disabled, isTrue);
    });

    test('a non-200 manifest throws', () async {
      expect(
        () => web.fetchManifest('https://example.com/missing.json'),
        throwsException,
      );
    });
  });

  group('downloadModules over a fake net', () {
    const entry = VegaManifestEntry(
      displayName: 'Internet Archive',
      value: 'archive',
      version: '1.0.0',
    );
    const base = 'https://raw.githubusercontent.com/Zenda-Cross/vega-providers/main/';

    test('required modules download, optional 404s are skipped', () async {
      final net = _Net({
        for (final name in ['catalog', 'posts', 'meta', 'stream'])
          '${base}dist/archive/$name.js': () => ResponseBody.fromString(
            _stamped('archive', '1.0.0', '//$name'),
            200,
          ),
        // episodes and settings 404: the fake net answers 404 by default.
      });
      final web = VegaRepositoryService(Dio()..httpClientAdapter = net);
      final downloaded = await web.downloadModules(base, entry);
      expect(downloaded.modules.keys, {'catalog', 'posts', 'meta', 'stream'});
      expect(downloaded.sha256.keys, {'catalog', 'posts', 'meta', 'stream'});
      expect(downloaded.modules['catalog'], contains('//catalog'));
    });

    test('a bundle with a bad stamp refuses the whole provider', () async {
      final net = _Net({
        for (final name in ['catalog', 'posts', 'meta'])
          '${base}dist/archive/$name.js': () => ResponseBody.fromString(
            _stamped('archive', '1.0.0'),
            200,
          ),
        '${base}dist/archive/stream.js': () => ResponseBody.fromString(
          _stamped('archive', '9.9.9'),
          200,
        ),
      });
      final web = VegaRepositoryService(Dio()..httpClientAdapter = net);
      expect(() => web.downloadModules(base, entry), throwsException);
    });

    test('a missing required module throws', () async {
      final net = _Net({
        for (final name in ['catalog', 'posts', 'meta'])
          '${base}dist/archive/$name.js': () => ResponseBody.fromString(
            _stamped('archive', '1.0.0'),
            200,
          ),
        // stream.js 404s.
      });
      final web = VegaRepositoryService(Dio()..httpClientAdapter = net);
      expect(() => web.downloadModules(base, entry), throwsException);
    });
  });
}

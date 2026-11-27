import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../features/settings/presentation/general_settings_provider.dart'
    show GithubProxyOption;
import '../models/vega_models.dart';
import 'repository_service.dart' show applyGithubProxy;

/// Where a Vega source is read from: its manifest URL, the directory its
/// `dist/` bundles live under, and the name shown for it (a Vega manifest
/// carries no repository name of its own).
typedef VegaSource = ({String manifestUrl, String baseUrl, String label});

/// The modules a Vega provider ships, in the order the bridge loads them.
/// `catalog`, `posts`, `meta` and `stream` are required; `episodes` and
/// `settings` are optional — only the files that exist are downloaded.
const List<String> kVegaRequiredModules = ['catalog', 'posts', 'meta', 'stream'];
const List<String> kVegaOptionalModules = ['episodes', 'settings'];

/// Fetches Vega provider repositories and their prebuilt `dist/` bundles.
///
/// Mirrors [RepositoryService]: the same Dio, the same GitHub-proxy
/// normalization, the same "one malformed entry must not empty the whole
/// repository" rule. It never executes anything it downloads — every bundle
/// is stamp-checked (see [hasValidStamp]) before it is installed, and a
/// bundle whose stamp is missing or mismatched refuses the whole provider.
class VegaRepositoryService {
  final Dio _dio;

  /// The GitHub proxy choice; [GithubProxyOption.none] is the old toggle
  /// off. Kept as a field (not read off a provider) so the service stays
  /// constructible in tests.
  final GithubProxyOption githubProxy;

  /// The base URL a Custom proxy prefixes with; ignored unless
  /// [githubProxy] is [GithubProxyOption.custom].
  final String githubProxyCustomUrl;

  VegaRepositoryService(
    this._dio, {
    this.githubProxy = GithubProxyOption.none,
    this.githubProxyCustomUrl = '',
  });

  /// Resolves what the user typed into the source it is read from.
  ///
  /// Accepted shapes (the Vega app's own install flow):
  /// * A bare GitHub username — the repository named exactly
  ///   `vega-providers` under it.
  /// * `user/repo` — that repository, `main` branch.
  /// * A full `https://github.com/user/repo` URL, optionally with
  ///   `/tree/<branch>` (or `/blob/<branch>`) — that branch, else `main`.
  /// * A full manifest URL ending in `/manifest.json` (raw GitHub, a
  ///   jsDelivr mirror, or any other host) — used as-is.
  ///
  /// HTTP dev-server sources (`http://<ip>:3001`) are rejected: the plan
  /// defers them to a later phase; GitHub sources come first.
  VegaSource resolveSource(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw Exception('Enter a GitHub username or repository URL');
    }
    if (trimmed.startsWith('http://')) {
      throw Exception(
        'HTTP sources are not supported — use a GitHub username or an '
        'https:// repository URL',
      );
    }

    // A bare GitHub username: the repo named exactly `vega-providers`.
    if (RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$').hasMatch(trimmed)) {
      return _rawSource(trimmed, 'vega-providers', 'main', trimmed);
    }

    // `user/repo`, main branch.
    final userRepo = RegExp(
      r'^([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_.-]+)$',
    ).firstMatch(trimmed);
    if (userRepo != null) {
      final user = userRepo.group(1)!;
      final repo = userRepo.group(2)!.replaceAll(RegExp(r'\.git$'), '');
      return _rawSource(user, repo, 'main', '$user/$repo');
    }

    final uri = Uri.tryParse(trimmed);
    if (uri != null &&
        (uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.pathSegments.isNotEmpty) {
      // A full manifest URL: use it as-is, bundles beside it. A
      // github.com blob URL is NOT a raw manifest — it falls through to
      // the github.com branch below, which converts it to raw.
      if (uri.pathSegments.last == 'manifest.json' &&
          uri.host != 'github.com') {
        final base = trimmed.substring(
          0,
          trimmed.length - 'manifest.json'.length,
        );
        return (
          manifestUrl: trimmed,
          baseUrl: base,
          label: labelForManifestUrl(trimmed),
        );
      }
      // A github.com repository URL, optionally with /tree/<branch> or
      // /blob/<branch> (the blob view of the manifest is a common paste).
      if (uri.host == 'github.com' && uri.pathSegments.length >= 2) {
        final user = uri.pathSegments[0];
        final repo = uri.pathSegments[1].replaceAll(RegExp(r'\.git$'), '');
        var branch = 'main';
        if (uri.pathSegments.length >= 4 &&
            (uri.pathSegments[2] == 'tree' ||
                uri.pathSegments[2] == 'blob')) {
          branch = uri.pathSegments[3];
        }
        return _rawSource(user, repo, branch, '$user/$repo');
      }
    }

    throw Exception(
      'Enter a GitHub username (for a repo named vega-providers) or a full '
      'repository URL',
    );
  }

  VegaSource _rawSource(
    String user,
    String repo,
    String branch,
    String label,
  ) {
    final base = 'https://raw.githubusercontent.com/$user/$repo/$branch/';
    return (manifestUrl: '${base}manifest.json', baseUrl: base, label: label);
  }

  /// A readable name for a manifest URL that carries none of its own:
  /// `user/repo` for a raw GitHub URL, else the host.
  static String labelForManifestUrl(String manifestUrl) {
    final uri = Uri.tryParse(manifestUrl);
    if (uri == null) return manifestUrl;
    final segments = uri.pathSegments;
    if (uri.host == 'raw.githubusercontent.com' && segments.length >= 2) {
      return '${segments[0]}/${segments[1]}';
    }
    if (uri.host == 'cdn.jsdelivr.net' &&
        segments.length >= 3 &&
        segments[0] == 'gh') {
      final repo = segments[2].split('@').first;
      return '${segments[1]}/$repo';
    }
    return uri.host;
  }

  /// Fetches and parses a repository's `manifest.json`: a JSON array, one
  /// entry per provider. A malformed entry is skipped, never fatal; an
  /// unreachable or non-200 manifest throws.
  Future<List<VegaManifestEntry>> fetchManifest(String manifestUrl) async {
    final response = await _dio.get<String>(
      _normalizeUrl(manifestUrl),
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        },
      ),
    );
    final status = response.statusCode ?? 0;
    if (status != 200 || response.data == null) {
      throw Exception(
        'Could not load the Vega manifest (HTTP $status) — check the '
        'source or your connection',
      );
    }
    final decoded = _jsonDecodeSafe(response.data!);
    if (decoded is! List) {
      throw Exception(
        'Invalid Vega manifest: expected a JSON array of providers',
      );
    }
    final entries = <VegaManifestEntry>[];
    for (final raw in decoded) {
      if (raw is! Map) continue;
      try {
        final entry = VegaManifestEntry.fromJson(
          Map<String, dynamic>.from(raw),
        );
        // A `value` that cannot be a directory name is not installable:
        // it becomes a path below, and must not escape it.
        if (entry.value.isEmpty || !_isSafeValue(entry.value)) continue;
        entries.add(entry);
      } catch (_) {
        // One malformed entry must not empty the whole repository.
        if (kDebugMode) {
          debugPrint('Skipping malformed Vega manifest entry in $manifestUrl');
        }
      }
    }
    return entries;
  }

  /// Downloads a provider's `dist/` bundles from [baseUrl] and verifies
  /// each one's stamp before returning it.
  ///
  /// Required modules (`catalog`, `posts`, `meta`, `stream`) must all be
  /// present; a missing or failed one throws and nothing is installed.
  /// Optional modules (`episodes`, `settings`) are downloaded when they
  /// exist and skipped on 404. A bundle whose `// @vega-provider` /
  /// `// @vega-version` stamp is missing or does not match [entry]
  /// refuses the whole provider — a bundle is never executed unchecked.
  Future<({Map<String, String> modules, Map<String, String> sha256})>
  downloadModules(String baseUrl, VegaManifestEntry entry) async {
    final modules = <String, String>{};
    final hashes = <String, String>{};
    for (final name in [...kVegaRequiredModules, ...kVegaOptionalModules]) {
      final required = kVegaRequiredModules.contains(name);
      final url = '${baseUrl}dist/${entry.value}/$name.js';
      final source = await _fetchModule(url, name, required);
      if (source == null) continue;
      if (!hasValidStamp(source, entry.value, entry.version)) {
        throw Exception(
          'Refusing Vega provider "${entry.value}": its $name bundle has '
          'no valid // @vega-provider / // @vega-version stamp',
        );
      }
      modules[name] = source;
      // Hash the UTF-8 bytes, the same bytes writeAsString writes to disk,
      // so a later file-byte check matches this record.
      hashes[name] = sha256.convert(utf8.encode(source)).toString();
    }
    for (final required in kVegaRequiredModules) {
      if (!modules.containsKey(required)) {
        throw Exception(
          'Vega provider "${entry.value}" is missing its $required module',
        );
      }
    }
    return (modules: modules, sha256: hashes);
  }

  /// One module file, or null when it is optional and absent (404). Any
  /// other failure throws.
  Future<String?> _fetchModule(
    String url,
    String name,
    bool required,
  ) async {
    final response = await _dio.get<String>(
      _normalizeUrl(url),
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 200 && response.data != null) return response.data!;
    if (status == 404 && !required) return null;
    throw Exception(
      'Could not download the $name bundle (HTTP $status)',
    );
  }

  /// Whether [source] carries the stamp the Vega build writes into every
  /// `dist/` file: the first two non-empty lines must be
  /// `// @vega-provider <value>` and `// @vega-version <version>`.
  @visibleForTesting
  static bool hasValidStamp(String source, String value, String version) {
    final lines = source
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(2)
        .toList(growable: false);
    if (lines.length < 2) return false;
    return lines[0] == '// @vega-provider $value' &&
        lines[1] == '// @vega-version $version';
  }

  /// A manifest `value` is safe to use as a directory name under the Vega
  /// root: the Vega build itself only allows `[A-Za-z0-9_.-]`, and a value
  /// starting with a dot (`.`, `..`) would escape or hide the directory.
  static bool _isSafeValue(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(value);

  String _normalizeUrl(String url) {
    return applyGithubProxy(url, githubProxy, githubProxyCustomUrl);
  }

  dynamic _jsonDecodeSafe(String source) {
    try {
      return jsonDecode(source);
    } catch (_) {
      return null;
    }
  }
}

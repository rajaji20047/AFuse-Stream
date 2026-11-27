import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../logger/app_logger.dart';
import '../base_provider.dart';
import '../models/extension_plugin.dart';
import '../engine/js_bytecode_compiler.dart';
import '../engine/js_engine.dart';
import '../engine/vega_provider_context.dart';

/// Hard ceiling on the per-call result count, mirroring [JsBasedProvider]'s
/// `_kMaxResultListLength` / `_kMaxStreamsPerCall`: a provider that returns a
/// pathological list cannot grow the caller's memory without bound.
const int _kVegaMaxResultListLength = 5000;
const int _kVegaMaxStreamsPerCall = 200;

/// Cap on the episode links remembered per provider session (see
/// [VegaBasedProvider._episodeLinks]) and on the stream URLs with stored
/// skip intervals (see [VegaBasedProvider._skipIntervals]).
const int _kVegaMaxEpisodeLinks = 2000;
const int _kVegaMaxSkipUrls = 500;

/// Cap on the listing images remembered per provider session (see
/// [VegaBasedProvider._listingImages]).
const int _kVegaMaxListingImages = 500;

/// Cap on the catalog section filters remembered per provider session (see
/// [VegaBasedProvider._catalogFilters]).
const int _kVegaMaxCatalogFilters = 200;

/// One skip interval (intro / recap / credits) a Vega stream reported, in
/// seconds. Parsed and validated by [VegaBasedProvider]; the player does not
/// consume these yet (see [VegaBasedProvider.skipIntervalsFor]).
class VegaSkipInterval {
  final String? title;
  final double fromSec;
  final double toSec;

  const VegaSkipInterval({
    this.title,
    required this.fromSec,
    required this.toSec,
  });
}

/// What the provider's modules export, read once at init.
class _VegaCapabilities {
  final bool hasSearchPosts;
  final bool hasEpisodes;
  final bool hasSettings;

  const _VegaCapabilities({
    required this.hasSearchPosts,
    required this.hasEpisodes,
    required this.hasSettings,
  });
}

/// A Vega App provider (vega-org / Zenda-Cross style: `catalog.ts`,
/// `posts.ts`, `meta.ts`, `stream.ts`, optional `episodes.ts` and
/// `settings.ts`, prebuilt to `dist/` by esbuild) running on Fuse's QuickJS
/// worker as a [SkyStreamProvider].
///
/// Mirrors [JsBasedProvider]: one namespaced installer
/// (`__ssInstall_<namespace>`), one bridge token minted per launch, modules
/// loaded as CommonJS with a fresh `module`/`exports`/`require` per file,
/// and calls made through [JsEngineService.invokeAsync]. The provider's
/// `providerContext` (axios / cheerio / kvStore / commonHeaders /
/// openWebView) comes from the shared bundle loaded by
/// [VegaProviderContext] — the context is never rebuilt per provider, and
/// the bridge token keeps one provider's storage calls out of another
/// provider's key space.
///
/// The module sources are passed in-memory (`modules`: name -> built dist
/// bundle source). Phase 3 owns fetching them from a repo and keeping them
/// fresh; this class only runs them.
///
/// Known limits (see the Vega bridge plan / spike report):
/// * [loadStreams] resolves through `getMeta` first, so a cold start pays
///   one extra metadata fetch per play — the same cost .sky plugins pay
///   inside their own `loadStreams`.
/// * Series / dynamic episodes (`episodesLink`) are implemented but were
///   NOT exercised in the Phase-0 spike (the Internet Archive provider has
///   no `episodes.js`); the phone test must cover a series.
class VegaBasedProvider extends SkyStreamProvider {
  /// Bump whenever [_buildIife]'s wrapper text changes: the version is part
  /// of the `.qbc` filename, so bytecode compiled from an older wrapper is
  /// ignored rather than loaded.
  static const int _vegaWrapperVersion = 1;

  final JsEngineService _jsEngine;

  /// The Vega provider value (the `providers/<value>/` folder name and the
  /// manifest `value`), e.g. `internetArchive`.
  final String _value;
  String get value => _value;

  final String _displayName;
  final String _version;

  /// Module name -> built dist bundle source. `catalog`, `posts`, `meta`
  /// and `stream` are required; `episodes` and `settings` are optional.
  final Map<String, String> _modules;

  /// Directory compiled wrapper bytecode is cached under, or null to skip
  /// the `.qbc` fast path (Phase 2 loads from in-memory sources).
  final String? _bytecodeDir;

  String get _namespace => namespaceFor(_value);

  /// The JS-engine namespace for a provider value. The settings dialog
  /// uses it to build the kvStore key a setting lives under — see
  /// [kvKeyFor].
  static String namespaceFor(String value) => 'vega_${_sanitize(value)}';

  /// The storage key a provider setting lives under in the extensions
  /// box: `<namespace>::<key>`, the same key the Vega context bundle's
  /// kvStore reads and writes through the engine's `get_storage` /
  /// `set_storage` bridge (key `<storageNamespace>::<key>`).
  static String kvKeyFor(String value, String settingKey) =>
      '${namespaceFor(value)}::$settingKey';

  /// The reserved kvStore key holding the provider's key index (the
  /// context bundle's `KV_INDEX_KEY`): a JSON array of the setting keys
  /// the provider has stored. Dart-side writers (the settings dialog)
  /// maintain it alongside the values they write, so `kvStore.keys()`
  /// lists dialog-written settings too.
  static const String kvIndexKey = '__vega_kv_keys';

  static String kvIndexKeyFor(String value) =>
      '${namespaceFor(value)}::$kvIndexKey';

  @override
  String get packageName => 'vega.$_value';

  @override
  String get name => _displayName;

  /// Vega providers have no single home page: the base URL lives in the
  /// provider's own settings / urls map.
  @override
  String get mainUrl => '';

  @override
  String get version => _version;

  @override
  List<String> get languages => const ['en'];

  @override
  Set<ProviderType> get supportedTypes => const {
    ProviderType.movie,
    ProviderType.series,
  };

  @override
  String? get checkSource => 'vega:$_namespace';

  Future<void>? _initFuture;
  Future<void>? _invokeLock;
  _VegaCapabilities? _capabilities;
  String? _error;
  String? _wrapperCache;

  /// Episode links seen by [getDetails] this session. [loadStreams]
  /// answers one of these straight from `getStream` (type `series`); any
  /// other URL is a details URL and goes through `getMeta` first. Bounded
  /// (see [_kVegaMaxEpisodeLinks]).
  final Set<String> _episodeLinks = {};

  /// Skip intervals a provider returned per stream URL, for the player
  /// wiring in a later phase (no consumer yet — see [skipIntervalsFor]).
  final Map<String, List<VegaSkipInterval>> _skipIntervals = {};

  /// Listing images seen by [getHome]/search this session, keyed by the
  /// post's link URL. Some providers' `getMeta` returns no image at all
  /// (MX Player: `image=""` for Yashoda) while the listing that led here
  /// carried a poster — [_infoToItem] falls back to this cache so the
  /// details hero is not left on the placeholder. Bounded (see
  /// [_kVegaMaxListingImages]).
  final Map<String, String> _listingImages = {};

  /// Catalog section filters seen by [getHome] this session, keyed by the
  /// section title (the Home row title). [getCatalogPage] resolves a
  /// section's filter from this cache so the Home "View All" page can load
  /// page 2+. Bounded (see [_kVegaMaxCatalogFilters]).
  final Map<String, String> _catalogFilters = {};

  VegaBasedProvider(
    this._jsEngine, {
    required String value,
    required String displayName,
    required String version,
    required Map<String, String> modules,
    String? bytecodeDir,
  })  : _value = value,
        _displayName = displayName,
        _version = version,
        _modules = Map<String, String>.unmodifiable(modules),
        _bytecodeDir = bytecodeDir {
    for (final required in const ['catalog', 'posts', 'meta', 'stream']) {
      if (!_modules.containsKey(required)) {
        throw ArgumentError(
          'Vega provider "$value" is missing its $required module',
        );
      }
    }
  }

  static String _sanitize(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

  Future<void> _ensureReady() {
    _initFuture ??= _init();
    return _initFuture!;
  }

  Future<void> get waitForInit => _ensureReady();

  @override
  void cancelInit() {
    _jsEngine.cancelPendingForTag(packageName);
  }

  /// Name of the one-shot installer function this provider's wrapper
  /// publishes on `globalThis`. Derived from the namespace, so it is unique
  /// per provider.
  String get _installerGlobal =>
      '${JsEngineService.kBridgeInstallerPrefix}$_namespace';

  String get _wrapper => _wrapperCache ??= _buildIife();

  /// Wraps the Vega module sources in a namespaced installer function with
  /// the bridge token, the providerContext, and the invokeAsync envelope —
  /// the Vega equivalent of [JsBasedProvider._buildIife].
  ///
  /// The token itself is not in here: it is minted fresh per launch (see
  /// [_installBridgeToken]). The wrapper publishes a one-shot installer
  /// under a name derived from this provider's namespace, and the installer
  /// takes the token as an argument, so no token ever sits in a slot shared
  /// with another provider.
  ///
  /// Each Vega module is loaded as CommonJS (fresh `module`/`exports`/
  /// `require` per file, exactly like the Phase-0 spike's loader) and the
  /// namespace exports are thin wrappers that inject the providerContext
  /// and a fresh AbortSignal — Dart calls them with plain JSON params, and
  /// the wrapper adds what JSON cannot carry (functions).
  ///
  /// Map-returning calls (`getMeta`, `getCatalog`, `getGenres`,
  /// `getCapabilities`) are wrapped in the `{success: true, data: ...}`
  /// envelope `invokeAsync` requires; array-returning calls pass through
  /// unwrapped. A throw inside any call is caught and returned as
  /// `{success: false, errorCode, message}` so Dart gets a structured
  /// `JsPluginException` instead of a bare eval error.
  @visibleForTesting
  String buildIife() => _wrapper;

  String _buildIife() {
    final installerKey = jsonEncode(_installerGlobal);
    final namespaceJson = jsonEncode(_namespace);
    final valueJson = jsonEncode(_value);
    final factoryGlobal = VegaProviderContext.kFactoryGlobal;
    String requiredModule(String name) =>
        jsonEncode(_modules[name]!);
    String optionalModule(String name) => _modules.containsKey(name)
        ? '__loadCjs(${jsonEncode(_modules[name]!)})'
        : 'null';
    return """
globalThis[$installerKey] = function(__ssTok) {
  // CommonJS loader: one fresh module/exports/require per Vega file.
  // `require` only answers node builtins (the Vega build strips those to
  // {}) and throws otherwise — a provider cannot pull in anything else.
  var __vegaRequire = function(name) {
    if (name.indexOf("node:") === 0) return {};
    var __builtins = ["fs","path","http","https","stream","zlib","url","os","crypto","buffer","events","util","querystring","net","tls","child_process"];
    if (__builtins.indexOf(name) >= 0) return {};
    throw new Error("require(" + name + ") is not available in the Vega sandbox");
  };
  var __loadCjs = function(code) {
    var module = {exports: {}};
    var fn = new Function("module", "exports", "require", code);
    fn(module, module.exports, __vegaRequire);
    return module.exports;
  };

  var __mods = {
    catalog: __loadCjs(${requiredModule('catalog')}),
    posts: __loadCjs(${requiredModule('posts')}),
    meta: __loadCjs(${requiredModule('meta')}),
    stream: __loadCjs(${requiredModule('stream')}),
    episodes: ${optionalModule('episodes')},
    settings: ${optionalModule('settings')}
  };

  // One providerContext per provider, bound to this provider's token.
  // The factory is loaded once per engine by VegaProviderContext; if it is
  // missing the install fails here, closed, instead of running the provider
  // without a context.
  var providerContext = globalThis["$factoryGlobal"](__ssTok);

  var __signal = function() {
    return {
      aborted: false,
      addEventListener: function() {},
      removeEventListener: function() {},
      throwIfAborted: function() { if (this.aborted) throw new Error("The operation was aborted"); }
    };
  };
  var __err = function(e) {
    return {success: false, errorCode: "VEGA_ERROR", message: (e && e.message) || String(e)};
  };
  // Map-returning calls: invokeAsync unwraps {success, data}.
  var __wrapMap = function(fn) {
    return async function() {
      try { var r = await fn.apply(null, arguments); return {success: true, data: r}; }
      catch (e) { return __err(e); }
    };
  };
  // Array-returning calls: invokeAsync passes arrays through unwrapped.
  // A throw still returns the error envelope, so Dart gets a structured
  // JsPluginException instead of a bare eval error.
  var __wrapList = function(fn) {
    return async function() {
      try { return await fn.apply(null, arguments); }
      catch (e) { return __err(e); }
    };
  };

  globalThis[$namespaceJson] = {
    getCatalog: __wrapMap(async function() {
      var c = __mods.catalog.catalog;
      if (typeof c === "function") c = await c({signal: __signal(), providerContext: providerContext});
      return c || [];
    }),
    getGenres: __wrapMap(async function() {
      var g = __mods.catalog.genres;
      if (typeof g === "function") g = await g({signal: __signal(), providerContext: providerContext});
      return g || [];
    }),
    getPosts: __wrapList(function(params) {
      return __mods.posts.getPosts({filter: params.filter, page: params.page, providerValue: $valueJson, signal: __signal(), providerContext: providerContext});
    }),
    getSearchPosts: __wrapList(function(params) {
      return __mods.posts.getSearchPosts({searchQuery: params.searchQuery, page: params.page, providerValue: $valueJson, signal: __signal(), providerContext: providerContext});
    }),
    getMeta: __wrapMap(function(params) {
      return __mods.meta.getMeta({link: params.link, provider: $valueJson, providerContext: providerContext});
    }),
    getEpisodes: __mods.episodes ? __wrapList(function(params) {
      return __mods.episodes.getEpisodes({url: params.url, providerContext: providerContext});
    }) : undefined,
    getStream: __wrapList(function(params) {
      return __mods.stream.getStream({link: params.link, type: params.type, signal: __signal(), providerContext: providerContext, isDownload: !!params.isDownload});
    }),
    getSettingsSchema: __mods.settings ? __wrapList(function() {
      return __mods.settings.getSettingsSchema({providerContext: providerContext});
    }) : undefined,
    getCapabilities: __wrapMap(async function() {
      return {
        hasSearchPosts: typeof __mods.posts.getSearchPosts === "function",
        hasEpisodes: !!__mods.episodes,
        hasSettings: !!__mods.settings
      };
    })
  };
};
""";
  }

  /// Hands the installer its bridge token. Mirrors
  /// [JsBasedProvider._installBridgeToken]: the token is only given when
  /// the installer slot holds this provider's own plain configurable
  /// function, and it is deleted after the one-shot handoff — if the slot
  /// is occupied by another namespace the install fails closed (see the
  /// comment on JsBasedProvider's version for the full rationale).
  Future<void> _installBridgeToken() async {
    final installer = _installerGlobal;
    final token = _jsEngine.mintBridgeToken(
      namespace: _namespace,
      packageName: packageName,
    );
    final key = jsonEncode(installer);
    final warn = jsonEncode(
      '[bridge] installer slot $installer is not this plugin\'s own — '
      'refusing to hand over its capability token',
    );
    await _jsEngine.loadScript(
      '(function(){'
      'var __d = Object.getOwnPropertyDescriptor(globalThis, $key);'
      'if (!__d) return;'
      'try { delete globalThis[$key]; } catch (e) {}'
      'if (typeof __d.value !== "function" || !__d.configurable) {'
      'try { console.error($warn); } catch (e) {} return; }'
      '__d.value(${jsonEncode(token)});'
      '})();',
      tag: packageName,
    );
  }

  String? get _qbcPath {
    final dir = _bytecodeDir;
    if (dir == null) return null;
    // The filename carries the wrapper version AND a hash of the wrapper
    // text: the sources live in memory (no file mtime to compare), so the
    // name itself is the freshness key. A changed wrapper or changed module
    // source compiles to a new file instead of reusing stale bytecode.
    final digest =
        sha256.convert(utf8.encode(_wrapper)).toString().substring(0, 12);
    return '$dir/${_namespace}_v${_vegaWrapperVersion}_$digest.qbc';
  }

  /// Precompiles the wrapper to a `.qbc` for the next launch (the .qbc
  /// fast path in [_init]). A no-op when there is no bytecode directory.
  /// Returns true when a compile actually ran.
  Future<bool> precompile() async {
    final qbc = _qbcPath;
    if (qbc == null) return false;
    final file = File(qbc);
    if (await file.exists()) return false;
    return JsBytecodeCompiler.compile(_wrapper, qbc);
  }

  /// Deletes this provider's compiled wrapper bytecode.
  Future<void> deleteBytecode() async {
    final qbc = _qbcPath;
    if (qbc == null) return;
    try {
      final file = File(qbc);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _init() async {
    try {
      await VegaProviderContext.ensureLoaded(_jsEngine);
    } catch (e) {
      _error = 'Context: $e';
      if (kDebugMode) {
        debugPrint(
          'VegaBasedProvider: context load failed for $packageName: $e',
        );
      }
      return;
    }

    final wrapper = _wrapper;
    final qbc = _qbcPath;

    try {
      if (qbc != null) {
        final file = File(qbc);
        if (await file.exists()) {
          try {
            final bytes = await file.readAsBytes();
            await _jsEngine.loadBytes(bytes, tag: packageName);
            await _installBridgeToken();
            await _loadCapabilities();
            if (kDebugMode) {
              talker.debug(
                'VegaBasedProvider: loaded bytecode for $packageName',
              );
            }
            return;
          } on JsEvalCancelledException {
            rethrow;
          } catch (e) {
            talker.warning(
              'VegaBasedProvider: discarding unusable bytecode for '
              '$packageName, recompiling from source: $e',
            );
            try {
              await File(qbc).delete();
            } catch (_) {}
          }
        }
      }

      await _jsEngine.loadScript(wrapper, tag: packageName);
      await _installBridgeToken();
      await _loadCapabilities();
      if (kDebugMode) {
        talker.debug('VegaBasedProvider: loaded script for $packageName');
      }

      if (qbc != null) {
        JsBytecodeCompiler.compile(wrapper, qbc).ignore();
      }
    } on JsEvalCancelledException {
      _initFuture = null;
      _error = null;
      return;
    } catch (e) {
      _error = 'Eval: $e';
      if (kDebugMode) {
        debugPrint(
          'VegaBasedProvider: CRITICAL - Eval failed for $packageName: $e',
        );
      }
    }
  }

  Future<void> _loadCapabilities() async {
    try {
      final result = await _jsEngine.invokeAsync(_fn('getCapabilities'));
      if (result is Map) {
        final map = Map<String, dynamic>.from(result);
        _capabilities = _VegaCapabilities(
          hasSearchPosts: (map['hasSearchPosts'] as bool?) ?? false,
          hasEpisodes: (map['hasEpisodes'] as bool?) ?? false,
          hasSettings: (map['hasSettings'] as bool?) ?? false,
        );
        return;
      }
    } catch (_) {
      // A provider whose capabilities call fails degrades to the safe
      // defaults below instead of failing init outright.
    }
    _capabilities = const _VegaCapabilities(
      hasSearchPosts: false,
      hasEpisodes: false,
      hasSettings: false,
    );
  }

  String _fn(String name) => '$_namespace.$name';

  /// Serializes invocations through this provider. The shared JS runtime
  /// is single-threaded but async-yields between bridge calls, so two
  /// concurrent calls would interleave at every `await` point and clobber
  /// each other's local variables (same reason as JsBasedProvider's
  /// `_serializedInvoke`).
  Future<T> _serializedInvoke<T>(Future<T> Function() fn) async {
    while (_invokeLock != null) {
      await _invokeLock!;
    }
    final completer = Completer<void>();
    _invokeLock = completer.future;
    try {
      return await fn();
    } finally {
      _invokeLock = null;
      completer.complete();
    }
  }

  /// Drops this provider's exports from the shared JS runtime and revokes
  /// its bridge token (see [JsEngineService.unload]). Called when the
  /// provider is removed; a reload mints a fresh token.
  void dispose() {
    _jsEngine.unload(_namespace);
  }

  // ---------------------------------------------------------------------------
  // SkyStreamProvider implementation
  // ---------------------------------------------------------------------------

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    await _ensureReady();
    if (_error != null) throw JsPluginException('INIT_ERROR', _error!);
    return _serializedInvoke(() async {
      try {
        final caps = _capabilities;
        final dynamic result;
        if (caps != null && caps.hasSearchPosts) {
          result = await _jsEngine.invokeAsync(_fn('getSearchPosts'), [
            {'searchQuery': query, 'page': 1, 'providerValue': _value},
          ], cancelToken);
        } else {
          // The provider has no getSearchPosts (the template calls it
          // optional, ProviderType requires it): ask getPosts with the
          // query as the filter instead of failing the search outright.
          result = await _jsEngine.invokeAsync(_fn('getPosts'), [
            {'filter': query, 'page': 1, 'providerValue': _value},
          ], cancelToken);
        }
        if (result is! List) return <MultimediaItem>[];
        final bounded = result.length > _kVegaMaxResultListLength
            ? result.sublist(0, _kVegaMaxResultListLength)
            : result;
        return bounded
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => _postToItem(Map<String, dynamic>.from(e)))
            .where((item) => item.url.isNotEmpty)
            .toList(growable: false);
      } on JsPluginException {
        rethrow;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('VegaBasedProvider: search error for $packageName: $e');
        }
        return <MultimediaItem>[];
      }
    });
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    await _ensureReady();
    if (_error != null) throw JsPluginException('INIT_ERROR', _error!);
    return _serializedInvoke(() async {
      try {
        final catalog = await _jsEngine.invokeAsync(_fn('getCatalog'));
        if (catalog is! List) {
          throw Exception('Extension returned invalid home data (not a map).');
        }
        // One getPosts per catalog entry, in order. NOT concurrent: the
        // namespace exports are thin wrappers, but a provider may keep
        // per-call state in module-level variables across its own awaits,
        // and concurrent calls would clobber it (same reason as
        // _serializedInvoke). A failed section is skipped instead of
        // failing all of home.
        final sections = <String, List<MultimediaItem>>{};
        for (final entry in catalog.whereType<Map<dynamic, dynamic>>()) {
          final title = (entry['title'] as String?) ?? '';
          final filter = (entry['filter'] as String?) ?? '';
          if (title.isEmpty) continue;
          // Remember the section's filter for [getCatalogPage] (the Home
          // "View All" page). The filter may legitimately be ''.
          if (_catalogFilters.length >= _kVegaMaxCatalogFilters) {
            _catalogFilters.clear();
          }
          _catalogFilters[title] = filter;
          try {
            final posts = await _jsEngine.invokeAsync(_fn('getPosts'), [
              {'filter': filter, 'page': 1, 'providerValue': _value},
            ]);
            if (posts is! List) continue;
            final items = posts
                .whereType<Map<dynamic, dynamic>>()
                .map((e) => _postToItem(Map<String, dynamic>.from(e)))
                .where((item) => item.url.isNotEmpty)
                .toList(growable: false);
            if (items.isNotEmpty) sections[title] = items;
          } catch (e) {
            if (kDebugMode) {
              debugPrint(
                'VegaBasedProvider: home section "$title" failed for '
                '$packageName: $e',
              );
            }
          }
        }
        return sections;
      } on JsPluginException {
        rethrow;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('VegaBasedProvider: getHome error for $packageName: $e');
        }
        talker.error('VegaBasedProvider: getHome error for $packageName: $e');
        throw Exception('Failed to load home content: $e');
      }
    });
  }

  /// One page of a catalog section's posts, for the Home "View All" page.
  /// [sectionTitle] is the catalog entry's title (the Home row title); the
  /// filter is resolved from [_catalogFilters], re-reading the catalog on a
  /// miss. Returns [] for an unknown section or any error — the caller
  /// treats an empty page as the end of the list. Page numbers are 1-based,
  /// like the provider's `getPosts`.
  Future<List<MultimediaItem>> getCatalogPage(
    String sectionTitle,
    int page,
  ) async {
    try {
      await _ensureReady();
    } catch (_) {
      return <MultimediaItem>[];
    }
    if (_error != null) return <MultimediaItem>[];
    return _serializedInvoke(() async {
      try {
        var filter = _catalogFilters[sectionTitle];
        if (filter == null) {
          await _refreshCatalogFilters();
          filter = _catalogFilters[sectionTitle];
        }
        if (filter == null) return <MultimediaItem>[];
        final posts = await _jsEngine.invokeAsync(_fn('getPosts'), [
          {'filter': filter, 'page': page, 'providerValue': _value},
        ]);
        if (posts is! List) return <MultimediaItem>[];
        return posts
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => _postToItem(Map<String, dynamic>.from(e)))
            .where((item) => item.url.isNotEmpty)
            .toList(growable: false);
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            'VegaBasedProvider: getCatalogPage error for $packageName: $e',
          );
        }
        return <MultimediaItem>[];
      }
    });
  }

  /// Re-reads the provider's catalog and rebuilds [_catalogFilters].
  /// Used when [getCatalogPage] is asked for a section title the cache
  /// does not know (e.g. the provider instance was recreated since Home
  /// loaded). Returns true when the map was rebuilt.
  Future<bool> _refreshCatalogFilters() async {
    try {
      final catalog = await _jsEngine.invokeAsync(_fn('getCatalog'));
      if (catalog is! List) return false;
      _catalogFilters.clear();
      for (final entry in catalog.whereType<Map<dynamic, dynamic>>()) {
        final title = (entry['title'] as String?) ?? '';
        if (title.isEmpty) continue;
        if (_catalogFilters.length >= _kVegaMaxCatalogFilters) break;
        _catalogFilters[title] = (entry['filter'] as String?) ?? '';
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          'VegaBasedProvider: catalog refresh failed for $packageName: $e',
        );
      }
      return false;
    }
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    await _ensureReady();
    if (_error != null) throw JsPluginException('INIT_ERROR', _error!);
    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('getMeta'), [
          {'link': url},
        ]);
        if (result is! Map) {
          throw Exception('Extension returned invalid detail data.');
        }
        return await _infoToItem(Map<String, dynamic>.from(result), url);
      } on JsPluginException {
        rethrow;
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            'VegaBasedProvider: getDetails error for $packageName: $e',
          );
        }
        talker.error(
          'VegaBasedProvider: getDetails error for $packageName: $e',
        );
        return MultimediaItem(title: 'Error: $e', url: url, posterUrl: '');
      }
    });
  }

  @override
  Future<List<StreamResult>> loadStreams(
    String url, {
    bool isDownload = false,
  }) async {
    await _ensureReady();
    if (_error != null) throw JsPluginException('INIT_ERROR', _error!);
    return _serializedInvoke(() async {
      try {
        // Resolve the media link and its type. An episode URL (recorded by
        // getDetails) goes straight to getStream as a series link; anything
        // else is a details URL and goes through getMeta first, which names
        // the playable link. A getMeta failure falls back to treating the
        // URL as a direct link (a cold start where the episode was never
        // seen by getDetails this session).
        var streamLink = url;
        var streamType = 'series';
        if (!_episodeLinks.contains(url)) {
          try {
            final meta = await _jsEngine.invokeAsync(_fn('getMeta'), [
              {'link': url},
            ]);
            if (meta is Map) {
              final info = Map<String, dynamic>.from(meta);
              final resolved = await _firstStreamLink(info);
              if (resolved != null) {
                streamLink = resolved;
                streamType = (info['type'] as String?) ?? 'movie';
              }
            }
          } catch (_) {
            // Fall through: try getStream on the URL as given.
          }
        }
        final result = await _jsEngine.invokeAsync(_fn('getStream'), [
          {'link': streamLink, 'type': streamType, 'isDownload': isDownload},
        ]);
        if (result is! List) return <StreamResult>[];
        final bounded = result.length > _kVegaMaxStreamsPerCall
            ? result.sublist(0, _kVegaMaxStreamsPerCall)
            : result;
        final streams = <StreamResult>[];
        for (final entry in bounded) {
          if (entry is! Map) continue;
          final stream = _streamToResult(Map<String, dynamic>.from(entry));
          if (stream != null) streams.add(stream);
        }
        return streams;
      } on JsPluginException {
        rethrow;
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            'VegaBasedProvider: loadStreams error for $packageName: $e',
          );
        }
        talker.error(
          'VegaBasedProvider: loadStreams error for $packageName: $e',
        );
        return <StreamResult>[];
      }
    });
  }

  // Not an override: SkyStreamProvider declares no getSettings (same as
  // JsBasedProvider). Phase 3's ExtensionManager reads it directly.
  Future<List<PluginSettingDefinition>> getSettings() async {
    await _ensureReady();
    if (_error != null) return const [];
    final caps = _capabilities;
    if (caps == null || !caps.hasSettings) return const [];
    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('getSettingsSchema'));
        if (result is! List) return const [];
        return result
            .take(100)
            .whereType<Map<dynamic, dynamic>>()
            .map(
              (raw) => PluginSettingDefinition.fromJson(
                _normalizeVegaSetting(Map<String, dynamic>.from(raw)),
              ),
            )
            .where((setting) => setting.key.isNotEmpty)
            .toList(growable: false);
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            'VegaBasedProvider: getSettingsSchema unavailable for '
            '$packageName: $e',
          );
        }
        return const [];
      }
    });
  }

  /// The provider's genre list (from `catalog.ts`), for a later filter UI.
  /// Not used by [getHome] (catalog entries are the home sections).
  Future<List<Map<String, String>>> getGenres() async {
    await _ensureReady();
    if (_error != null) return const [];
    return _serializedInvoke(() async {
      try {
        final result = await _jsEngine.invokeAsync(_fn('getGenres'));
        if (result is! List) return const [];
        return result
            .whereType<Map<dynamic, dynamic>>()
            .map(
              (e) => {
                'title': (e['title'] as String?) ?? '',
                'filter': (e['filter'] as String?) ?? '',
              },
            )
            .where((e) => e['title']!.isNotEmpty)
            .toList(growable: false);
      } catch (_) {
        return const [];
      }
    });
  }

  /// Skip intervals a provider returned for [streamUrl] (seconds), parsed
  /// and validated. No consumer yet: StreamResult carries no skip field and
  /// the player reads its segments from its own services. Phase 4 wires
  /// these in (a StreamResult field plus a merge in the players' skip
  /// loading) — until then they are recorded and readable, not dropped.
  List<VegaSkipInterval> skipIntervalsFor(String streamUrl) =>
      _skipIntervals[streamUrl] ?? const [];

  // ---------------------------------------------------------------------------
  // Vega -> Fuse type mapping
  // ---------------------------------------------------------------------------

  MultimediaItem _postToItem(Map<String, dynamic> post) {
    final link = (post['link'] as String?) ?? '';
    final image = (post['image'] as String?) ?? '';
    if (link.isNotEmpty && image.isNotEmpty) {
      if (_listingImages.length >= _kVegaMaxListingImages) {
        _listingImages.clear();
      }
      _listingImages[link] = image;
    }
    return MultimediaItem(
      title: (post['title'] as String?) ?? '',
      url: link,
      posterUrl: image,
      provider: packageName,
      source: _displayName,
    );
  }

  Future<MultimediaItem> _infoToItem(
    Map<String, dynamic> info,
    String url,
  ) async {
    final type = MultimediaItem.parseContentType(info['type'] as String?);
    final isSeries = type == MultimediaContentType.series;
    final imdbId = _validImdbId(info['imdbId'] as String?);
    final tmdbId = switch (info['tmdbId']) {
      final int id => id,
      final String s => int.tryParse(s),
      _ => null,
    };
    final score = switch (info['rating']) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s),
      _ => null,
    };
    final tags = _stringList(info['tags']);
    final cast = _stringList(info['cast'])
        ?.map((name) => Actor(name: name))
        .toList(growable: false);
    final linkList = (info['linkList'] as List?) ?? const [];
    final seasonNames = <SeasonName>[];
    var seasonIndex = 0;
    for (final entry in linkList) {
      if (entry is! Map) continue;
      seasonIndex++;
      final title = (entry['title'] as String?) ?? '';
      if (title.isNotEmpty) {
        seasonNames.add(SeasonName(season: seasonIndex, name: title));
      }
    }

    List<Episode>? episodes;
    if (isSeries || type == MultimediaContentType.anime) {
      episodes = await _episodesFromLinkList(linkList);
    } else if (type == MultimediaContentType.movie ||
        type == MultimediaContentType.other) {
      // A film has no episode list, but the details page's Play button is
      // gated on `episodes` being non-empty — without one the button is
      // dead and neither tap (direct play) nor hold (links sheet) works.
      // A film is one episode: itself. The episodes section is gated on
      // !isMovie, so this never draws episode UI for a film.
      episodes = [
        Episode(
          name: (info['title'] as String?) ?? '',
          url: url,
        ),
      ];
    }
    // A livestream keeps episodes null, as before.

    // getMeta may return no image at all (empty string, not null) while
    // the listing that led here carried a poster — fall back to it so the
    // details hero is not left on the placeholder.
    final metaImage = _nonEmpty(info['poster']) ?? _nonEmpty(info['image']);
    final image = metaImage ?? _listingImages[url];

    return MultimediaItem(
      title: (info['title'] as String?) ?? '',
      url: url,
      posterUrl: image ?? '',
      bannerUrl: image,
      logoUrl: info['logo'] as String?,
      description: info['synopsis'] as String?,
      contentType: type,
      episodes: episodes,
      provider: packageName,
      source: _displayName,
      tags: tags,
      cast: cast,
      score: score,
      tmdbId: tmdbId,
      imdbId: imdbId,
      seasonNames: seasonNames.isEmpty ? null : seasonNames,
    );
  }

  Future<List<Episode>> _episodesFromLinkList(List<dynamic> linkList) async {
    final episodes = <Episode>[];
    var seasonIndex = 0;
    for (final entry in linkList) {
      if (entry is! Map) continue;
      seasonIndex++;
      final season = seasonIndex;
      final directLinks = (entry['directLinks'] as List?) ?? const [];
      if (directLinks.isNotEmpty) {
        var episodeIndex = 0;
        for (final dl in directLinks) {
          if (dl is! Map) continue;
          final link = (dl['link'] as String?) ?? '';
          if (link.isEmpty) continue;
          episodeIndex++;
          episodes.add(
            _episodeFromLink(
              Map<String, dynamic>.from(dl),
              link,
              season,
              episodeIndex,
            ),
          );
        }
        continue;
      }
      // Dynamic season: only an episodesLink, no direct links.
      final episodesLink = (entry['episodesLink'] as String?) ?? '';
      if (episodesLink.isEmpty) continue;
      try {
        final result = await _jsEngine.invokeAsync(_fn('getEpisodes'), [
          {'url': episodesLink},
        ]);
        if (result is! List) continue;
        var episodeIndex = 0;
        for (final e in result) {
          if (e is! Map) continue;
          final link = (e['link'] as String?) ?? '';
          if (link.isEmpty) continue;
          episodeIndex++;
          episodes.add(
            _episodeFromLink(
              Map<String, dynamic>.from(e),
              link,
              season,
              episodeIndex,
            ),
          );
        }
      } catch (e) {
        // One bad season must not fail the details.
        if (kDebugMode) {
          debugPrint(
            'VegaBasedProvider: getEpisodes failed for $packageName: $e',
          );
        }
      }
    }
    return episodes;
  }

  Episode _episodeFromLink(
    Map<String, dynamic> link,
    String url,
    int season,
    int episode,
  ) {
    final episodeLink = Episode(
      name: (link['title'] as String?) ?? 'Episode $episode',
      url: url,
      season: season,
      episode: episode,
      description: link['description'] as String?,
      posterUrl: link['image'] as String?,
    );
    _rememberEpisodeLink(url);
    return episodeLink;
  }

  void _rememberEpisodeLink(String url) {
    if (_episodeLinks.length >= _kVegaMaxEpisodeLinks) _episodeLinks.clear();
    _episodeLinks.add(url);
  }

  /// The first playable link in an Info's linkList: a static season's
  /// first direct link, or a dynamic season's first episode link (via
  /// getEpisodes).
  Future<String?> _firstStreamLink(Map<String, dynamic> info) async {
    final linkList = (info['linkList'] as List?) ?? const [];
    for (final entry in linkList) {
      if (entry is! Map) continue;
      final directLinks = (entry['directLinks'] as List?) ?? const [];
      for (final dl in directLinks) {
        if (dl is Map) {
          final link = (dl['link'] as String?) ?? '';
          if (link.isNotEmpty) return link;
        }
      }
      final episodesLink = (entry['episodesLink'] as String?) ?? '';
      if (episodesLink.isEmpty) continue;
      try {
        final result = await _jsEngine.invokeAsync(_fn('getEpisodes'), [
          {'url': episodesLink},
        ]);
        if (result is List) {
          for (final e in result) {
            if (e is Map) {
              final link = (e['link'] as String?) ?? '';
              if (link.isNotEmpty) return link;
            }
          }
        }
      } catch (_) {
        // A season that will not list its episodes: try the next one.
      }
    }
    return null;
  }

  StreamResult? _streamToResult(Map<String, dynamic> s) {
    final link = (s['link'] as String?) ?? '';
    if (link.isEmpty) return null;
    final server = (s['server'] as String?) ?? 'Unknown';
    final type = (s['type'] as String?)?.toLowerCase() ?? '';
    // An adaptive container (HLS master / DASH manifest) offers several
    // renditions, which the player lists in its Quality tab: quality 0.
    // A fixed file takes the provider's height.
    final quality =
        (type == 'm3u8' || type == 'hls' || type == 'mpd' || type == 'dash')
            ? 0
            : parseStreamQuality(s['quality']);
    final headers = s['headers'] is Map
        ? Map<String, String>.from(
            (s['headers'] as Map).map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            ),
          )
        : null;
    final subtitles = _subtitleFiles(s['subtitles']);
    final drm = s['drm'] is Map
        ? Map<String, dynamic>.from(s['drm'] as Map)
        : null;
    String? drmKid;
    String? drmKey;
    String? licenseUrl;
    if (drm != null) {
      final drmType = (drm['type'] as String?)?.toLowerCase();
      if (drmType == 'clearkey') {
        final clearKeys = drm['clearKeys'];
        if (clearKeys is Map && clearKeys.isNotEmpty) {
          final first = clearKeys.entries.first;
          drmKid = first.key.toString();
          drmKey = first.value.toString();
        }
      } else if (drmType == 'widevine') {
        final server = drm['licenseServer'] as String?;
        if (server != null && server.isNotEmpty) licenseUrl = server;
      }
      // playready / fairplay: no Android player path in Phase 2. The
      // stream is still listed without DRM fields; it will fail at
      // playback like any undecryptable link, and the user can pick
      // another server.
    }
    _recordSkipIntervals(link, s['skip']);
    return StreamResult(
      url: link,
      source: server,
      providerName: _displayName,
      quality: quality,
      headers: headers,
      subtitles: subtitles,
      drmKid: drmKid,
      drmKey: drmKey,
      licenseUrl: licenseUrl,
    );
  }

  List<SubtitleFile>? _subtitleFiles(dynamic raw) {
    if (raw is! List) return null;
    final files = <SubtitleFile>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final uri = (entry['uri'] as String?) ?? '';
      if (uri.isEmpty) continue;
      files.add(
        SubtitleFile(
          url: uri,
          label:
              (entry['title'] as String?) ??
              (entry['language'] as String?) ??
              'Unknown',
          lang: entry['language'] as String?,
        ),
      );
    }
    return files.isEmpty ? null : files;
  }

  void _recordSkipIntervals(String streamUrl, dynamic raw) {
    if (raw is! List) return;
    final intervals = <VegaSkipInterval>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final from = (entry['from'] as num?)?.toDouble();
      final to = (entry['to'] as num?)?.toDouble();
      if (from == null || to == null || to <= from || from < 0) continue;
      intervals.add(
        VegaSkipInterval(
          title: entry['title'] as String?,
          fromSec: from,
          toSec: to,
        ),
      );
    }
    if (intervals.isEmpty) return;
    if (_skipIntervals.length >= _kVegaMaxSkipUrls) _skipIntervals.clear();
    _skipIntervals[streamUrl] = intervals;
  }

  /// Vega settings fields (`getSettingsSchema`) use `label` for the title
  /// and field types the Fuse settings UI does not have one-to-one:
  /// `multiselect` becomes a toggle group (one toggle per option) and
  /// `number` becomes plain text (its default is stringified by
  /// PluginSettingDefinition.fromJson).
  Map<String, dynamic> _normalizeVegaSetting(Map<String, dynamic> raw) {
    final type = (raw['type'] as String?)?.toLowerCase() ?? 'text';
    final mappedType = switch (type) {
      'select' => 'select',
      'multiselect' => 'toggle_group',
      'toggle' => 'toggle',
      _ => 'text',
    };
    return {
      'key': raw['key'],
      'title': raw['label'] ?? raw['key'],
      'description': raw['description'],
      'type': mappedType,
      'defaultValue': raw['defaultValue'],
      'options': raw['options'],
    };
  }

  /// A non-empty string, or null for anything else (null, empty string,
  /// non-string). getMeta returns `image=""` (empty, not null) for some
  /// titles, so a plain `??` would keep the empty value.
  String? _nonEmpty(dynamic value) =>
      value is String && value.isNotEmpty ? value : null;

  List<String>? _stringList(dynamic raw) {
    if (raw is! List) return null;
    final list = raw
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return list.isEmpty ? null : list;
  }

  String? _validImdbId(String? id) {
    if (id == null) return null;
    final head = id.trim().split(':').first;
    return RegExp(r'^tt\d{6,}$').hasMatch(head) ? head : null;
  }
}

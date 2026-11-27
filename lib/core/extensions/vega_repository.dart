import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/extension_update_report.dart';
import 'base_provider.dart';
import 'engine/js_engine.dart';
import 'extension_manager.dart';
import 'models/vega_models.dart';
import 'providers.dart';
import 'providers/vega_based_provider.dart';
import 'services/plugin_storage_service.dart';
import 'services/vega_repository_service.dart';

/// Vega provider repositories and installed providers, and the bridge into
/// Raja's provider list.
///
/// The Vega analogue of [CloudStreamRepository]: it owns the sources the
/// user added, fetches their manifests, installs the prebuilt `dist/`
/// bundles under `extensions/vega/<value>/`, and publishes the resulting
/// [VegaBasedProvider]s through
/// `ExtensionManager.setExternalProviders('vega', …)` — the same hook
/// CloudStream uses — so their home pages, search, details and streams go
/// through the same screens as every other provider.
///
/// Storage (see the plan):
/// * the source list is a SharedPreferences string list of manifest URLs
///   (like the `.sky` controller's `repoUrlsKey`);
/// * installed providers live under app-support `extensions/vega/<value>/`
///   as `<module>.js` bundles plus a `meta.json` install record carrying
///   each bundle's SHA-256 (the `.sky` `meta.json` pattern);
/// * a user-disabled provider stays installed on disk but is not published
///   (its package name is kept in a SharedPreferences disabled-set, the
///   `.sky` sub-provider enable pattern).
///
/// Deliberately NOT a `@Riverpod` codegen notifier: a plain
/// [NotifierProvider] needs no generated part file, so this file compiles
/// exactly as written. [build] does no I/O at all — it only declares the
/// external source — so the Extensions screen never watches a load that
/// cannot finish in a test harness; [ensureInitialized] starts the load.
final vegaRepositoryProvider =
    NotifierProvider<VegaRepository, VegaState>(VegaRepository.new);

class VegaRepository extends Notifier<VegaState> {
  /// SharedPreferences key holding the manifest URLs the user added.
  static const String repoUrlsKey = 'vega_repo_urls';

  /// The Vega source present by default: the Zenda-Cross provider
  /// repository, the de facto real-providers repo for the Vega app's
  /// provider system. Seeded on first initialisation when no source is
  /// stored yet, so the Vega tab lists its providers without the user
  /// adding anything.
  static const String defaultSourceInput = 'Zenda-Cross';

  /// SharedPreferences flag recording that the default source was seeded.
  /// Once set, the seed never runs again, so removing the default source
  /// stays removed — a later launch never puts it back.
  static const String defaultSourceSeededKey = 'vega_default_source_seeded';

  /// SharedPreferences key holding the package names the user disabled.
  static const String disabledProvidersKey = 'vega_disabled_providers';

  static const String _source = 'vega';

  bool _initialized = false;

  /// Providers built from the installed bundles, by package name
  /// (`vega.<value>`). A new instance for the active provider would make
  /// Home load again, so they are kept while their version and engine
  /// hold — the same reason CloudStream caches its providers.
  final Map<String, VegaBasedProvider> _providers = {};

  /// The engine the cached providers were built on. A different engine
  /// means their namespaces are gone, so they are rebuilt.
  JsEngineService? _engine;

  /// Module sources read from disk, by provider value. Populated at
  /// install time from the download, so a publish does not re-read the
  /// bundles; dropped on uninstall and on a settings reload.
  final Map<String, Map<String, String>> _moduleSources = {};

  @override
  VegaState build() {
    // A saved active provider that is a Vega one must survive the launch
    // until the providers publish.
    ref.read(extensionManagerProvider.notifier).expectExternalSource(_source);
    return const VegaState();
  }

  /// Call once (from app startup and from the Extensions screen) to load
  /// the sources and installed providers. Never throws: a load failure
  /// lands in state instead of escaping into a post-frame callback.
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _load();
    } catch (_) {
      if (state.isLoading) state = state.copyWith(isLoading: false);
    }
  }

  Future<void> _load() async {
    state = state.copyWith(isLoading: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      var urls = prefs.getStringList(repoUrlsKey) ?? const <String>[];
      final disabled = <String>{
        ...?prefs.getStringList(disabledProvidersKey),
      };
      // The default source: a fresh install — or one that never added a
      // Vega source — gets Zenda-Cross without the user adding anything,
      // so the Vega tab lists its providers from the first launch. The
      // seeded flag is written only after the URL list is persisted, so
      // a failed write retries next launch; once set, the seed never runs
      // again, so removing the source stays removed.
      if (urls.isEmpty && !(prefs.getBool(defaultSourceSeededKey) ?? false)) {
        try {
          final source = ref
              .read(vegaRepositoryServiceProvider)
              .resolveSource(defaultSourceInput);
          urls = [source.manifestUrl];
          await prefs.setStringList(repoUrlsKey, urls);
          await prefs.setBool(defaultSourceSeededKey, true);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Vega: could not seed the default source: $e');
          }
        }
      }
      final installed = await _listInstalled();

      // The installed providers publish from disk first: Home, search and
      // the details screen must not wait on a manifest fetch to see them.
      // The manifests follow, on the network, and refresh the listings.
      state = state.copyWith(
        isLoading: false,
        repos: [
          for (final url in urls)
            VegaRepo(
              manifestUrl: url,
              label: VegaRepositoryService.labelForManifestUrl(url),
            ),
        ],
        installed: installed,
        disabled: disabled,
        clearError: true,
      );
      await _publish();
      await _refreshManifests();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Re-reads every stored source's manifest. One unreachable source keeps
  /// its last listing (or an empty one); it never takes the others — or
  /// the installed providers, which work from disk — down with it.
  Future<void> _refreshManifests() async {
    final service = ref.read(vegaRepositoryServiceProvider);
    final repos = <VegaRepo>[];
    final available = <String, List<VegaManifestEntry>>{};
    for (final url in state.repos.map((r) => r.manifestUrl)) {
      try {
        final entries = await service.fetchManifest(url);
        repos.add(
          VegaRepo(
            manifestUrl: url,
            label: VegaRepositoryService.labelForManifestUrl(url),
            entries: entries,
            fetchedAt: DateTime.now(),
          ),
        );
        available[url] = entries;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Vega: could not load $url: $e');
        }
        final previous = state.repos
            .where((r) => r.manifestUrl == url)
            .firstOrNull;
        repos.add(
          previous ??
              VegaRepo(
                manifestUrl: url,
                label: VegaRepositoryService.labelForManifestUrl(url),
              ),
        );
        available[url] = state.available[url] ?? const [];
      }
    }
    state = state.copyWith(
      repos: repos,
      available: available,
      updates: _computeUpdates(available, state.installed),
    );
  }

  /// Adds a Vega source from what the user typed — a GitHub username, a
  /// `user/repo`, or a full repository/manifest URL. Returns how many
  /// (non-disabled) providers it lists. A source that is already there is
  /// refreshed instead of duplicated. Throws on an invalid input or an
  /// unreachable manifest; the caller shows the error.
  Future<int> addSource(String input) async {
    final service = ref.read(vegaRepositoryServiceProvider);
    final source = service.resolveSource(input);
    if (state.repos.any((r) => r.manifestUrl == source.manifestUrl)) {
      await refreshSource(source.manifestUrl);
      return state.available[source.manifestUrl]
              ?.where((e) => !e.disabled)
              .length ??
          0;
    }
    final entries = await service.fetchManifest(source.manifestUrl);
    final repo = VegaRepo(
      manifestUrl: source.manifestUrl,
      label: source.label,
      entries: entries,
      fetchedAt: DateTime.now(),
    );
    final prefs = await SharedPreferences.getInstance();
    final urls = [
      ...state.repos.map((r) => r.manifestUrl),
      source.manifestUrl,
    ];
    await prefs.setStringList(repoUrlsKey, urls);
    final repos = [...state.repos, repo];
    final available = {...state.available, source.manifestUrl: entries};
    state = state.copyWith(
      repos: repos,
      available: available,
      updates: _computeUpdates(available, state.installed),
    );
    return entries.where((e) => !e.disabled).length;
  }

  /// Re-reads one source's manifest. Throws on failure; the caller shows
  /// the error and the old listing stays.
  Future<void> refreshSource(String manifestUrl) async {
    final service = ref.read(vegaRepositoryServiceProvider);
    final entries = await service.fetchManifest(manifestUrl);
    final repos = [
      for (final r in state.repos)
        if (r.manifestUrl == manifestUrl)
          r.copyWith(entries: entries, fetchedAt: DateTime.now())
        else
          r,
    ];
    final available = {...state.available, manifestUrl: entries};
    state = state.copyWith(
      repos: repos,
      available: available,
      updates: _computeUpdates(available, state.installed),
    );
  }

  /// Removes a source and uninstalls every provider installed from it.
  Future<void> removeSource(String manifestUrl) async {
    for (final installed in state.installed
        .where((p) => p.repositoryUrl == manifestUrl)
        .toList()) {
      await uninstallProvider(installed, publish: false);
    }
    final repos = state.repos
        .where((r) => r.manifestUrl != manifestUrl)
        .toList();
    final available = {...state.available}..remove(manifestUrl);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      repoUrlsKey,
      repos.map((r) => r.manifestUrl).toList(),
    );
    state = state.copyWith(
      repos: repos,
      available: available,
      updates: _computeUpdates(available, state.installed),
    );
    await _publish();
  }

  /// Installs (or updates, when the provider is already installed) one
  /// provider from its source. Downloads the bundles, verifies their
  /// stamps, and swaps them in atomically-ish: a failed download or a bad
  /// stamp leaves the previous install intact. Throws on failure; the
  /// caller shows the error.
  Future<void> installProvider(
    VegaManifestEntry entry,
    String manifestUrl,
  ) async {
    state = state.copyWith(installing: {...state.installing, entry.value});
    try {
      final service = ref.read(vegaRepositoryServiceProvider);
      final baseUrl = manifestUrl.substring(
        0,
        manifestUrl.length - 'manifest.json'.length,
      );
      final downloaded = await service.downloadModules(baseUrl, entry);
      final record = await _writeInstall(
        entry,
        manifestUrl,
        downloaded.modules,
        downloaded.sha256,
      );
      final installed = [
        for (final p in state.installed)
          if (p.value != entry.value) p,
        record,
      ];
      state = state.copyWith(
        installed: installed,
        installing: state.installing
            .where((v) => v != entry.value)
            .toSet(),
        updates: _computeUpdates(state.available, installed),
      );
      await _publish();
    } catch (e) {
      state = state.copyWith(
        installing: state.installing
            .where((v) => v != entry.value)
            .toSet(),
      );
      rethrow;
    }
  }

  /// Installs the waiting update for [installed], if there is one.
  Future<void> updateProvider(VegaInstalledProvider installed) async {
    final entry = state.updates[installed.packageName];
    if (entry == null) return;
    await installProvider(entry, installed.repositoryUrl);
  }

  /// Installs every provider a source lists that is not installed yet, one
  /// at a time; one bad download does not keep the rest back. Returns the
  /// display names of the ones that went in.
  Future<List<String>> installAll(String manifestUrl) async {
    final installedNames = <String>[];
    for (final entry in state.available[manifestUrl] ?? const []) {
      if (entry.disabled) continue;
      if (state.installedFor(entry.value) != null) continue;
      try {
        await installProvider(entry, manifestUrl);
        installedNames.add(entry.displayName);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Vega install-all skipped ${entry.value}: $e');
        }
      }
    }
    return installedNames;
  }

  /// Uninstalls a provider: its runtime is disposed, its directory (with
  /// its bytecode) is deleted, and it leaves the provider list.
  Future<void> uninstallProvider(
    VegaInstalledProvider installed, {
    bool publish = true,
  }) async {
    _providers.remove(installed.packageName)?.dispose();
    _moduleSources.remove(installed.value);
    final root = await _vegaRoot();
    final dir = resolvePluginPathWithin(root.path, installed.value);
    if (dir != null) {
      final target = Directory(dir);
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
    }
    final remaining = state.installed
        .where((p) => p.value != installed.value)
        .toList();
    final updates = {...state.updates}..remove(installed.packageName);
    state = state.copyWith(installed: remaining, updates: updates);
    if (publish) await _publish();
  }

  /// Enables or disables an installed provider. Disabled stays installed
  /// on disk but is not published, so it leaves Home, search and the
  /// provider list without losing its bundles or settings.
  Future<void> setProviderEnabled(String packageName, bool enabled) async {
    final disabled = {...state.disabled};
    if (enabled) {
      disabled.remove(packageName);
    } else {
      disabled.add(packageName);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(disabledProvidersKey, disabled.toList());
    state = state.copyWith(disabled: disabled);
    await _publish();
  }

  /// The live provider for [value], or null when it is not installed,
  /// disabled, or has not published yet. The settings dialog reads its
  /// `getSettings()` through here.
  VegaBasedProvider? providerForValue(String value) =>
      _providers['vega.$value'];

  /// Reloads a provider from disk (its settings changed): the old runtime
  /// is disposed and a fresh instance publishes in its place.
  Future<void> reloadProvider(String value) async {
    _providers.remove('vega.$value')?.dispose();
    _moduleSources.remove(value);
    await _publish();
  }

  /// Re-reads every source's manifest and records which installed
  /// providers have a newer version waiting. Installs nothing. Returns the
  /// display names with an update waiting.
  Future<List<String>> checkForUpdates() async {
    await _refreshManifests();
    return state.updates.values.map((e) => e.displayName).toList();
  }

  /// The launch-time pass: refreshes the manifests and installs every
  /// waiting update, quietly — one bad update leaves its entry for the
  /// update button to retry instead of raising an error over whatever the
  /// user is doing.
  Future<ExtensionUpdateReport> autoUpdate() async {
    await ensureInitialized();
    if (state.repos.isEmpty) return const ExtensionUpdateReport();
    await checkForUpdates();
    final updated = <String>[];
    for (final entry in state.updates.values.toList()) {
      final installed = state.installedFor(entry.value);
      if (installed == null) continue;
      try {
        await installProvider(entry, installed.repositoryUrl);
        updated.add(entry.displayName);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Vega auto-update failed for ${entry.value}: $e');
        }
      }
    }
    return ExtensionUpdateReport(updated: updated);
  }

  /// The newest version of each installed provider that the repository it
  /// came from lists, when that is newer than what is installed. Only
  /// from that repository: any repository can list a provider under any
  /// name, so matching across all of them would let one replace another's
  /// provider with code of its own.
  Map<String, VegaManifestEntry> _computeUpdates(
    Map<String, List<VegaManifestEntry>> available,
    List<VegaInstalledProvider> installed,
  ) {
    final updates = <String, VegaManifestEntry>{};
    for (final p in installed) {
      final listed = available[p.repositoryUrl];
      if (listed == null) continue;
      VegaManifestEntry? newest;
      for (final online in listed) {
        if (online.value != p.value) continue;
        if (online.disabled) continue;
        if (compareVegaVersions(online.version, p.entry.version) <= 0) {
          continue;
        }
        if (newest == null ||
            compareVegaVersions(online.version, newest.version) > 0) {
          newest = online;
        }
      }
      if (newest != null) updates[p.packageName] = newest;
    }
    return updates;
  }

  /// Hands the current providers to Raja's provider list (none while a
  /// provider is disabled, uninstalled, or failing to load). A provider
  /// instance is kept while its version and engine hold; a version bump
  /// or an engine change rebuilds it. A provider that will not build is
  /// left out, where the user can see it is missing and reinstall it;
  /// it does not keep the others back.
  Future<void> _publish() async {
    final JsEngineService engine;
    try {
      engine = ref.read(jsEngineProvider);
    } catch (e) {
      // The engine is unavailable (a test harness, or a launch that has
      // not built it yet): publish nothing rather than failing the load.
      if (kDebugMode) debugPrint('Vega: no JS engine yet ($e)');
      ref
          .read(extensionManagerProvider.notifier)
          .setExternalProviders(_source, const []);
      return;
    }
    if (!identical(_engine, engine)) {
      for (final provider in _providers.values) {
        provider.dispose();
      }
      _providers.clear();
      _engine = engine;
    }
    final providers = <SkyStreamProvider>[];
    for (final installed in state.installed) {
      if (state.isDisabled(installed.packageName)) continue;
      try {
        final provider = await _providerFor(installed, engine);
        if (provider != null) providers.add(provider);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Vega: could not build ${installed.value}: $e');
        }
      }
    }
    final keep = {for (final p in providers) p.packageName};
    for (final packageName in _providers.keys.toList()) {
      if (!keep.contains(packageName)) {
        _providers.remove(packageName)?.dispose();
      }
    }
    ref
        .read(extensionManagerProvider.notifier)
        .setExternalProviders(_source, providers);
    for (final p in providers) {
      if (p is VegaBasedProvider) unawaited(p.precompile());
    }
  }

  Future<VegaBasedProvider?> _providerFor(
    VegaInstalledProvider installed,
    JsEngineService engine,
  ) async {
    final existing = _providers[installed.packageName];
    if (existing != null && existing.version == installed.entry.version) {
      return existing;
    }
    // A version bump — or a first build — disposes the old runtime before
    // the new one takes its namespace, so two installers never share it.
    existing?.dispose();
    final root = await _vegaRoot();
    final dir = resolvePluginPathWithin(root.path, installed.value);
    if (dir == null) return null;
    final modules =
        _moduleSources[installed.value] ??= await _readModules(dir);
    final provider = VegaBasedProvider(
      engine,
      value: installed.value,
      displayName: installed.entry.displayName,
      version: installed.entry.version,
      modules: modules,
      bytecodeDir: dir,
    );
    _providers[installed.packageName] = provider;
    return provider;
  }

  Future<Map<String, String>> _readModules(String dir) async {
    final modules = <String, String>{};
    for (final name in [
      ...kVegaRequiredModules,
      ...kVegaOptionalModules,
    ]) {
      final file = File(p.join(dir, '$name.js'));
      if (await file.exists()) {
        modules[name] = await file.readAsString();
      }
    }
    for (final required in kVegaRequiredModules) {
      if (!modules.containsKey(required)) {
        throw Exception('Vega install is missing its $required module');
      }
    }
    return modules;
  }

  /// Writes an install the same atomic-ish way the `.sky` installer does:
  /// extract to a staging sibling, then swap it in, so a failure partway
  /// leaves the previous install intact.
  Future<VegaInstalledProvider> _writeInstall(
    VegaManifestEntry entry,
    String manifestUrl,
    Map<String, String> modules,
    Map<String, String> sha256,
  ) async {
    final root = await _vegaRoot();
    final dir = resolvePluginPathWithin(root.path, entry.value);
    if (dir == null) {
      throw Exception(
        'Refusing Vega provider "${entry.value}": unsafe name',
      );
    }
    final staging = Directory(
      p.join(
        root.path,
        '.tmp-install-${entry.value}-'
            '${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    try {
      for (final module in modules.entries) {
        await File(
          p.join(staging.path, '${module.key}.js'),
        ).writeAsString(module.value);
      }
      final record = VegaInstalledProvider(
        entry: entry,
        repositoryUrl: manifestUrl,
        installedAt: DateTime.now(),
        moduleSha256: sha256,
      );
      await File(
        p.join(staging.path, 'meta.json'),
      ).writeAsString(jsonEncode(record.toJson()));
      final target = Directory(dir);
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await staging.rename(dir);
      _moduleSources[entry.value] = Map<String, String>.unmodifiable(modules);
      return record;
    } catch (e) {
      try {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<List<VegaInstalledProvider>> _listInstalled() async {
    final installed = <VegaInstalledProvider>[];
    final root = await _vegaRoot();
    if (!await root.exists()) return installed;
    final children = await root.list().toList();
    for (final entity in children) {
      if (entity is! Directory) continue;
      try {
        final metaFile = File(p.join(entity.path, 'meta.json'));
        if (!await metaFile.exists()) continue;
        final record = VegaInstalledProvider.fromJson(
          jsonDecode(await metaFile.readAsString())
              as Map<String, dynamic>,
        );
        installed.add(record);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Vega: skipping unreadable install at ${entity.path}: $e');
        }
      }
    }
    return installed;
  }

  Future<Directory> _vegaRoot() async {
    final appDocDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDocDir.path, 'extensions', 'vega'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}

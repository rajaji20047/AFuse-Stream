import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/config/tmdb_config.dart';
import '../../../core/storage/settings_repository.dart';

part 'general_settings_provider.g.dart';

/// Which proxy, if any, GitHub downloads go through.
///
/// The design preview's GitHub Proxy choice: None, ghproxy, or a custom
/// proxy. jsDelivr is the fourth value because it is what the old on/off
/// toggle did — rewriting `raw.githubusercontent.com` to
/// `cdn.jsdelivr.net/gh` — so an upgrade from the toggle keeps its behaviour
/// under this name instead of silently changing it.
enum GithubProxyOption {
  /// Direct: no proxy.
  none,

  /// `raw.githubusercontent.com` rewritten to `cdn.jsdelivr.net/gh`
  /// (the old toggle's behaviour).
  jsdelivr,

  /// Prefixed with `https://ghproxy.com/` — the ghproxy mirror.
  ghproxy,

  /// Prefixed with the viewer's own base URL ([GeneralSettings
  /// .githubProxyCustomUrl]).
  custom,
}

/// Nuvio's nav-bar style (Settings → Navigation bar). ADAPTIVE is the
/// default: labels hide on scroll down and return on scroll up. EXPANDED
/// keeps the labels always, COMPACT is icons only.
enum NavBarStyle {
  adaptive,
  expanded,
  compact,
}

class GeneralSettings {
  final bool watchHistoryEnabled;
  final String defaultHomeScreen;

  /// The nav-bar style (Nuvio parity — see [NavBarStyle]).
  final NavBarStyle navBarStyle;

  /// The accent halo under the selection bubble. On by default
  /// (Nuvio's default).
  final bool navBarGlowEnabled;

  /// The pill's liquid-glass layer. On by default; off is a plain
  /// translucent surface (Nuvio's non-glass fallback).
  final bool navBarGlassEnabled;

  /// The unselected icons' colour override (ARGB). Null = default
  /// (white 65% on dark glass, onSurfaceVariant on light).
  final int? navBarIconColorArgb;

  /// The GitHub proxy choice. Replaces the old on/off toggle: a stored
  /// choice of [GithubProxyOption.none] is off, anything else is on.
  final GithubProxyOption githubProxy;

  /// The base URL a Custom proxy prefixes GitHub URLs with. Empty when
  /// never set; a Custom choice with an empty URL behaves as None.
  final String githubProxyCustomUrl;

  /// Whether any proxy is in use — the old toggle's meaning, kept for the
  /// one consumer that only ever asked that.
  bool get githubProxyEnabled => githubProxy != GithubProxyOption.none;

  final bool alwaysOnTop;
  final String titlePosition;
  final String? downloadDirectory;
  final int downloadConcurrency;
  final int downloadChunks;

  /// How many Nuvio providers run in parallel when resolving links.
  /// Default 8, the old fixed cap in `NuvioStreamService`.
  final int nuvioConcurrency;

  /// User-supplied TMDB API key. Empty means "fall back to the build-time
  /// `--dart-define=TMDB_API_KEY` value" (which may itself be empty).
  final String tmdbApiKey;

  /// User-supplied WeTrakr client id. Empty means "fall back to the
  /// build-time `--dart-define=WETRAKR_CLIENT_ID` value" (which may itself
  /// be empty, in which case the WeTrakr row offers to set one up).
  final String wetrakrClientId;

  const GeneralSettings({
    this.watchHistoryEnabled = true,
    this.defaultHomeScreen = '/home',
    this.githubProxy = GithubProxyOption.none,
    this.githubProxyCustomUrl = '',
    this.alwaysOnTop = false,
    this.titlePosition = 'below',
    this.downloadDirectory,
    this.downloadConcurrency = 3,
    this.downloadChunks = 8,
    this.nuvioConcurrency = 8,
    this.tmdbApiKey = '',
    this.wetrakrClientId = '',
    this.navBarStyle = NavBarStyle.adaptive,
    this.navBarGlowEnabled = true,
    this.navBarGlassEnabled = true,
    this.navBarIconColorArgb,
  });

  GeneralSettings copyWith({
    bool? watchHistoryEnabled,
    String? defaultHomeScreen,
    GithubProxyOption? githubProxy,
    String? githubProxyCustomUrl,
    bool? alwaysOnTop,
    String? titlePosition,
    String? downloadDirectory,
    bool clearDownloadDirectory = false,
    int? downloadConcurrency,
    int? downloadChunks,
    int? nuvioConcurrency,
    String? tmdbApiKey,
    String? wetrakrClientId,
    NavBarStyle? navBarStyle,
    bool? navBarGlowEnabled,
    bool? navBarGlassEnabled,
    int? navBarIconColorArgb,
    bool clearNavBarIconColor = false,
  }) {
    return GeneralSettings(
      watchHistoryEnabled: watchHistoryEnabled ?? this.watchHistoryEnabled,
      defaultHomeScreen: defaultHomeScreen ?? this.defaultHomeScreen,
      githubProxy: githubProxy ?? this.githubProxy,
      githubProxyCustomUrl: githubProxyCustomUrl ?? this.githubProxyCustomUrl,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      titlePosition: titlePosition ?? this.titlePosition,
      // Null means "keep" to a nullable field, so clearing the custom
      // directory back to the default needs its own flag — the same shape
      // the player settings' clearPreferredPlayer uses. Without it the
      // Reset-to-default button wrote null to storage while the screen
      // kept showing the old folder until the next launch.
      downloadDirectory: clearDownloadDirectory
          ? null
          : (downloadDirectory ?? this.downloadDirectory),
      downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
      downloadChunks: downloadChunks ?? this.downloadChunks,
      nuvioConcurrency: nuvioConcurrency ?? this.nuvioConcurrency,
      tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
      wetrakrClientId: wetrakrClientId ?? this.wetrakrClientId,
      navBarStyle: navBarStyle ?? this.navBarStyle,
      navBarGlowEnabled: navBarGlowEnabled ?? this.navBarGlowEnabled,
      navBarGlassEnabled: navBarGlassEnabled ?? this.navBarGlassEnabled,
      // Same "null means keep" shape as the download directory: clearing
      // the icon-colour override back to Default needs its own flag.
      navBarIconColorArgb: clearNavBarIconColor
          ? null
          : (navBarIconColorArgb ?? this.navBarIconColorArgb),
    );
  }
}

@Riverpod(keepAlive: true)
class GeneralSettingsNotifier extends _$GeneralSettingsNotifier {
  /// Serialises setting writes (L8): rapid same-field taps used to
  /// race — each setter read `state` at completion time, so the slower
  /// write could overwrite the newer one. Every setter runs through
  /// this chain, in tap order.
  Future<void> _writeChain = Future.value();

  Future<void> _enqueue(Future<void> Function() work) {
    final run = _writeChain.then((_) => work());
    // Keep the chain alive past a failed write (a later tap must still
    // run), while the caller still sees its own write's error.
    _writeChain = run.catchError((_) {});
    return run;
  }

  @override
  GeneralSettings build() {
    final repository = ref.watch(settingsRepositoryProvider);
    // A stored choice wins; without one the legacy toggle decides, so an
    // upgrade from the on/off switch keeps its behaviour (on = jsDelivr).
    // An unrecognised name — written by a newer build, or a corrupted box —
    // reads as None, the safe side.
    final storedOption = repository.getGithubProxyOption();
    final githubProxy = storedOption == null
        ? (repository.isGithubProxyEnabled()
              ? GithubProxyOption.jsdelivr
              : GithubProxyOption.none)
        : GithubProxyOption.values.firstWhere(
            (e) => e.name == storedOption,
            orElse: () => GithubProxyOption.none,
          );
    return GeneralSettings(
      watchHistoryEnabled: repository.isWatchHistoryEnabled(),
      defaultHomeScreen: repository.getDefaultHomeScreen(),
      githubProxy: githubProxy,
      githubProxyCustomUrl: repository.getGithubProxyCustomUrl(),
      alwaysOnTop: repository.isAlwaysOnTop(),
      titlePosition: repository.getTitlePosition(),
      downloadDirectory: repository.getDownloadDirectory(),
      downloadConcurrency: repository.getDownloadConcurrency(),
      downloadChunks: repository.getDownloadChunks(),
      nuvioConcurrency: repository.getNuvioConcurrency(),
      tmdbApiKey: repository.getTmdbApiKey(),
      wetrakrClientId: repository.getWetrakrClientId(),
      // An unrecognised stored name — written by a newer build, or a
      // corrupted box — reads as the default, the safe side (same shape
      // as the GitHub proxy choice above).
      navBarStyle: NavBarStyle.values.firstWhere(
        (e) => e.name == repository.getNavBarStyle(),
        orElse: () => NavBarStyle.adaptive,
      ),
      navBarGlowEnabled: repository.getNavBarGlow(),
      navBarGlassEnabled: repository.getNavBarGlass(),
      navBarIconColorArgb: repository.getNavBarIconColor(),
    );
  }

  Future<void> setWatchHistoryEnabled(bool enabled) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setWatchHistoryEnabled(enabled);
      state = state.copyWith(watchHistoryEnabled: enabled);
    });
  }

  Future<void> setDefaultHomeScreen(String path) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setDefaultHomeScreen(path);
      state = state.copyWith(defaultHomeScreen: path);
    });
  }

  /// Picks the GitHub proxy, and the custom base URL when the choice is
  /// Custom. A Custom choice with an empty URL behaves as None (see
  /// [applyGithubProxy]); the empty URL is still stored, so the field the
  /// viewer typed is not lost when they come back.
  Future<void> setGithubProxy(
    GithubProxyOption option, {
    String? customUrl,
  }) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setGithubProxyOption(option.name);
      final url = customUrl?.trim() ?? state.githubProxyCustomUrl;
      if (customUrl != null) {
        await repository.setGithubProxyCustomUrl(url);
      }
      // The legacy toggle mirrors the choice, so anything still reading it —
      // and a downgrade back to the old build — sees the same on/off.
      await repository.setGithubProxyEnabled(option != GithubProxyOption.none);
      state = state.copyWith(githubProxy: option, githubProxyCustomUrl: url);
    });
  }

  Future<void> setGithubProxyEnabled(bool enabled) {
    // Delegates to setGithubProxy (which enqueues); wrapping
    // this too would deadlock, because the outer work would
    // wait on the inner enqueue, which waits on the outer work.
    return setGithubProxy(
      enabled ? GithubProxyOption.jsdelivr : GithubProxyOption.none,
    );
  }

  Future<void> setAlwaysOnTop(bool enabled) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setAlwaysOnTop(enabled);
      state = state.copyWith(alwaysOnTop: enabled);
    });
  }

  Future<void> setTitlePosition(String position) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setTitlePosition(position);
      state = state.copyWith(titlePosition: position);
    });
  }

  /// Nuvio's nav-bar settings (Settings → Navigation bar). Each writes
  /// through to storage and updates the state, so the shell's bar
  /// restyles without an app restart.
  Future<void> setNavBarStyle(NavBarStyle style) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setNavBarStyle(style.name);
      state = state.copyWith(navBarStyle: style);
    });
  }

  Future<void> setNavBarGlowEnabled(bool enabled) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setNavBarGlow(enabled);
      state = state.copyWith(navBarGlowEnabled: enabled);
    });
  }

  Future<void> setNavBarGlassEnabled(bool enabled) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setNavBarGlass(enabled);
      state = state.copyWith(navBarGlassEnabled: enabled);
    });
  }

  /// Pass null to clear the override back to the default icon colour.
  Future<void> setNavBarIconColor(int? argb) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setNavBarIconColor(argb);
      state = state.copyWith(
        navBarIconColorArgb: argb,
        clearNavBarIconColor: argb == null,
      );
    });
  }

  Future<void> setDownloadDirectory(String? path) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setDownloadDirectory(path);
      state = state.copyWith(
        downloadDirectory: path,
        clearDownloadDirectory: path == null,
      );
    });
  }

  Future<void> setDownloadConcurrency(int value) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setDownloadConcurrency(value);
      state = state.copyWith(downloadConcurrency: value);
    });
  }

  Future<void> setNuvioConcurrency(int value) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setNuvioConcurrency(value);
      state = state.copyWith(nuvioConcurrency: value);
    });
  }

  /// Persists a user-supplied TMDB key and mirrors it into [TmdbConfig] so
  /// in-flight screens pick it up without an app restart. Passing an empty
  /// string clears the override and reverts to the build-time key.
  Future<void> setTmdbApiKey(String value) {
    return _enqueue(() async {
      final trimmed = value.trim();
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setTmdbApiKey(trimmed);
      TmdbConfig.setUserApiKey(trimmed);
      state = state.copyWith(tmdbApiKey: trimmed);
    });
  }

  /// Persists a user-supplied WeTrakr client id. Passing an empty string
  /// clears it and reverts to the build-time id. The Accounts row and the
  /// service both read this state, so they pick it up without a restart.
  Future<void> setWetrakrClientId(String value) {
    return _enqueue(() async {
      final trimmed = value.trim();
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setWetrakrClientId(trimmed);
      state = state.copyWith(wetrakrClientId: trimmed);
    });
  }

  Future<void> setDownloadChunks(int value) {
    return _enqueue(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setDownloadChunks(value);
      state = state.copyWith(downloadChunks: value);
    });
  }
}

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'storage_service.dart';

part 'settings_repository.g.dart';

@Riverpod(keepAlive: true)
SettingsRepository settingsRepository(Ref ref) {
  return SettingsRepository(ref.watch(storageServiceProvider));
}

class SettingsRepository {
  final StorageService _storageService;

  SettingsRepository(this._storageService);

  Future<void> saveThemeMode(String mode) async {
    await _storageService.saveThemeMode(mode);
  }

  String? getThemeMode() {
    return _storageService.getThemeMode();
  }

  /// Accent color preset name ('gold', 'red', ...). `null` = never picked.
  Future<void> saveAccentColor(String name) async {
    await _storageService.saveAccentColor(name);
  }

  String? getAccentColor() {
    return _storageService.getAccentColor();
  }

  /// Named theme variant name ('arenaGold', 'midnight', 'frost',
  /// 'liquidGlass'). `null` = never picked.
  Future<void> saveThemeVariant(String name) async {
    await _storageService.saveThemeVariant(name);
  }

  String? getThemeVariant() {
    return _storageService.getThemeVariant();
  }

  /// Last dark theme variant name. `null` = never picked a dark variant.
  Future<void> saveLastDarkThemeVariant(String name) async {
    await _storageService.saveLastDarkThemeVariant(name);
  }

  String? getLastDarkThemeVariant() {
    return _storageService.getLastDarkThemeVariant();
  }

  Future<void> setSidebarExpanded(bool expanded) async {
    await _storageService.setSidebarExpanded(expanded);
  }

  bool? getSidebarExpanded() {
    return _storageService.getSidebarExpanded();
  }

  Future<void> setFullScreenMode(bool enabled) async {
    await _storageService.setFullScreenMode(enabled);
  }

  bool? getFullScreenMode() {
    return _storageService.getFullScreenMode();
  }

  Future<void> setDefaultHomeScreen(String path) async {
    await _storageService.setDefaultHomeScreen(path);
  }

  String getDefaultHomeScreen() {
    return _storageService.getDefaultHomeScreen();
  }

  Future<void> setDownloadDirectory(String? path) =>
      _storageService.setDownloadDirectory(path);

  String? getDownloadDirectory() => _storageService.getDownloadDirectory();

  Future<void> setDownloadConcurrency(int value) =>
      _storageService.setDownloadConcurrency(value);

  int getDownloadConcurrency() => _storageService.getDownloadConcurrency();

  Future<void> setNuvioConcurrency(int value) =>
      _storageService.setNuvioConcurrency(value);

  int getNuvioConcurrency() => _storageService.getNuvioConcurrency();

  Future<void> setDownloadChunks(int value) =>
      _storageService.setDownloadChunks(value);

  int getDownloadChunks() => _storageService.getDownloadChunks();

  /// User-supplied TMDB API key. Empty string means "not set" — callers fall
  /// back to the compile-time `--dart-define=TMDB_API_KEY` value.
  static const String kTmdbApiKey = 'tmdb_api_key';

  Future<void> setTmdbApiKey(String value) =>
      _storageService.setString(kTmdbApiKey, value.isEmpty ? null : value);

  String getTmdbApiKey() => _storageService.getString(kTmdbApiKey) ?? '';

  /// User-supplied WeTrakr client id, entered in Accounts. Empty string
  /// means "not set" — callers fall back to the compile-time
  /// `--dart-define=WETRAKR_CLIENT_ID` value.
  static const String kWetrakrClientId = 'wetrakr_client_id';

  Future<void> setWetrakrClientId(String value) =>
      _storageService.setString(kWetrakrClientId, value.isEmpty ? null : value);

  String getWetrakrClientId() =>
      _storageService.getString(kWetrakrClientId) ?? '';

  /// User-supplied Simkl AUTH V2 client id, entered in Accounts. Empty
  /// string means "not set" — callers fall back to the compile-time
  /// `--dart-define=SIMKL_V2_CLIENT_ID` value. V2 is the only sign-in
  /// path offered in Accounts (V1 PIN ends about April 2027).
  static const String kSimklV2ClientId = 'simkl_v2_client_id';

  Future<void> setSimklV2ClientId(String value) =>
      _storageService.setString(kSimklV2ClientId, value.isEmpty ? null : value);

  String getSimklV2ClientId() =>
      _storageService.getString(kSimklV2ClientId) ?? '';

  /// User-supplied Trakt client id, entered in Accounts. Empty string
  /// means "not set" — callers fall back to the compile-time
  /// `--dart-define=TRAKT_CLIENT_ID` value.
  static const String kTraktClientId = 'trakt_client_id';

  Future<void> setTraktClientId(String value) =>
      _storageService.setString(kTraktClientId, value.isEmpty ? null : value);

  String getTraktClientId() =>
      _storageService.getString(kTraktClientId) ?? '';

  /// User-supplied Trakt client secret, entered in Accounts alongside the
  /// id: Trakt needs it at token exchange. Empty string means "not set" —
  /// callers fall back to the compile-time `--dart-define=TRAKT_CLIENT_SECRET`
  /// value.
  static const String kTraktClientSecret = 'trakt_client_secret';

  Future<void> setTraktClientSecret(String value) => _storageService
      .setString(kTraktClientSecret, value.isEmpty ? null : value);

  String getTraktClientSecret() =>
      _storageService.getString(kTraktClientSecret) ?? '';

  /// User-supplied MyAnimeList client id, entered in Accounts. Empty
  /// string means "not set" — callers fall back to the compile-time
  /// `--dart-define=MAL_CLIENT_ID` value.
  static const String kMalClientId = 'mal_client_id';

  Future<void> setMalClientId(String value) =>
      _storageService.setString(kMalClientId, value.isEmpty ? null : value);

  String getMalClientId() => _storageService.getString(kMalClientId) ?? '';

  /// User-supplied AniList client id, entered in Accounts. Empty string
  /// means "not set" — callers fall back to the compile-time
  /// `--dart-define=ANILIST_CLIENT_ID` value.
  static const String kAnilistClientId = 'anilist_client_id';

  Future<void> setAnilistClientId(String value) => _storageService.setString(
    kAnilistClientId,
    value.isEmpty ? null : value,
  );

  String getAnilistClientId() =>
      _storageService.getString(kAnilistClientId) ?? '';

  /// Home rows customise (v7): one JSON object, source key -> {order, hidden}.
  /// See `home_row_prefs.dart` for the shape. Null/absent = nothing saved.
  static const String kHomeRowPrefs = 'home_row_prefs';

  Future<void> setHomeRowPrefsJson(String? json) =>
      _storageService.setString(kHomeRowPrefs, json);

  String? getHomeRowPrefsJson() => _storageService.getString(kHomeRowPrefs);

  /// App lock (v7): whether Face ID / passcode is asked for on launch and
  /// after a while in the background. Off unless turned on.
  static const String kAppLockEnabled = 'app_lock_enabled';

  Future<void> setAppLockEnabled(bool enabled) =>
      _storageService.setPlayerSetting(kAppLockEnabled, enabled ? true : null);

  bool isAppLockEnabled() =>
      _storageService.getPlayerSetting<bool>(kAppLockEnabled) ?? false;

  Future<void> setTitlePosition(String position) async {
    await _storageService.setTitlePosition(position);
  }

  String getTitlePosition() {
    return _storageService.getTitlePosition();
  }

  /// Nuvio's nav-bar settings (Settings → Navigation bar). Plain
  /// pass-throughs to [StorageService].
  Future<void> setNavBarStyle(String style) async {
    await _storageService.setNavBarStyle(style);
  }

  String getNavBarStyle() {
    return _storageService.getNavBarStyle();
  }

  Future<void> setNavBarGlow(bool enabled) async {
    await _storageService.setNavBarGlow(enabled);
  }

  bool getNavBarGlow() {
    return _storageService.getNavBarGlow();
  }

  Future<void> setNavBarGlass(bool enabled) async {
    await _storageService.setNavBarGlass(enabled);
  }

  bool getNavBarGlass() {
    return _storageService.getNavBarGlass();
  }

  Future<void> setNavBarIconColor(int? argb) async {
    await _storageService.setNavBarIconColor(argb);
  }

  int? getNavBarIconColor() {
    return _storageService.getNavBarIconColor();
  }

  /// Which nav buttons are hidden (Settings → Navigation bar).
  /// Plain pass-through to [StorageService].
  Future<void> setHiddenNavTabs(Set<String> hidden) async {
    await _storageService.setHiddenNavTabs(hidden);
  }

  Set<String> getHiddenNavTabs() {
    return _storageService.getHiddenNavTabs();
  }

  /// Whether Settings is also a nav-bar button (Settings → Navigation
  /// bar). Plain pass-through to [StorageService].
  Future<void> setShowSettingsInNavBar(bool show) async {
    await _storageService.setShowSettingsInNavBar(show);
  }

  bool getShowSettingsInNavBar() {
    return _storageService.getShowSettingsInNavBar();
  }

  Future<void> setDevLoadAssets(bool enabled) async {
    await _storageService.setDevLoadAssets(enabled);
  }

  bool getDevLoadAssets() {
    return _storageService.getDevLoadAssets();
  }

  Future<void> setDevQoeLog(bool enabled) async {
    await _storageService.setDevQoeLog(enabled);
  }

  bool getDevQoeLog() {
    return _storageService.getDevQoeLog();
  }

  Future<void> setActiveProviderId(String? id) =>
      _storageService.setActiveProviderId(id);

  String? getActiveProviderId() {
    return _storageService.getActiveProviderId();
  }

  Future<void> setCustomBaseUrl(String packageName, String? url) =>
      _storageService.setCustomBaseUrl(packageName, url);

  String? getCustomBaseUrl(String packageName) =>
      _storageService.getCustomBaseUrl(packageName);

  Future<void> setLanguage(String lang) async {
    await _storageService.setLanguage(lang);
  }

  /// `null` when the user has never chosen a language - see
  /// [StorageService.getLanguage].
  String? getLanguage() {
    return _storageService.getLanguage();
  }

  Future<void> setExploreLanguage(String lang) async {
    await _storageService.setExploreLanguage(lang);
  }

  String getExploreLanguage() {
    return _storageService.getExploreLanguage();
  }

  Future<void> setWatchHistoryEnabled(bool enabled) async {
    await _storageService.setWatchHistoryEnabled(enabled);
  }

  bool isWatchHistoryEnabled() {
    return _storageService.isWatchHistoryEnabled();
  }

  Future<void> setSearchHistory(List<String> queries) async {
    await _storageService.setSearchHistory(queries);
  }

  List<String> getSearchHistory() {
    return _storageService.getSearchHistory();
  }

  Future<void> setAlwaysOnTop(bool enabled) async {
    await _storageService.setAlwaysOnTop(enabled);
  }

  bool isAlwaysOnTop() {
    return _storageService.isAlwaysOnTop();
  }

  Future<void> setGithubProxyEnabled(bool enabled) async {
    await _storageService.setGithubProxyEnabled(enabled);
  }

  bool isGithubProxyEnabled() {
    return _storageService.isGithubProxyEnabled();
  }

  /// The GitHub proxy choice, by enum name, or null when never chosen (the
  /// legacy toggle then decides — see the storage doc).
  Future<void> setGithubProxyOption(String option) async {
    await _storageService.setGithubProxyOption(option);
  }

  String? getGithubProxyOption() {
    return _storageService.getGithubProxyOption();
  }

  Future<void> setGithubProxyCustomUrl(String url) async {
    await _storageService.setGithubProxyCustomUrl(url);
  }

  String getGithubProxyCustomUrl() {
    return _storageService.getGithubProxyCustomUrl();
  }

  Future<void> setIntroDbIntegrationEnabled(bool enabled) async {
    await _storageService.setIntroDbIntegrationEnabled(enabled);
  }

  bool isIntroDbIntegrationEnabled() {
    return _storageService.isIntroDbIntegrationEnabled();
  }

  Future<void> setAnimeSkipIntegrationEnabled(bool enabled) async {
    await _storageService.setAnimeSkipIntegrationEnabled(enabled);
  }

  bool isAnimeSkipIntegrationEnabled() {
    return _storageService.isAnimeSkipIntegrationEnabled();
  }

  Future<void> setPlayerSetting(String key, dynamic value) async {
    await _storageService.setPlayerSetting(key, value);
  }

  T? getPlayerSetting<T>(String key, {T? defaultValue}) {
    return _storageService.getPlayerSetting<T>(key, defaultValue: defaultValue);
  }

  Future<void> clearPreferences({bool keepRepos = true}) async {
    await _storageService.clearPreferences(keepRepos: keepRepos);
  }

  Future<void> deleteAllData() async {
    await _storageService.deleteAllData();
  }

  Future<int> computeImageVideoCacheBytes() =>
      _storageService.computeImageVideoCacheBytes();

  Future<void> clearImageVideoCache() => _storageService.clearImageVideoCache();
}

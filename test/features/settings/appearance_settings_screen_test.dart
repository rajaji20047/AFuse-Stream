/// Appearance lives on its own screen now (user 2026-11-26): the theme
/// cards, the accent swatches and Dark Mode moved out of the main
/// Settings list, and Settings carries one "Appearance" row that opens
/// this screen. The main Settings header reads "Settings", simply —
/// the old "Personalize Fuse" title and its "Your cinema, your rules"
/// line are gone.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:raja/core/providers/device_info_provider.dart';
import 'package:raja/core/services/notification_service.dart';
import 'package:raja/core/storage/secure_token_storage.dart';
import 'package:raja/core/storage/settings_repository.dart';
import 'package:raja/core/storage/storage_service.dart';
import 'package:raja/core/theme/theme_provider.dart';
import 'package:raja/features/settings/presentation/appearance_settings_screen.dart';
import 'package:raja/features/settings/presentation/app_version_provider.dart';
import 'package:raja/features/settings/presentation/cache_provider.dart';
import 'package:raja/features/settings/presentation/general_settings_provider.dart';
import 'package:raja/features/settings/presentation/player_settings_provider.dart';
import 'package:raja/features/settings/presentation/settings_screen.dart';
import 'package:raja/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:raja/features/tracking/presentation/tracking_auth_provider.dart';
import 'package:raja/l10n/generated/app_localizations.dart';

/// Enough of a repository to render a settings tree, and nothing that touches
/// a box: [StorageService] here is never initialised.
class _QuietSettings extends SettingsRepository {
  _QuietSettings() : super(StorageService());

  @override
  bool isWatchHistoryEnabled() => true;

  @override
  String getDefaultHomeScreen() => '/home';

  @override
  bool isGithubProxyEnabled() => false;

  @override
  bool? getFullScreenMode() => false;

  @override
  Future<void> setFullScreenMode(bool enabled) async {}

  @override
  bool isAnimeSkipIntegrationEnabled() => false;

  @override
  bool isIntroDbIntegrationEnabled() => false;

  @override
  bool getDevLoadAssets() => false;

  @override
  bool getDevQoeLog() => false;

  @override
  Future<void> setDevQoeLog(bool enabled) async {}

  // The theme variant and accent providers read these on build; the base
  // implementations touch the Hive box, which is never initialised here.
  // Nothing chosen yet → the fresh-install defaults.
  @override
  String? getThemeVariant() => null;

  @override
  String? getAccentColor() => null;
}

class _NoTokens extends SecureTokenStorage {
  _NoTokens() : super(StorageService());

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _SignedOutTrackers extends TrackingAuth {
  @override
  Future<Map<String, bool>> build() async => const <String, bool>{
    'simkl': false,
    'trakt': false,
    'mal': false,
    'anilist': false,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('appearance_settings');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          settingsRepositoryProvider.overrideWithValue(_QuietSettings()),
          secureTokenStorageProvider.overrideWithValue(_NoTokens()),
          notificationServiceProvider.overrideWithValue(NotificationService()),
          trackingAuthProvider.overrideWith(_SignedOutTrackers.new),
          appThemeModeProvider.overrideWithValue(ThemeMode.dark),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
          deviceProfileProvider.overrideWith(
            (ref) => const DeviceProfile(isDesktopOS: true),
          ),
          appVersionProvider.overrideWith((ref) async => '1.0.0 +1'),
          cacheSizeProvider.overrideWith((ref) async => 0),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: screen,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('Appearance screen holds the theme, accent and Dark Mode', (
    tester,
  ) async {
    await pump(tester, const AppearanceSettingsScreen());

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('APP THEME'), findsOneWidget);
    expect(find.text('ACCENT COLOR'), findsOneWidget);
    expect(find.text('Dark Mode'), findsOneWidget);
  });

  testWidgets('Settings shows the Appearance row, not the theme sections', (
    tester,
  ) async {
    await pump(tester, const SettingsScreen());

    // The header is simply "Settings" now.
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Personalize Fuse'), findsNothing);

    // One Appearance row, first in the group.
    expect(find.text('Appearance'), findsOneWidget);
    final appearanceTile = tester.widget<SettingsTile>(
      find
          .ancestor(
            of: find.text('Appearance'),
            matching: find.byType(SettingsTile),
          )
          .first,
    );
    expect(appearanceTile.subtitle, 'Theme, accent color & Dark Mode');

    // The moved sections no longer render on the main list.
    expect(find.text('APP THEME'), findsNothing);
    expect(find.text('ACCENT COLOR'), findsNothing);
    expect(find.text('Dark Mode'), findsNothing);
  });
}

/// The Download location row under DOWNLOADS: with no custom directory it
/// names the folder downloads actually land in — on Android the public
/// Downloads folder's Raja subfolder, never the iOS Files label.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/services/notification_service.dart';
import 'package:raja/core/storage/secure_token_storage.dart';
import 'package:raja/core/storage/settings_repository.dart';
import 'package:raja/features/settings/presentation/account_settings_screen.dart';
import 'package:raja/features/settings/presentation/player_settings_provider.dart';
import 'package:raja/features/tracking/presentation/tracking_auth_provider.dart';
import 'package:raja/l10n/generated/app_localizations.dart';

import 'account_settings_tracking_login_test.dart'
    show NoTokens, QuietSettings, RecordingNotifications;

class _Trackers extends TrackingAuth {
  @override
  Future<Map<String, bool>> build() async => <String, bool>{
    'simkl': false,
    'trakt': false,
    'wetrakr': false,
    'mal': false,
    'anilist': false,
  };
}

void main() {
  testWidgets('on Android the default location names the Downloads folder', (
    tester,
  ) async {
    // Tall enough for the lazy list to build the downloads rows.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationServiceProvider.overrideWithValue(
            RecordingNotifications(),
          ),
          secureTokenStorageProvider.overrideWithValue(NoTokens()),
          settingsRepositoryProvider.overrideWithValue(QuietSettings()),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
          trackingAuthProvider.overrideWith(() => _Trackers()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(platform: TargetPlatform.android),
          home: const AccountSettingsScreen(isEmbedded: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Download location'), findsOneWidget);
    expect(find.text('Downloads › Raja'), findsOneWidget);
    expect(find.text('On My iPhone › Raja'), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/services/notification_service.dart';
import 'package:raja/core/storage/secure_token_storage.dart';
import 'package:raja/core/storage/settings_repository.dart';
import 'package:raja/features/settings/presentation/account_settings_screen.dart';
import 'package:raja/features/settings/presentation/player_settings_provider.dart';
import 'package:raja/features/tracking/data/anilist_service.dart';
import 'package:raja/features/tracking/data/mal_service.dart';
import 'package:raja/features/tracking/data/simkl_service.dart';
import 'package:raja/features/tracking/data/trakt_service.dart';
import 'package:raja/features/tracking/presentation/tracking_auth_provider.dart';
import 'package:raja/l10n/generated/app_localizations.dart';

import 'account_settings_tracking_login_test.dart'
    show NoTokens, QuietSettings, RecordingNotifications;

class _Trackers extends TrackingAuth {
  @override
  Future<Map<String, bool>> build() async => const <String, bool>{
    'simkl': false,
    'trakt': false,
    'mal': false,
    'anilist': false,
  };
}

/// The Simkl, Trakt, MyAnimeList and AniList rows under TRACKING & SYNC:
/// always there now — with a client id each offers to connect, without one
/// it offers to set one up, and entering an id turns it into Connect.
/// Mirrors the WeTrakr row test.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    bool? simkl,
    bool? trakt,
    bool? mal,
    bool? anilist,
  }) async {
    // Tall enough for the lazy list to build the tracking rows.
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
          trackingAuthProvider.overrideWith(_Trackers.new),
          if (simkl != null)
            simklConfiguredProvider.overrideWithValue(simkl),
          if (trakt != null)
            traktConfiguredProvider.overrideWithValue(trakt),
          if (mal != null) malConfiguredProvider.overrideWithValue(mal),
          if (anilist != null)
            anilistConfiguredProvider.overrideWithValue(anilist),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AccountSettingsScreen(isEmbedded: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectSetupOffered(ValueKey<String> row) {
    expect(find.byKey(row), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(row), matching: find.text('Set up')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(row),
        matching: find.text('Client ID not set'),
      ),
      findsOneWidget,
    );
  }

  void expectConnectOffered(ValueKey<String> row) {
    expect(find.byKey(row), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(row), matching: find.text('Connect')),
      findsOneWidget,
    );
  }

  Future<void> enterIdAndSave(
    WidgetTester tester,
    String dialogTitle,
    String id,
  ) async {
    expect(find.text(dialogTitle), findsOneWidget);
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, id);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Save'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(dialogTitle), findsNothing);
  }

  testWidgets('without a client id Simkl offers to set one up', (
    tester,
  ) async {
    await pump(tester, simkl: false);
    expectSetupOffered(const ValueKey('account-simkl'));
  });

  testWidgets('without a client id Trakt offers to set one up', (
    tester,
  ) async {
    await pump(tester, trakt: false);
    expectSetupOffered(const ValueKey('account-trakt'));
  });

  testWidgets('without a client id MyAnimeList offers to set one up', (
    tester,
  ) async {
    await pump(tester, mal: false);
    expectSetupOffered(const ValueKey('account-mal'));
  });

  testWidgets('without a client id AniList offers to set one up', (
    tester,
  ) async {
    await pump(tester, anilist: false);
    expectSetupOffered(const ValueKey('account-anilist'));
  });

  testWidgets('with a client id Simkl offers to connect', (tester) async {
    await pump(tester, simkl: true);
    expectConnectOffered(const ValueKey('account-simkl'));
  });

  testWidgets('with a client id Trakt offers to connect', (tester) async {
    await pump(tester, trakt: true);
    expectConnectOffered(const ValueKey('account-trakt'));
  });

  testWidgets('with a client id MyAnimeList offers to connect', (
    tester,
  ) async {
    await pump(tester, mal: true);
    expectConnectOffered(const ValueKey('account-mal'));
  });

  testWidgets('with a client id AniList offers to connect', (tester) async {
    await pump(tester, anilist: true);
    expectConnectOffered(const ValueKey('account-anilist'));
  });

  testWidgets('entering a Simkl id turns the row into Connect', (
    tester,
  ) async {
    // No override: the row follows the stored id, empty at first.
    await pump(tester);
    expectSetupOffered(const ValueKey('account-simkl'));

    await tester.tap(find.byKey(const ValueKey('account-simkl')));
    await tester.pumpAndSettle();
    await enterIdAndSave(tester, 'Simkl client ID', 'simkl-v2-id');

    expectConnectOffered(const ValueKey('account-simkl'));
  });

  testWidgets('entering a Trakt id and secret turns the row into Connect', (
    tester,
  ) async {
    await pump(tester);
    expectSetupOffered(const ValueKey('account-trakt'));

    await tester.tap(find.byKey(const ValueKey('account-trakt')));
    await tester.pumpAndSettle();
    expect(find.text('Trakt client ID'), findsOneWidget);

    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, 'trakt-id');
    await tester.enterText(fields.last, 'trakt-secret');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Save'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Trakt client ID'), findsNothing);
    expectConnectOffered(const ValueKey('account-trakt'));
  });

  testWidgets('entering a MyAnimeList id turns the row into Connect', (
    tester,
  ) async {
    await pump(tester);
    expectSetupOffered(const ValueKey('account-mal'));

    await tester.tap(find.byKey(const ValueKey('account-mal')));
    await tester.pumpAndSettle();
    await enterIdAndSave(tester, 'MyAnimeList client ID', 'mal-id');

    expectConnectOffered(const ValueKey('account-mal'));
  });

  testWidgets('entering an AniList id turns the row into Connect', (
    tester,
  ) async {
    await pump(tester);
    expectSetupOffered(const ValueKey('account-anilist'));

    await tester.tap(find.byKey(const ValueKey('account-anilist')));
    await tester.pumpAndSettle();
    await enterIdAndSave(tester, 'AniList client ID', 'anilist-id');

    expectConnectOffered(const ValueKey('account-anilist'));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/features/player/presentation/widgets/engine_picker_sheet.dart';
import 'package:raja/features/settings/presentation/player_settings_provider.dart';
import 'package:raja/l10n/generated/app_localizations.dart';

void main() {
  Future<void> pumpOpener(
    WidgetTester tester,
    PlayerEngine current,
    void Function(PlayerEngine?) onPicked,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                onPicked(await showEnginePickerSheet(context, current));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the picker lists both engines with the current one marked', (
    tester,
  ) async {
    PlayerEngine? picked;
    await pumpOpener(tester, PlayerEngine.mpv, (p) => picked = p);

    expect(find.text('Player Engine'), findsOneWidget);
    expect(find.text('libmpv Golden'), findsOneWidget);
    expect(find.text('libVLC'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
    expect(
      find.byIcon(Icons.radio_button_unchecked_rounded),
      findsOneWidget,
    );

    await tester.tap(find.text('libVLC'));
    await tester.pumpAndSettle();
    expect(picked, PlayerEngine.vlc);
  });

  testWidgets('picking the engine already playing returns it', (
    tester,
  ) async {
    PlayerEngine? picked;
    await pumpOpener(tester, PlayerEngine.vlc, (p) => picked = p);

    await tester.tap(find.text('libVLC'));
    await tester.pumpAndSettle();
    // The sheet returns the pick as-is; the screen no-ops on a same-engine
    // pick instead of reopening the video for nothing.
    expect(picked, PlayerEngine.vlc);
  });
}

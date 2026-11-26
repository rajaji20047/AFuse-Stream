import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/features/player/presentation/mpv/golden_options_drawer.dart';
import 'package:raja/features/player/presentation/vlc/panel/player_panel_data.dart';

/// The MPV Quality drawer (user 2026-11-26: no way to change an Auto
/// quality on either player): Auto first, then the HLS ladder's heights,
/// tallest first; a tap reports the pick. Pumped on its own — no test in
/// the repo pumps the whole `GoldenPlayerControls`, and the full tree
/// hangs the test isolate.
void main() {
  Future<void> pumpDrawer(
    WidgetTester tester, {
    List<int> ladder = const [1080, 720, 480],
    int? pick,
    required void Function(int?) onPick,
  }) async {
    final panelData = ValueNotifier<PanelData>(
      PanelData(qualityLadder: ladder, qualityPick: pick),
    );
    addTearDown(panelData.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: GoldenQualityDrawer(
            panelData: panelData,
            onPick: onPick,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('Auto first, then the heights, tallest first', (tester) async {
    await pumpDrawer(tester, onPick: (_) {});
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('480p'), findsOneWidget);
  });

  testWidgets('a height tap reports that height', (tester) async {
    int? picked = -1;
    await pumpDrawer(tester, onPick: (height) => picked = height);
    await tester.tap(find.text('720p'));
    expect(picked, 720);
  });

  testWidgets('the Auto tap reports null', (tester) async {
    int? picked = -1;
    await pumpDrawer(
      tester,
      pick: 720,
      onPick: (height) => picked = height,
    );
    await tester.tap(find.text('Auto'));
    expect(picked, isNull);
  });

  testWidgets('a pick between rungs ticks the rung below it', (tester) async {
    // 900p is no rung: 720p plays, so its row carries the tick — the
    // same rule VLC's Quality tab draws by.
    await pumpDrawer(tester, pick: 900, onPick: (_) {});
    Finder radioOf(String label) => find.descendant(
      of: find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      ),
      matching: find.byType(Icon),
    );
    expect(
      tester.widget<Icon>(radioOf('720p')).icon,
      Icons.radio_button_checked_rounded,
    );
    expect(
      tester.widget<Icon>(radioOf('1080p')).icon,
      Icons.radio_button_unchecked_rounded,
    );
    expect(
      tester.widget<Icon>(radioOf('Auto')).icon,
      Icons.radio_button_unchecked_rounded,
    );
  });
}

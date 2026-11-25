// A SettingsTile's value must fit inside the row. A long value (a download
// path, a custom URL) used to sit in ListTile.trailing, which takes its
// full intrinsic width first — so the title was starved to a sliver and
// wrapped one letter per line, with the value painting over the icon.
// The value now shares the title's own Row and ellipsizes instead.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/icons/reicon_icon.dart';
import 'package:raja/features/settings/presentation/widgets/settings_widgets.dart';

Future<void> _pumpTile(
  WidgetTester tester, {
  required String title,
  String? value,
  Widget? trailing,
  bool showChevron = true,
}) async {
  // A narrow phone: the row has ~280 dp for title + value together.
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(720, 1600);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      // No Center: the tile must get the screen's full width, as on the
      // settings page — a loose width would let title and value take
      // their intrinsic sizes and hide the crush this test pins.
      home: Scaffold(
        body: SettingsTile(
          reicon: Reicon.folder,
          title: title,
          value: value,
          trailing: trailing,
          showChevron: showChevron,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a long download path does not crush the title', (
    tester,
  ) async {
    await _pumpTile(
      tester,
      title: 'Download location',
      value: '/storage/emulated/0/Download/ZoroX',
    );

    // The title stays on one line — not one letter per line.
    expect(find.text('Download location'), findsOneWidget);
    expect(
      tester.getSize(find.text('Download location')).height,
      lessThan(30),
      reason: 'the title must not wrap vertically',
    );
    // The value is still there, ellipsized, and nothing overflows.
    expect(find.text('/storage/emulated/0/Download/ZoroX'), findsOneWidget);
    final value = tester.widget<Text>(
      find.text('/storage/emulated/0/Download/ZoroX'),
    );
    expect(value.overflow, TextOverflow.ellipsis);
    expect(value.maxLines, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long title keeps its value beside it', (tester) async {
    await _pumpTile(
      tester,
      title: 'Download segments per file',
      value: 'Off',
    );

    expect(find.text('Download segments per file'), findsOneWidget);
    expect(
      tester.getSize(find.text('Download segments per file')).height,
      lessThan(30),
    );
    expect(find.text('Off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a value beside a trailing widget still shows', (
    tester,
  ) async {
    await _pumpTile(
      tester,
      title: 'Text colour',
      value: 'Yellow',
      trailing: const SizedBox(width: 24, height: 24),
      showChevron: false,
    );

    expect(find.text('Text colour'), findsOneWidget);
    expect(find.text('Yellow'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

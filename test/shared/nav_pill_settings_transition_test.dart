/// Repro: the bottom nav pill vanishes for a few seconds when navigating
/// to/from Settings (user 2026-11-19, build 85/86, recording
/// 6cc621ab...mp4). Frames show the pill missing mid-transition (Settings
/// sliding out over Home) and only back seconds later, even though the
/// branch switch itself is 360 ms.
///
/// 2026-11-28 reversal: the user chose "Pill Settings pe bhi dikhe,
/// Settings button highlight ho", reversing his 2026-11-19 sink request.
/// The Builds 88-90 park is gone: the pill stays visible on Settings and
/// the Settings button wears the selected bubble when it is in the pill.
/// The history below is kept for context; the tests assert the new
/// behaviour.
///
/// Build 88: the pill is hidden on the Settings branch again — the user
/// saw build 87's always-visible pill on Settings and chose "Settings pe
/// chhupa do" — but it NEVER leaves the tree. The gap was the
/// re-insertion: the pill was destroyed on Settings and rebuilt on the
/// return (its glass layer re-rendering), so it only appeared ~2 frames
/// into the slide. Now the pill stays mounted on every branch and is
/// parked off-screen on Settings (hiddenNavPaddingBottom): the
/// visibility flips in the same build as the branch change, so the pill
/// is back on screen in the first frame of the return and gone in the
/// first frame of the way in. The pill keeps highlighting the tab the
/// user came from while on Settings: the package has no "no selection"
/// state, and passing 5 would slide its highlight capsule off the
/// bar's right edge.
///
/// Build 89: the park is ANIMATED. Build 88 flipped the padding in one
/// build, so the pill popped in/out with a jerk ("jhatak se") while the
/// page slid for 360 ms (user 2026-11-19). The padding now tweens over
/// kMotionPage with kMotionPageCurve — the Settings slide's own timing
/// — so the pill glides with the page: still hidden on settled
/// Settings, still back with no seconds-long gap, never a single-frame
/// jump in either direction.
///
/// Build 90: the glide goes DOWN, not up. Build 88/89 parked the pill
/// above the screen top (a screen-tall padding), so it slid up out of
/// view and down on the return; the user asked (2026-11-19, "upar
/// janese accha neeche jaye") for the natural bottom-bar direction.
/// Now the pill parks BELOW the bottom edge (a negative padding, see
/// hiddenNavPaddingBottom): it sinks down out of view as Settings
/// slides in and rises up from below as it slides out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_bottom_nav/liquid_glass_bottom_nav.dart';
import 'package:raja/core/providers/device_info_provider.dart';
import 'package:raja/core/router/app_router.dart';
import 'package:raja/features/settings/presentation/general_settings_provider.dart';
import 'package:raja/l10n/generated/app_localizations.dart';
import 'package:raja/shared/widgets/app_scaffold.dart';
import 'package:raja/shared/widgets/custom_bottom_nav.dart';

void main() {
  Future<GoRouter> pumpShell(
    WidgetTester tester, {
    Widget? homePage,
    GeneralSettings settings = const GeneralSettings(),
  }) async {
    tester.view.physicalSize = const Size(720, 1568);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    Widget page(String label, Color color) => ColoredBox(
      color: color,
      child: Center(child: Text(label)),
    );

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        StatefulShellRoute(
          builder: (context, state, shell) =>
              AppScaffold(navigationShell: shell),
          navigatorContainerBuilder:
              AppShellRouteData.$navigatorContainerBuilder,
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/home',
                  builder: (_, _) => homePage ?? page('home', Colors.red),
                ),
              ],
            ),
            for (final (path, label, color) in const [
              ('/search', 'search', Colors.green),
              ('/extensions', 'extensions', Colors.blue),
              ('/library', 'library', Colors.orange),
              ('/browse', 'browse', Colors.purple),
              ('/settings', 'settings', Colors.teal),
            ])
              StatefulShellBranch(
                routes: [
                  GoRoute(path: path, builder: (_, _) => page(label, color)),
                ],
              ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(
            const AsyncValue.data(DeviceProfile(isTv: false, isTablet: false)),
          ),
          generalSettingsProvider.overrideWithValue(settings),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  bool pillPresent(WidgetTester tester) =>
      find.byType(CustomBottomNavBar).evaluate().isNotEmpty;

  /// The pill's top / bottom edge on screen. On a tab the pill hugs the
  /// bottom edge; since the 2026-11-28 park removal it hugs the bottom
  /// edge on Settings too (before that it was parked below the screen
  /// bottom, build 90 — mounted, but invisible).
  ///
  /// Measured on the package bar itself, not on [CustomBottomNavBar]:
  /// build 102 wraps the bar in a full-screen treatment Stack (gold glow
  /// + metallic rim), so the wrapper's box is the whole screen and says
  /// nothing about where the pill sits.
  double pillTop(WidgetTester tester) =>
      tester.getTopLeft(find.byType(LiquidGlassNavBar)).dy;

  double pillBottom(WidgetTester tester) {
    final topLeft = tester.getTopLeft(find.byType(LiquidGlassNavBar));
    final size = tester.getSize(find.byType(LiquidGlassNavBar));
    return topLeft.dy + size.height;
  }

  testWidgets('pill stays visible on Settings — no glide down, no park '
      '(2026-11-28)', (tester) async {
    final router = await pumpShell(tester);
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(pillPresent(tester), isTrue, reason: 'pill on Home');
    expect(
      pillBottom(tester),
      lessThanOrEqualTo(screenHeight),
      reason: 'pill on screen on Home',
    );
    expect(
      pillTop(tester),
      greaterThan(0),
      reason: 'pill fully on screen on Home',
    );
    final homeBottom = pillBottom(tester);
    final homeTop = pillTop(tester);

    // The Builds 88-90 park sank the pill below the screen on
    // Settings; removed 2026-11-28 on the user's choice ("Pill
    // Settings pe bhi dikhe"): the pill stays put through the
    // navigation, in the same build as the branch change, and the
    // Settings page content clears it.
    router.go('/settings');
    await tester.pumpAndSettle();
    expect(pillPresent(tester), isTrue, reason: 'pill on Settings');
    expect(
      pillBottom(tester),
      closeTo(homeBottom, 1.0),
      reason: 'pill has not moved on Settings',
    );
    expect(
      pillTop(tester),
      closeTo(homeTop, 1.0),
      reason: 'pill has not moved on Settings',
    );
    expect(
      pillBottom(tester),
      lessThanOrEqualTo(screenHeight),
      reason: 'pill still on screen on Settings',
    );
    expect(
      pillTop(tester),
      greaterThan(0),
      reason: 'pill fully on screen on Settings',
    );

    router.go('/home');
    await tester.pumpAndSettle();
    expect(pillPresent(tester), isTrue, reason: 'pill on Home');
    expect(
      pillBottom(tester),
      closeTo(homeBottom, 1.0),
      reason: 'pill has not moved on the return',
    );
  });

  // Nuvio ADAPTIVE: scrolling the page down hides the pill's labels and
  // narrows the pill (Nuvio's 28 → 58 dp); scrolling up restores both.
  // The labels are found through their own Opacity ancestor, so any
  // unrelated Opacity in the shell tree cannot skew the assertion.
  testWidgets('ADAPTIVE: scrolling down collapses the labels, up restores them',
      (tester) async {
    await pumpShell(
      tester,
      homePage: ListView.builder(
        itemCount: 30,
        itemBuilder: (_, i) => SizedBox(height: 80, child: Text('item $i')),
      ),
    );

    double labelOpacity(String label) {
      final opacities = tester.widgetList<Opacity>(
        find.ancestor(of: find.text(label), matching: find.byType(Opacity)),
      );
      expect(opacities, hasLength(1));
      return opacities.single.opacity;
    }

    double pillMargin() {
      final positioned = tester
          .widgetList<Positioned>(find.byType(Positioned))
          .where(
            (p) =>
                p.left != null &&
                p.left! > 0 &&
                p.right != null &&
                p.height == null,
          )
          .toList();
      // The pill itself (left/right 19 or 49) — the rim has a fixed
      // height and the treatment's Positioned.fill has 0 margins.
      expect(positioned, hasLength(1));
      return positioned.single.left!;
    }

    expect(labelOpacity('Home'), 1.0, reason: 'labels shown at rest');
    expect(pillMargin(), 19.0, reason: 'full-width pill at rest');

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(labelOpacity('Home'), 0.0, reason: 'labels hidden after scroll down');
    expect(labelOpacity('Stremio'), 0.0);
    expect(pillMargin(), 49.0, reason: 'pill narrowed by 30 pt');

    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(labelOpacity('Home'), 1.0, reason: 'labels back after scroll up');
    expect(pillMargin(), 19.0, reason: 'pill back to full width');
  });

  testWidgets('pill keeps the last tab highlighted on Settings when the '
      'nav-bar button is off (fallback)', (
    tester,
  ) async {
    final router = await pumpShell(tester);

    router.go('/search');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      1,
      reason: 'Search highlighted on Search',
    );

    router.go('/settings');
    await tester.pumpAndSettle();
    expect(pillPresent(tester), isTrue, reason: 'pill on Settings');
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      1,
      reason:
          'still Search highlighted on Settings with the nav-bar button '
          'off — there is no Settings button to highlight, so the '
          'highlight stays on the last tab',
    );

    router.go('/home');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      0,
      reason: 'Home highlighted again on Home',
    );
  });

  testWidgets('pill highlights the Settings button on Settings when the '
      'nav-bar button is on (2026-11-28)', (tester) async {
    final router = await pumpShell(
      tester,
      settings: const GeneralSettings().copyWith(showSettingsInNavBar: true),
    );

    router.go('/search');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      1,
      reason: 'Search highlighted on Search',
    );

    router.go('/settings');
    await tester.pumpAndSettle();
    expect(pillPresent(tester), isTrue, reason: 'pill on Settings');
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      5,
      reason: 'Settings button highlighted on Settings',
    );

    router.go('/home');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar))
          .currentIndex,
      0,
      reason: 'Home highlighted again on Home',
    );
  });
}

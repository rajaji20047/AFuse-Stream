// Build 118: the profile switcher is a SMALL Liquid Glass dropdown
// anchored top-right just below the header avatar — the 4 rows
// (profiles, Add account, Manage accounts, Settings), no title,
// compact text/icons — not the build-116 centered dialog. Build 118
// shrank the card to ~175pt wide with white foreground text/icons
// (the dark glass washed out the theme's dark text on light themes).
// Build 122 took the Settings row out (gear beside search instead);
// the user reversed that 2026-11-26, so the row is back here and the
// header gear is gone.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:raja/features/profiles/data/fuse_profile.dart';
import 'package:raja/features/profiles/data/fuse_profile_photos_notifier.dart';
import 'package:raja/features/profiles/data/fuse_profiles_notifier.dart';
import 'package:raja/features/profiles/presentation/profile_switcher_screen.dart';

FuseProfile _profile({required String id, required String name}) =>
    FuseProfile(
      id: id,
      name: name,
      color: 'blue',
      pinRecord: 'v1\$100000\$c2FsdA\$aGFzaA',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1795129000000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1795129000000),
    );

class _FixedProfilesNotifier extends FuseProfilesNotifier {
  _FixedProfilesNotifier(this._state);

  final FuseProfilesState _state;

  @override
  FuseProfilesState build() => _state;
}

class _FixedPhotosNotifier extends FuseProfilePhotosNotifier {
  @override
  Map<String, String> build() => const {};
}

void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    List<FuseProfile>? profiles,
  }) async {
    final state = FuseProfilesState(
      profiles:
          profiles ??
          [_profile(id: 'p1', name: 'Suresh'), _profile(id: 'p2', name: 'MM')],
      activeProfileId: 'p1',
      fetched: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fuseProfilesProvider.overrideWith(
            () => _FixedProfilesNotifier(state),
          ),
          fuseProfilePhotosProvider.overrideWith(
            _FixedPhotosNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFuseProfileSwitcher(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('dropdown shows the 4 rows: profiles, Add, Manage, Settings', (
    tester,
  ) async {
    await pumpDialog(tester);

    // No title in the dropdown (build 117): the 4 rows are the content.
    expect(find.text('Switch account'), findsNothing);
    expect(find.text('Suresh'), findsOneWidget);
    expect(find.text('MM'), findsOneWidget);
    // Only the active profile has the gold check.
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-switch-add')), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-switch-manage')), findsOneWidget);
    expect(find.text('Manage accounts'), findsOneWidget);
    // Settings is back in the profile (user 2026-11-26, reversing
    // build 122): the last row, after Manage accounts.
    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-switch-settings')),
      findsOneWidget,
    );

    // Small dropdown, top-right just below the header (not centered,
    // not full-screen): the test viewport is 800x600 with no status
    // bar, so the card sits ~54pt from the top, hugs the right edge,
    // and is narrow and short. Build 118 shrank it further (~185pt
    // wide, ~181pt tall here with 2 profiles + 3 actions) from the
    // build-117 ~300pt card; the Settings row adds one more row, so
    // the same card is ~172pt tall (2 profiles + 3 actions).
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('profile-switch-card')),
    );
    expect(cardRect.top, greaterThan(40));
    expect(cardRect.top, lessThan(90));
    expect(cardRect.right, greaterThan(750));
    expect(cardRect.width, lessThanOrEqualTo(190));
    expect(cardRect.height, lessThan(190));
  });

  testWidgets('tapping the active profile closes the dialog', (
    tester,
  ) async {
    await pumpDialog(tester);

    await tester.tap(find.byKey(const ValueKey('profile-switch-row-p1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-switch-card')), findsNothing);
  });

  testWidgets('no Add account row at the 5-profile cap', (tester) async {
    await pumpDialog(
      tester,
      profiles: [
        _profile(id: 'p1', name: 'One'),
        _profile(id: 'p2', name: 'Two'),
        _profile(id: 'p3', name: 'Three'),
        _profile(id: 'p4', name: 'Four'),
        _profile(id: 'p5', name: 'Five'),
      ],
    );

    expect(find.byKey(const ValueKey('profile-switch-add')), findsNothing);
    // The other rows still show — Settings included (it is back in the
    // profile since 2026-11-26).
    expect(find.text('Manage accounts'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('tapping Settings closes the dialog and opens Settings', (
    tester,
  ) async {
    // A router harness: the Settings row navigates with go_router, and
    // the plain MaterialApp harness above has no router to find.
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showFuseProfileSwitcher(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('Settings page'))),
        ),
      ],
    );
    addTearDown(router.dispose);

    final state = FuseProfilesState(
      profiles: [_profile(id: 'p1', name: 'Suresh')],
      activeProfileId: 'p1',
      fetched: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fuseProfilesProvider.overrideWith(
            () => _FixedProfilesNotifier(state),
          ),
          fuseProfilePhotosProvider.overrideWith(
            _FixedPhotosNotifier.new,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('profile-switch-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-switch-card')), findsNothing);
    expect(find.text('Settings page'), findsOneWidget);
    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      '/settings',
    );
  });
}

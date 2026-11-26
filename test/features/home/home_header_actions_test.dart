// The Home header has two actions, left to right — search, the
// profile avatar. The settings gear lived here from build 122
// (user 2026-11-22: "profile click se setting hatao aur search k
// bagal pr settings icon dalo"); the user reversed that 2026-11-26,
// so Settings is back inside the profile dropdown and the gear is gone.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:raja/features/home/presentation/widgets/home_header_actions.dart';
import 'package:raja/features/profiles/data/fuse_profile.dart';
import 'package:raja/features/profiles/data/fuse_profile_photos_notifier.dart';
import 'package:raja/features/profiles/data/fuse_profiles_notifier.dart';

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
  late FocusNode searchFocusNode;
  late GoRouter router;

  setUp(() {
    searchFocusNode = FocusNode();
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              actions: [
                HomeHeaderActions(searchFocusNode: searchFocusNode),
              ],
            ),
          ),
        ),
      ],
    );
  });

  tearDown(() {
    searchFocusNode.dispose();
    router.dispose();
  });

  Future<void> pumpHeader(WidgetTester tester) async {
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
    await tester.pumpAndSettle();
  }

  testWidgets('no settings gear: search and avatar only', (tester) async {
    await pumpHeader(tester);

    expect(find.byIcon(Icons.search), findsOneWidget);
    // The gear is gone (user 2026-11-26): Settings lives in the
    // profile dropdown now.
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(
      find.byKey(const ValueKey('home-header-settings')),
      findsNothing,
    );

    final searchRect = tester.getRect(
      find.byKey(const ValueKey('home-header-search')),
    );
    final avatarRect = tester.getRect(
      find.byKey(const ValueKey('home-header-avatar')),
    );

    // Same row, same size; order left to right: search, avatar.
    expect(avatarRect.width, searchRect.width);
    expect(avatarRect.height, searchRect.height);
    expect(avatarRect.center.dy, closeTo(searchRect.center.dy, 2));
    expect(avatarRect.center.dx, greaterThan(searchRect.center.dx));
  });
}

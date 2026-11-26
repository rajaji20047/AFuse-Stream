import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Re-tap requests for the bottom nav: tapping the tab the shell is
/// already on.
///
/// Nuvio's `handleRootTabClick`: re-tapping Home/Library/Live TV scrolls
/// that tab to the top, re-tapping Search focuses the search field and
/// scrolls to the top. Fuse has no Downloads tab (its re-tap does nothing
/// in Nuvio); Library's lists live in child tab widgets with no shared
/// controller and Plugins has no scroll controller of its own, so those
/// two are no-ops here too.
///
/// Plain Riverpod ([NotifierProvider]) — no codegen, so no `build_runner`
/// (see `raja_account_notifier.dart`).
///
/// The state maps a tab index (0 Home, 1 Search, 4 Browse) to how many
/// times it was re-tapped. A tab screen `ref.listen`s its own entry and
/// scrolls its controller to the top (Search also focuses its field) when
/// the count changes.
class NavBarRetapNotifier extends Notifier<Map<int, int>> {
  @override
  Map<int, int> build() => const {};

  void request(int tabIndex) {
    state = {...state, tabIndex: (state[tabIndex] ?? 0) + 1};
  }
}

final navBarRetapProvider =
    NotifierProvider<NavBarRetapNotifier, Map<int, int>>(
      NavBarRetapNotifier.new,
    );

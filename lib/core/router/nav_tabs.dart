/// The bottom-nav / sidebar tabs and the branch ↔ visible-position remap.
///
/// Branches are fixed in `AppShellRouteData` (see `app_router.dart`):
/// 0 Home, 1 Search, 2 Plugins, 3 Library, 4 Browse; 5 is Settings, which
/// is never a nav button (it is reached from the Home gear). The pill and
/// the sidebar show only the *visible* tabs — the user hides individual
/// buttons in Settings → Navigation bar — so a visible position is NOT a
/// branch index once anything is hidden: with Library hidden, tapping the
/// 3rd pill button must open Browse (branch 4), not Library (branch 3).
///
/// Everything that converts between the two goes through here, in both
/// directions, so the pill, the sidebar and the shell can never disagree
/// about which button opens which branch. Branches are never removed —
/// only the nav lists are filtered — so deep links (`/library`, …) and the
/// generated router keep working for a hidden tab.
///
/// The hidden set is stored as one comma-joined string under the
/// `hidden_nav_tabs` Hive key (see `StorageService`): a plain string, so
/// it travels in backups like the other nav-bar keys. Unknown routes in
/// a stored value (a route renamed by a newer build, a corrupted box)
/// are dropped on read.
library;

/// Branch routes in branch order: index == branch index (0–4).
const List<String> kNavTabRoutes = <String>[
  '/home',
  '/search',
  '/extensions',
  '/library',
  '/browse',
];

/// Parses a stored `hidden_nav_tabs` value into the hidden tab routes.
/// Null / empty means nothing hidden. Unknown routes are dropped.
Set<String> parseHiddenNavTabs(String? stored) {
  if (stored == null || stored.trim().isEmpty) return const <String>{};
  return stored
      .split(',')
      .map((s) => s.trim())
      .where(kNavTabRoutes.contains)
      .toSet();
}

/// Encodes a hidden set for storage: branch order, comma-joined, or ''
/// when nothing is hidden.
String encodeHiddenNavTabs(Set<String> hidden) {
  return kNavTabRoutes.where(hidden.contains).join(',');
}

/// The branch indices that have a nav button, in display order. Never
/// empty: hiding every tab falls back to Home, so there is always a
/// button to tap and a tab to land on.
List<int> visibleNavBranches(Set<String> hidden) {
  final visible = <int>[];
  for (var i = 0; i < kNavTabRoutes.length; i++) {
    if (!hidden.contains(kNavTabRoutes[i])) visible.add(i);
  }
  return visible.isEmpty ? const <int>[0] : visible;
}

/// The first visible branch — the tab a redirect lands on.
int firstVisibleNavBranch(Set<String> hidden) =>
    visibleNavBranches(hidden).first;

/// The visible position of [branch], or null when the branch is hidden.
int? branchToVisiblePosition(int branch, Set<String> hidden) {
  final visible = visibleNavBranches(hidden);
  final position = visible.indexOf(branch);
  return position < 0 ? null : position;
}

/// The branch at visible position [position] (clamped into range, so a
/// stale position from before a tab was hidden still lands somewhere).
int visiblePositionToBranch(int position, Set<String> hidden) {
  final visible = visibleNavBranches(hidden);
  return visible[position.clamp(0, visible.length - 1)];
}

/// The route the shell should actually start on / go back to: the saved
/// default home, unless that tab is hidden — then the first visible tab.
/// A saved route that is not a tab route ('/settings') passes through
/// unchanged.
String effectiveDefaultHomeRoute(String saved, Set<String> hidden) {
  if (hidden.contains(saved) && kNavTabRoutes.contains(saved)) {
    return kNavTabRoutes[firstVisibleNavBranch(hidden)];
  }
  return saved;
}

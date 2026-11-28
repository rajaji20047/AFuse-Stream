import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:raja/core/providers/device_info_provider.dart';
import 'package:raja/core/router/nav_tabs.dart';
import 'package:raja/core/utils/boot_trace.dart';
import 'package:raja/core/utils/layout_constants.dart';
import 'package:raja/core/utils/motion.dart';
import 'package:raja/core/utils/responsive_breakpoints.dart';
import 'package:raja/shared/widgets/custom_bottom_nav.dart';
import 'package:raja/shared/widgets/app_sidebar.dart';
import 'package:raja/shared/widgets/nav_bar_retap_provider.dart';
import 'package:raja/shared/widgets/nav_bar_scroll_state.dart';

import 'package:raja/l10n/generated/app_localizations.dart';

import '../../features/settings/presentation/general_settings_provider.dart';
import 'loading_indicator.dart';

/// The shell's television cursor layer.
///
/// Named because there is more than one [MouseRegion] in the shell - the
/// sidebar's dock magnification and every InkWell add their own - and a test
/// asking "what is the cursor right now" has to be able to say which one it
/// means.
@visibleForTesting
const Key kTvCursorRegionKey = Key('app-scaffold-tv-cursor');

class AppScaffold extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;
  const AppScaffold({super.key, required this.navigationShell});

  @override
  ConsumerState<AppScaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends ConsumerState<AppScaffold>
    with TickerProviderStateMixin {
  // The last tab branch (0-4) the shell was on. History: builds 88-90
  // parked the pill off-screen on the Settings branch, and the package
  // has no "no selection" state — back when the pill held only five
  // items, passing 5 slid its highlight capsule off the bar's right
  // edge (a gold sliver at the screen edge), so on branch 5 the pill
  // kept highlighting the tab the user came from. Removed 2026-11-28
  // on the user's choice ("Pill Settings pe bhi dikhe, Settings
  // button highlight ho"): the pill now stays visible on Settings and
  // highlights the Settings button itself when it is in the pill; this
  // field is the fallback for Settings opened without its nav-bar
  // button (profile dropdown while the button is off). Updated in
  // build whenever the shell is on a tab branch (covers pill taps,
  // the Settings gear and the back button alike); a plain field, no
  // setState, no rebuild loop.
  int _lastTabIndex = 0;

  /// A hidden-tab redirect is already queued for this frame (see
  /// [build]): without it every build while stranded would queue
  /// another post-frame `goBranch` for the same destination.
  bool _hiddenRedirectPending = false;

  // Owned here so the content-area LEFT key handler can focus them directly,
  // crossing the Branch Navigator's FocusScope boundary. Count comes from
  // [kSidebarDestinationCount] in app_sidebar.dart — single source of truth.
  late final List<FocusNode> _sidebarNodes = List.generate(
    kSidebarDestinationCount,
    (i) => FocusNode(debugLabel: 'sidebar_$i'),
  );

  /// The shell content. The branch-switch animation (tab cross-fade,
  /// Settings slide) lives in the shell's branch container,
  /// `BranchCrossFade` (see `AppShellRouteData.$navigatorContainerBuilder`),
  /// so the shell itself is never moved or remounted here.
  Widget _branchTransition() => widget.navigationShell;

  /// How long a pointer may sit still on a television before the cursor goes.
  ///
  /// Android TV boxes and Fire sticks report a pointer whether or not one is
  /// attached, and trackpad remotes move a real one, so a stationary arrow
  /// parked mid-screen is reachable on shipping hardware. Netflix, Prime Video
  /// and YouTube all take it away after roughly this long; so does Android
  /// TV's own launcher.
  static const Duration kTvCursorIdleTimeout = Duration(seconds: 3);

  /// Runs between the last pointer activity and the cursor going away.
  Timer? _cursorIdleTimer;

  /// Whether [kTvCursorIdleTimeout] has elapsed with the pointer still. Only
  /// ever true while [_cursorAutoHide] is true.
  bool _cursorHidden = false;

  /// Nuvio's ADAPTIVE nav-bar scroll state: the active tab's vertical
  /// scroll collapses the bar's labels (see [_onScrollNotification]).
  /// One state for the whole tab host, like Nuvio's — switching tabs does
  /// not reset it.
  final NavBarScrollState _navBarScrollState = NavBarScrollState();

  /// Whether the cursor clock may run at all this frame. Written by [build],
  /// read by the pointer handlers and by the timer, so a stand-down also stops
  /// a clock that is already ticking. See [_setCursorAutoHide].
  bool _cursorAutoHide = false;

  /// Where the pointer was when the clock was last re-armed.
  ///
  /// Motion is what counts: a hover is re-delivered at an unchanged position
  /// when the widget under a *stationary* pointer changes, and a ten-foot home
  /// screen is carousels animating under it. Without this the clock would be
  /// re-armed forever and the cursor would never go. The player learned the
  /// same lesson - see `_onHover` in vlc_player_controls.dart.
  Offset? _pointerAt;

  @override
  void dispose() {
    _cursorIdleTimer?.cancel();
    _navBarScrollState.dispose();
    for (final n in _sidebarNodes) {
      n.dispose();
    }
    super.dispose();
  }

  /// Every pointer event means the same two things: the focus highlight is no
  /// longer the thing being driven, and the cursor is in use.
  void _onPointerDown(PointerDownEvent event) {
    _pointerIsDriving();
    // A press is activity even when the pointer did not travel to get here, so
    // this one does not go through the motion filter: a click without a nudge
    // has to bring the cursor back.
    _pointerAt = event.position;
    _wakeCursor();
  }

  /// A pointer appearing at all - the box reporting a mouse at launch, or the
  /// viewer brushing a trackpad remote - starts the clock too. Without this an
  /// arrow that arrives and is never touched again would sit there for good,
  /// which is the exact thing this exists to stop.
  void _onPointerEnter(PointerEnterEvent event) {
    _pointerAt = event.position;
    _wakeCursor();
  }

  void _onPointerHover(PointerHoverEvent event) {
    _pointerIsDriving();
    _pointerMoved(event);
  }

  /// A drag: the press that started it already said who is driving, so this
  /// one only feeds the cursor clock. Which also keeps a touch device, where
  /// every scroll is a stream of these, exactly as cheap as it was before.
  void _onPointerMove(PointerMoveEvent event) => _pointerMoved(event);

  void _pointerMoved(PointerEvent event) {
    if (event.position == _pointerAt) return; // see [_pointerAt]
    _pointerAt = event.position;
    _wakeCursor();
  }

  void _pointerIsDriving() {
    ref.read<DpadActiveNotifier>(isDpadActiveProvider.notifier).set(false);
  }

  /// Shows the cursor now and starts the clock that will take it away.
  void _wakeCursor() {
    if (!_cursorAutoHide) return;
    if (_cursorHidden) {
      setState(() => _cursorHidden = false);
    }
    _cursorIdleTimer?.cancel();
    _cursorIdleTimer = Timer(kTvCursorIdleTimeout, _hideCursor);
  }

  void _hideCursor() {
    if (!mounted || !_cursorAutoHide || _cursorHidden) return;
    setState(() => _cursorHidden = true);
  }

  /// Latches whether the cursor clock may run, and puts the cursor back the
  /// instant it may not.
  ///
  /// Two things can forbid it. Off a television there is a real mouse on a
  /// desk and no OS hides that; and while another route sits on top of the
  /// shell the cursor belongs to whatever is up there. The player is the case
  /// that matters: it is a top-level route with a cursor auto-hide of its own
  /// (vlc_player_controls.dart, `MouseCursor.defer` while the bars are up),
  /// and a `defer` from an inner region resolves to whatever an outer one
  /// asks for - so a shell still holding `SystemMouseCursors.none` would hide
  /// the pointer out from under the player's visible chrome. Standing down
  /// here means the two can never disagree.
  void _setCursorAutoHide(bool value) {
    _cursorAutoHide = value;
    if (value) return;
    _cursorIdleTimer?.cancel();
    _cursorIdleTimer = null;
    _cursorHidden = false;
  }

  void _onItemTapped(int index, BuildContext context) {
    final isRetap = index == widget.navigationShell.currentIndex;
    if (isRetap) {
      // Re-tapping the tab already on: Nuvio scrolls that tab to the top
      // (Search also focuses its field). The tab screens listen for their
      // own index on [navBarRetapProvider]; Library and Plugins have no
      // scroll controller of their own, so their re-tap is a no-op (like
      // Nuvio's Downloads tab).
      ref.read(navBarRetapProvider.notifier).request(index);
    }
    widget.navigationShell.goBranch(
      index,
      initialLocation: isRetap,
    );
  }

  /// Nuvio's ADAPTIVE scroll feed: the page's own vertical scroll drives
  /// the bar's labels. Only the outermost vertical scrollable counts
  /// (depth 0) — the horizontal carousels and nested lists must not
  /// collapse the bar — and only while the style is ADAPTIVE.
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        notification.metrics.axis == Axis.vertical &&
        notification.depth == 0) {
      _navBarScrollState.onScrollDelta(notification.scrollDelta ?? 0.0);
    }
    return false; // let the notification keep bubbling.
  }

  int _getRouteIndex(String route) {
    // Raja nav (approved design preview): Home 0 / Search 1 /
    // Plugins 2 / Library 3 / Browse 4; Settings is branch 5.
    // (Explore is no longer a branch, so there is no '/explore' case;
    // '/detail' was replaced by '/browse' in v4.)
    switch (route) {
      case '/home':
        return 0;
      case '/search':
        return 1;
      case '/extensions':
        return 2;
      case '/library':
        return 3;
      case '/browse':
        return 4;
      case '/settings':
        return 5;
      default:
        return 0;
    }
  }

  // Intercepts D-pad LEFT only when the currently focused widget has no
  // focusable neighbour to the left in its own row within the content area. In
  // that case we explicitly focus the sidebar item (different FocusScope, so
  // directional traversal can't bridge it on its own). Otherwise we let the
  // event continue so normal in-row navigation works.
  KeyEventResult _onContentKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return KeyEventResult.ignored;

    final moved =
        _leftStaysInContent(primary) &&
        primary.focusInDirection(TraversalDirection.left);
    if (moved) {
      return KeyEventResult.handled;
    }
    // No focusable to the left in this scope — fall back to sidebar. Bail
    // back to ignored if the target node is out of range or unfocusable so
    // we don't silently swallow the Left key when focus can't move.
    final idx = widget.navigationShell.currentIndex;
    if (idx < 0 || idx >= _sidebarNodes.length) {
      return KeyEventResult.ignored;
    }
    final target = _sidebarNodes[idx];
    if (!target.canRequestFocus) {
      return KeyEventResult.ignored;
    }
    target.requestFocus();
    return KeyEventResult.handled;
  }

  // Whether Left from [node] should stay in the content: something focusable
  // sits to its left in its own row, the band Flutter's directional search
  // tries first. With nothing there the search takes the nearest node in any
  // row - from the middle of Home without a provider, the header's arrows -
  // where Left on a remote means the sidebar. A scope that holds focus itself
  // (a page that has not focused anything yet) is left to the search.
  static bool _leftStaysInContent(FocusNode node) {
    final scope = node.nearestScope;
    if (node is FocusScopeNode || scope == null) return true;
    final rect = node.rect;
    final row = Rect.fromLTRB(
      -double.infinity,
      rect.top,
      double.infinity,
      rect.bottom,
    );
    return scope.traversalDescendants.any(
      (other) =>
          other != node &&
          other.rect != rect &&
          other.rect.center.dx <= rect.left &&
          !other.rect.intersect(row).isEmpty,
    );
  }

  @override
  Widget build(BuildContext context) {
    // v20+20 diagnostic: boot-trace marker (once per launch).
    BootTrace.markOnce('appscaffold-build', 'APPSCAFFOLD build start');
    final deviceProfileAsync = ref.watch(deviceProfileProvider);
    final defaultHome = ref.watch(
      generalSettingsProvider.select((s) => s.defaultHomeScreen),
    );
    // Nuvio's nav-bar settings (Settings → Navigation bar): style,
    // glow, glass and the icon-colour override. Watched whole
    // — a style change restyles the bar without an app restart.
    final navSettings = ref.watch(generalSettingsProvider);
    // Which nav buttons are shown (Settings → Navigation bar), and
    // the branch ↔ visible-position remap for this frame.
    final hiddenNavTabs = navSettings.hiddenNavTabs;
    final visibleBranches = visibleNavBranches(hiddenNavTabs);
    final firstVisibleBranch = visibleBranches.first;
    // Settings as a nav button is opt-in (Settings → Navigation bar,
    // off by default): when on, branch 5 rides at the END of the
    // pill and the rail, after the five tabs. The tab-only lists
    // above stay 0–4 — the redirect, the default-home fallback and
    // the last-tab protection only ever land on a tab, never on
    // Settings (a page, not a tab).
    final navBranches = <int>[
      ...visibleBranches,
      // Branch 5 is Settings (AppShellRouteData.settingsBranchIndex;
      // the literal matches this file's existing 5s — app_router
      // already imports this scaffold, so the constant is not
      // imported here).
      if (navSettings.showSettingsInNavBar) 5,
    ];
    // A default home whose button is hidden falls back to the first
    // visible tab instead of landing on a button-less tab.
    final defaultIndex = _getRouteIndex(
      effectiveDefaultHomeRoute(defaultHome, hiddenNavTabs),
    );
    final isAtDefaultHome = widget.navigationShell.currentIndex == defaultIndex;
    // The active tab was hidden while on it (toggled in Settings):
    // redirect to the first visible tab — otherwise the user is
    // stranded on a tab with no button. Post-frame, once per hide:
    // goBranch rebuilds the shell and the condition clears itself.
    final currentBranch = widget.navigationShell.currentIndex;
    if (currentBranch < 5 &&
        !visibleBranches.contains(currentBranch) &&
        !_hiddenRedirectPending) {
      _hiddenRedirectPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _hiddenRedirectPending = false;
        if (!mounted) return;
        // Re-check at fire time: the user may have moved to a visible
        // tab (or unhidden the tab) in the meantime.
        final branch = widget.navigationShell.currentIndex;
        if (branch < 5 &&
            !visibleNavBranches(
              ref.read(generalSettingsProvider).hiddenNavTabs,
            ).contains(branch)) {
          widget.navigationShell.goBranch(firstVisibleBranch);
        }
      });
    }

    return deviceProfileAsync.when(
      data: (profile) {
        // `isCurrent` is a dependency, so pushing or popping the player route
        // rebuilds this and flips the clock with it.
        _setCursorAutoHide(
          profile.isTv && (ModalRoute.of(context)?.isCurrent ?? true),
        );

        if (profile.isTv || context.isTabletOrLarger) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (isAtDefaultHome) {
                // Nothing is left to go back to. The shell's own route has
                // nowhere to pop to, so an unhandled back press is a button
                // that does nothing — the most common "the app is stuck"
                // report on a television. Leave the app instead.
                SystemNavigator.pop();
              } else {
                widget.navigationShell.goBranch(defaultIndex);
              }
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              onPointerHover: _onPointerHover,
              onPointerMove: _onPointerMove,
              child: MouseRegion(
                key: kTvCursorRegionKey,
                // Not opaque: `deferToChild` adds no hit target of its own, so
                // taking the cursor away cannot take a tap away with it.
                opaque: false,
                onEnter: _onPointerEnter,
                // Present in every frame, cursor value or not. Putting the
                // MouseRegion into the tree only when it has something to say
                // would remount the branch Navigator under it and throw away
                // the scroll position of every screen in the shell.
                cursor: _cursorHidden
                    ? SystemMouseCursors.none
                    : MouseCursor.defer,
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent) {
                      final key = event.logicalKey;
                      if (key == LogicalKeyboardKey.arrowDown ||
                          key == LogicalKeyboardKey.arrowUp ||
                          key == LogicalKeyboardKey.arrowLeft ||
                          key == LogicalKeyboardKey.arrowRight ||
                          key == LogicalKeyboardKey.enter ||
                          key == LogicalKeyboardKey.select ||
                          key == LogicalKeyboardKey.space ||
                          key == LogicalKeyboardKey.tab) {
                        ref
                            .read<DpadActiveNotifier>(
                              isDpadActiveProvider.notifier,
                            )
                            .set(true);
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Material(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: SafeArea(
                      bottom: false,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Content in its own traversal group, positioned first (bottom layer)
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: LayoutConstants.sidebarWidthCompact,
                              ),
                              child: FocusTraversalGroup(
                                policy: WidgetOrderTraversalPolicy(),
                                child: Focus(
                                  canRequestFocus: false,
                                  skipTraversal: true,
                                  onKeyEvent: _onContentKeyEvent,
                                  child: _branchTransition(),
                                ),
                              ),
                            ),
                          ),
                          // Sidebar in its own traversal group, positioned second (top layer)
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: LayoutConstants.sidebarWidthCompact,
                            child: FocusTraversalGroup(
                              policy: WidgetOrderTraversalPolicy(),
                              child: AppSidebar(
                                currentIndex:
                                    widget.navigationShell.currentIndex,
                                onItemTapped: (int index) =>
                                    _onItemTapped(index, context),
                                visibleBranches: navBranches,
                                // One node per VISIBLE branch, in display
                                // order — the rail's own list is indexed
                                // by visible position, while _sidebarNodes
                                // stays indexed by branch.
                                focusNodes: [
                                  for (final branch in navBranches)
                                    _sidebarNodes[branch],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        // Mobile uses Bottom Navigation
        final mq = MediaQuery.of(context);
        // Build 88: the pill is hidden on the Settings branch again
        // (user 2026-11-19: "Settings pe chhupa do") — but it NEVER
        // leaves the tree. Build 87 kept it on screen on all six
        // branches to fix the seconds-long gap on the return; the user
        // did not want it on Settings at all. The gap itself was the
        // re-insertion: the pill was destroyed on Settings and rebuilt
        // on the return (its glass layer re-rendering), so it only
        // appeared ~2 frames into the 360 ms slide (his recording,
        // 6cc621ab...mp4: Home visible with a black strip where the
        // pill belongs, pill back ~0.2 s later). Now the pill stays
        // mounted on every branch. Builds 88-90 parked it off-screen
        // on Settings (see hiddenNavPaddingBottom) and pinned the
        // highlight to the last tab — removed 2026-11-28 on the user's
        // choice ("Pill Settings pe bhi dikhe, Settings button
        // highlight ho"), reversing his 2026-11-19 sink request
        // ("upar janese accha neeche jaye"): the pill stays visible
        // on Settings and the Settings button wears the selected
        // bubble. MediaQuery is an InheritedWidget, so the package's
        // root Positioned still talks directly to this Stack — no
        // Transform/Padding wrapper (the +15..+19 freeze rule).
        final currentIndex = widget.navigationShell.currentIndex;
        final onSettings = currentIndex == 5;
        if (currentIndex < 5 && visibleBranches.contains(currentIndex)) {
          _lastTabIndex = currentIndex;
        }
        // Pill positions are visible positions, not branches: with a
        // tab hidden, position 3 is Browse, not Library.
        //
        // On Settings the pill highlights the Settings button itself:
        // its position in navBranches, which carries branch 5 when
        // the nav-bar button is on. branchToVisiblePosition only
        // knows branches 0-4, so it can never map 5. When Settings
        // was opened without its nav-bar button (profile dropdown
        // while the button is off) there is no Settings button to
        // highlight, so the highlight stays on the last tab.
        final int pillIndex;
        if (onSettings && navBranches.contains(5)) {
          pillIndex = navBranches.indexOf(5);
        } else {
          final pillBranch = currentIndex < 5 ? currentIndex : _lastTabIndex;
          pillIndex =
              branchToVisiblePosition(pillBranch, hiddenNavTabs) ??
              branchToVisiblePosition(_lastTabIndex, hiddenNavTabs) ??
              0;
        }
        // Nuvio's nav-bar settings for this frame.
        final navStyle = navSettings.navBarStyle;
        // Content must clear the pill top (see
        // [CustomBottomNavBar.contentClearance]); the real safe-area
        // padding is already in mq.padding.bottom, so only the remainder
        // is added. The pill stays visible on Settings too (the
        // 2026-11-28 choice reversing the Builds 88-90 park), so the
        // Settings screens take the same clearance as every tab —
        // before the reversal they kept just the real safe area
        // (pre-87 behaviour) because the pill was parked off-screen.
        final navBarTotalHeight = math.max(
          CustomBottomNavBar.contentClearance - mq.padding.bottom,
          0.0,
        );

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (isAtDefaultHome) {
              // Same rule as the television branch: at the default home the
              // back button leaves the app instead of doing nothing.
              SystemNavigator.pop();
            } else {
              widget.navigationShell.goBranch(defaultIndex);
            }
          },
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            // No bottomNavigationBar: the bar is a Positioned overlay in
            // the body Stack (the package requires a Stack ancestor, and
            // it reads the real safe-area padding itself — so the bar sits
            // OUTSIDE the inflated MediaQuery below, while the content
            // sits inside it).
            body: Stack(
              children: [
                MediaQuery(
                  data: mq.copyWith(
                    padding: mq.padding.copyWith(
                      bottom: mq.padding.bottom + navBarTotalHeight,
                    ),
                    viewPadding: mq.viewPadding.copyWith(
                      bottom: mq.viewPadding.bottom + navBarTotalHeight,
                    ),
                  ),
                  // Nuvio ADAPTIVE: the page's vertical scroll feeds the
                  // bar's label state (see [_onScrollNotification]).
                  // A NotificationListener, not a controller per screen:
                  // the scroll notifications bubble up from whatever tab
                  // is on screen, so no tab screen changes for this.
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (navStyle == NavBarStyle.adaptive) {
                        return _onScrollNotification(notification);
                      }
                      return false;
                    },
                    child: _branchTransition(),
                  ),
                ),
                // v20+21: the package positions the pill at
                // MediaQuery.padding.bottom + insets, so on iOS the real
                // safe-area padding (~34) floats it mid-screen. Feeding it
                // a smaller padding (see
                // [CustomBottomNavBar.navPaddingBottom]) drops the pill to
                // the bottom edge — the Android spot. MediaQuery is an
                // InheritedWidget, not a render object, so the package's
                // root Positioned still talks directly to this Stack.
                // NEVER wrap the nav in a Transform/Padding/Align here:
                // a render object between the Stack and the Positioned
                // throws "Incorrect use of ParentDataWidget" on every
                // frame and freezes the app — that was +15..+19.
                //
                // No backing plate behind the pill: the fork has none,
                // and the pill is the fork's translucent frosted glass
                // in both dark and light mode (v4). A solid plate made
                // the pill read as a dark bar — and a fixed near-black
                // slab is wrong in light mode too. The glass itself
                // blurs whatever scrolls under it, and the shell's
                // bottom clearance keeps the last row above the pill,
                // so no row header can read through it.
                //
                // History: builds 88-90 parked the pill off-screen on
                // the Settings branch (hiddenNavPaddingBottom) —
                // mounted, never destroyed, so the return showed it in
                // the first frame. Removed 2026-11-28 on the user's
                // choice ("Pill Settings pe bhi dikhe, Settings button
                // highlight ho"), reversing his 2026-11-19 sink
                // request: the pill now stays visible on Settings and
                // the Settings button wears the selected bubble. What
                // follows is the park's own history, kept for context.
                //
                // Build 89: the park is ANIMATED, not a jump. Build 88
                // flipped the padding in one build, so the pill popped
                // in/out with a jerk while the page itself slid for
                // 360 ms (user 2026-11-19: "jhatak se na dikhe na jaye,
                // kuch animation ho acchasa"). The padding now tweens
                // between the two values over [kMotionPage] with
                // [kMotionPageCurve] — the exact timing of the Settings
                // page slide — so the pill glides with the page, one
                // motion with it. Build 90: the glide goes DOWN, not
                // up — build 88/89 parked the pill above the screen
                // top, so it slid up out of view; the user asked
                // (2026-11-19: "upar janese accha neeche jaye") for
                // the natural bottom-bar direction, so the pill now
                // sinks DOWN below the bottom edge as Settings slides
                // in and rises UP from below as it slides out (see
                // hiddenNavPaddingBottom). That park is gone now (see
                // the history note above): the pill stays put on
                // Settings, and the padding tween below only tracks
                // the normal nav padding.
                // Reduced motion jumps instead (same rule as the
                // branch container). A TweenAnimationBuilder builds no
                // render object of its own — like the MediaQuery it
                // wraps, it is not a RenderObjectWidget — so the
                // package's root Positioned still talks directly to
                // this Stack (the +15..+19 freeze rule: no
                // Transform/Padding/Align wrapper around the pill).
                // The bar itself is passed as `child`, so it is not
                // rebuilt on every animation frame — only the padding
                // value changes.
                // Nuvio's label animation: the scroll state only holds
                // the 0/1 target; this tween glides the fraction over
                // 250 ms so the labels fade and the pill narrows in one
                // motion. A ValueListenableBuilder (not a render object),
                // so the package's root Positioned still talks directly
                // to this Stack (the +15..+19 freeze rule).
                ValueListenableBuilder<double>(
                  valueListenable: _navBarScrollState.targetFraction,
                  builder: (context, scrollTarget, _) {
                    // The target fraction for the style: ADAPTIVE follows
                    // the scroll state, EXPANDED pins the labels on,
                    // COMPACT pins them off.
                    final targetFraction = navStyle == NavBarStyle.expanded
                        ? 1.0
                        : navStyle == NavBarStyle.compact
                            ? 0.0
                            : scrollTarget;
                    return TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: targetFraction),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      builder: (context, labelFraction, _) {
                        return TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            // The pill stays visible on every branch,
                            // Settings included: the Builds 88-90 park
                            // (hiddenNavPaddingBottom on Settings) was
                            // removed on the user's 2026-11-28 choice
                            // ("Pill Settings pe bhi dikhe"), reversing
                            // his 2026-11-19 sink request.
                            end: CustomBottomNavBar.navPaddingBottom(
                              context,
                            ),
                          ),
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : kMotionPage,
                          curve: kMotionPageCurve,
                          // The padding is the pill's anchor: the
                          // package reads padding.bottom for it. (Builds
                          // 88-90 parked it here — sinking the pill
                          // below the screen on Settings; removed
                          // 2026-11-28, the pill stays visible.)
                          builder: (context, navPadding, child) => MediaQuery(
                            data: mq.copyWith(
                              padding: mq.padding.copyWith(bottom: navPadding),
                            ),
                            child: child!,
                          ),
                          child: CustomBottomNavBar(
                            branchIndices: navBranches,
                            currentIndex: pillIndex,
                            onTap: (position) => _onItemTapped(
                              navBranches[position.clamp(
                                0,
                                navBranches.length - 1,
                              )],
                              context,
                            ),
                            labelFraction: labelFraction,
                            glowEnabled: navSettings.navBarGlowEnabled,
                            glassEnabled: navSettings.navBarGlassEnabled,
                            compactSize:
                                navStyle == NavBarStyle.compact,
                            inactiveColorOverride:
                                navSettings.navBarIconColorArgb == null
                                ? null
                                : Color(navSettings.navBarIconColorArgb!),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const Scaffold(body: Center(child: AppLoadingIndicator())),
      error: (err, stack) => Scaffold(
        body: Center(
          child: Text(
            AppLocalizations.of(context)!.errorPrefix(err.toString()),
          ),
        ),
      ),
    );
  }
}

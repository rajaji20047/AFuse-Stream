import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_bottom_nav/liquid_glass_bottom_nav.dart';
import 'package:reicons/reicons.dart';
import 'package:raja/core/utils/boot_trace.dart';
import 'package:raja/l10n/generated/app_localizations.dart';

/// The app's bottom navigation, built on the `liquid_glass_bottom_nav`
/// package (0.0.14): a floating frosted-glass pill with a physics sliding
/// bubble, drag-to-switch and haptics.
///
/// The five tabs use the Reicon icon font as plain [IconData] — Filled
/// (`ReiconFilledIcons.home/.puzzle/.library/.grid`), except Search which
/// is Outline (`ReiconIcons.search`, per M M 2026-11-14) — so the exact
/// same icons render on iOS and Android — the font is bundled in the app,
/// no per-platform work, no asset files.
///
/// Build 110 (user 2026-11-21 01:44, 01:49–01:50): the selected tab is
/// a DARK bubble with the theme ACCENT icon and label — build 104's
/// nav-follows-accent, back on the new nav — and the pill is a rounded
/// rectangle (24 pt corners, slightly round, not a full stadium — build
/// 111, user 2026-11-21 04:03 "thoda round corner pe"). The pill wears
/// a thin NEUTRAL rim, no gold rim, no gold glow. The icons, labels,
/// routes and the liquid-glass material itself are exactly as they
/// were — the rim is a Positioned sibling around the package bar inside
/// [_NavPillRim], never inside the package.
/// Zenith-style bar (user 2026-11-25, from his Zenith recording): the
/// pill is a full STADIUM (34 pt corners, the package default), the side
/// gutter is 19 pt and the foot is 21 dp off the edge (Zenith's
/// sideMargin/bottomLift), and the selected tab wears a primary-tint
/// indicator (14% accent, not the build-109 dark bubble) that travels
/// on a ~1/3 s spring with one soft overshoot. Icons 28 dp, labels
/// 10 sp. What Zenith has that this bar does NOT copy: the mini-player
/// pill above the bar (Fuse has no audio mini-player) and the
/// scroll-collapse to a single inline tab (Fuse pages feed no scroll
/// into the bar) — both would need new wiring, not a restyle.
///
/// Nuvio's nav bar (user 2026-11-26, "Sirf itna implement kro" — the
/// functionality from the Nuvio description): the scroll-collapse IS
/// now wired — the shell feeds the active tab's vertical scroll into
/// [NavBarScrollState] and this bar's [labelFraction] (ADAPTIVE style:
/// labels hide on scroll down, return on scroll up; EXPANDED pins the
/// labels on, COMPACT pins them off), the selection bubble can wear
/// Nuvio's accent glow, the glass can be switched off for a plain
/// surface, and CLASSIC is the flat docked bar (icons only, top
/// divider) instead of the pill. The style/glow/glass/colour settings
/// live in [GeneralSettings] (Settings → Navigation bar) and the shell
/// passes them in here; the defaults keep the Zenith-style look exactly.
/// A Stack is the one wrapper that does not break the +15..+19 rule: the
/// package's root Positioned needs a Stack ancestor, and this Stack is
/// one (a Transform/Padding parent would throw "Incorrect use of
/// ParentDataWidget"). The legacy (non-Impeller) bar is not a floating
/// pill, so it keeps its plain return path.
///
/// The package renders its glass only on Impeller — on by default on iOS,
/// explicitly enabled in AndroidManifest.xml
/// (`io.flutter.embedding.android.EnableImpeller`). Where Impeller is
/// unavailable it falls back to a standard Material bar with the same
/// items. Pass [impellerSupported] false to force that fallback (tests).
///
/// The widget is a [Positioned] overlay: the shell must place it as a
/// direct child of a [Stack] (see [AppScaffold]), not as a Scaffold
/// bottomNavigationBar.
class CustomBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final void Function(int) onTap;

  /// Forces the package's legacy Material fallback when false.
  final bool impellerSupported;

  /// Label visibility, 1 = labels fully shown, 0 = icons only. The
  /// shell animates this (ADAPTIVE: the scroll state; EXPANDED: 1;
  /// COMPACT: 0) so the rim below stays in sync with the pill.
  final double labelFraction;

  /// Accent glow under the selection bubble (Nuvio's nav-bar glow, on
  /// by default there).
  final bool glowEnabled;

  /// The pill's liquid-glass layer. Off is a plain translucent surface
  /// (Nuvio's non-glass fallback).
  final bool glassEnabled;

  /// Flat docked bar instead of the floating pill (Nuvio CLASSIC).
  final bool classic;

  /// Nuvio's compactSize (COMPACT style): 24 pt icons and a pill 8
  /// shorter at every fraction (55 expanded, 39 collapsed). The shell
  /// passes this from the nav-bar style; the pill's labels are already
  /// pinned off by [labelFraction] 0 for this style.
  final bool compactSize;

  /// Unselected-icon colour override (null = default: white 65% on dark
  /// glass, onSurfaceVariant on light). Nuvio's navBarDefaultIconColor.
  final Color? inactiveColorOverride;

  const CustomBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.impellerSupported = true,
    this.labelFraction = 1.0,
    this.glowEnabled = true,
    this.glassEnabled = true,
    this.classic = false,
    this.compactSize = false,
    this.inactiveColorOverride,
  });

  /// The package insets: the side margin AND the bottom offset the
  /// package adds under the pill. Zenith-style (user 2026-11-25):
  /// 19, Zenith's sideMargin (Apple's 19 pt gutter) — build 111's 16
  /// (user 2026-11-21 04:07: "corner k side pe screen dikhe") is
  /// superseded. The bottom gap itself still comes from
  /// [targetBottomGap] via [navPaddingBottom], not from this value:
  /// the shell feeds padding.bottom = gap − insets, so the pill
  /// still lands 21 pt up.
  static const double _kBottomMargin = 19.0;

  /// The pill's EXPANDED height (63) — the clearance math below uses the
  /// tallest the pill gets; the collapsed pill is 47 (see
  /// [LiquidGlassNavBar.pillHeightFor]). The rim uses the live height,
  /// not this constant, so it stays on the pill's edge while it shrinks.
  static const double _kPillHeight = 63.0;

  /// The pill's corner radius. Zenith-style (user 2026-11-25): 34 pt —
  /// the package default, a full stadium at the 63 pt pill height,
  /// the shape Zenith's pill has. Build 111's 24 pt (user 2026-11-21
  /// 04:03: "thoda round corner pe") is superseded. The package paints
  /// the selected bubble with this same radius, so the bubble follows
  /// it — one radius keeps pill and bubble consistent.
  static const double _kPillRadius = 34.0;

  /// How far the pill's bottom edge sits above the physical screen bottom
  /// — Zenith's spot (user 2026-11-25): 21 dp, Zenith's foot off the
  /// edge (bottomLift 6 + the 15 dp gesture inset). Build 109's 20 pt
  /// is superseded. The package positions the pill at
  /// `MediaQuery.padding.bottom + insets`, so the shell feeds it a
  /// bottom padding of [targetBottomGap] − [_kBottomMargin] (see
  /// [navPaddingBottom]).
  static const double targetBottomGap = 21.0;

  /// Breathing room between the pill top and the last content row.
  static const double _kContentBuffer = 12.0;

  /// Total bottom clearance content needs from the physical screen bottom:
  /// pill top (target gap + pill height) + breathing buffer. The shell
  /// reserves this (minus the real safe-area padding, which is already in
  /// the content's MediaQuery) so the last row clears the pill.
  static const double contentClearance =
      targetBottomGap + _kPillHeight + _kContentBuffer;

  /// The clearance the shell reserves for the bar, as a bottom padding:
  /// the floating pill always reserves [contentClearance] — the Classic
  /// bar is a 60 pt docked bar, but the screens'
  /// `shellBottomContentPadding` floors at 100 anyway, so a smaller
  /// number would change nothing on screen.
  static double contentClearanceFor({required bool classic}) =>
      contentClearance;

  /// The `padding.bottom` the package should see so the pill lands at
  /// [targetBottomGap] above the physical screen bottom. The package
  /// positions the pill at `MediaQuery.padding.bottom + insets`, so the
  /// padding must be [targetBottomGap] − [_kBottomMargin] (2): on iOS
  /// (real safe-area padding ~34) that LOWERS it, on Android (real ~0)
  /// it RAISES it — either way the pill lands 21 pt up. Build 109
  /// changed this from lower-only (the old 8 pt gap needed 0, which the
  /// real padding already covered on Android).
  ///
  /// Implemented as a [MediaQuery] override (see [AppScaffold]) — an
  /// [InheritedWidget], not a [RenderObjectWidget] — so the package's root
  /// [Positioned] still talks directly to the shell's [Stack]. A
  /// [Transform] or [Padding] wrapper here would put a render object
  /// between them and throw "Incorrect use of ParentDataWidget" on every
  /// frame — that is exactly what froze the app in +15..+19.
  static double navPaddingBottom(BuildContext context) {
    const needed = targetBottomGap - _kBottomMargin;
    return math.max(0.0, needed);
  }

  /// The `padding.bottom` the shell feeds the package on the Settings
  /// branch so the pill parks entirely below the screen bottom (build
  /// 90). The package positions the pill at
  /// `MediaQuery.padding.bottom + insets` from the bottom edge, so a
  /// NEGATIVE padding sinks the whole 63 px pill below the screen —
  /// invisible and untappable, but still mounted, so its State and
  /// glass layer stay warm and the return to a tab shows it in the
  /// first frame. That is the fix for the pre-87 gap (the pill was
  /// unmounted on Settings and only reappeared ~2 frames into the
  /// 360 ms slide back, his recording 6cc621ab...mp4) without putting
  /// the pill on Settings, which the user rejected in build 87
  /// ("Settings pe chhupa do"). Build 88 parked it ABOVE the screen
  /// top with a screen-tall padding, so it slid up out of view and
  /// down on the return; the user asked (2026-11-19, "upar janese
  /// accha neeche jaye") for the natural bottom-bar direction
  /// instead: sink DOWN below the bottom edge on the way in, rise UP
  /// from below on the way back. The value is exactly
  /// [contentClearance] negated, so the parked pill's top sits
  /// [contentClearance] − insets − pill height = 24 px below the
  /// screen bottom — the same breathing buffer the content keeps
  /// above it. A negative MediaQuery padding is fine: EdgeInsets
  /// carries it, and the package reads padding.bottom only for its
  /// Positioned bottom. An InheritedWidget override like
  /// [navPaddingBottom], so the package's root Positioned still talks
  /// directly to the shell's Stack (the +15..+19 freeze rule).
  static double hiddenNavPaddingBottom(BuildContext context) =>
      -contentClearance;

  @override
  Widget build(BuildContext context) {
    // v20+20 diagnostic: boot-trace marker (once per launch).
    BootTrace.markOnce('custombottomnav-build', 'CUSTOMBOTTOMNAV build start');
    final localizations = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    // Light Liquid Glass: the package paints its light-mode pill with a
    // 76% white fill, a 55% white border and full light intensity — a
    // milky, frosted pill (user 2026-11-19, build 83: "white mode pe
    // blurry hein crystal clear karo"). Its dark-mode pill is the clear
    // one (4% fill). The package picks between them from the theme's
    // brightness alone, so on light Liquid Glass it is handed a dark
    // brightness and draws the same clear glass. Colours of the icons and
    // labels are passed in below and do not come from this theme. Theme
    // is not a layout widget: the bar's Positioned still talks to the
    // Stack directly.
    final clearGlass = clearNavGlassFor(theme);
    final fraction = labelFraction.clamp(0.0, 1.0);
    final bar = LiquidGlassNavBar(
      items: [
        LiquidGlassNavItem(
          id: 'home',
          label: localizations.home,
          icon: ReiconFilledIcons.home,
        ),
        LiquidGlassNavItem(
          id: 'search',
          label: localizations.search,
          // Outline, not Filled — M M asked for the outline search icon
          // (2026-11-14); the other four tabs stay Filled.
          icon: ReiconIcons.search,
        ),
        const LiquidGlassNavItem(
          id: 'plugins',
          // Preview tab name (no l10n key for it): the user approved
          // "Plugins" — the Extensions screen (Fuse Repo + providers).
          label: 'Plugins',
          icon: ReiconFilledIcons.puzzle,
        ),
        LiquidGlassNavItem(
          id: 'library',
          label: localizations.library,
          icon: ReiconFilledIcons.library,
        ),
        const LiquidGlassNavItem(
          id: 'browse',
          // Preview tab name (no l10n key for it): the user asked for a
          // "Browse" tab here in place of the Detail tab (v4) — the world's
          // movies, from TMDB when a key is set, the active provider's home
          // page otherwise.
          label: 'Browse',
          icon: ReiconFilledIcons.grid,
        ),
      ],
      selectedIndex: currentIndex,
      onTap: onTap,
      impellerSupported: impellerSupported,
      // Nuvio's nav-bar settings, from the shell (Settings →
      // Navigation bar). The defaults are the Zenith-style look.
      labelFraction: fraction,
      glowEnabled: glowEnabled,
      glassEnabled: glassEnabled,
      classic: classic,
      compactSize: compactSize,
      // The package insets (Zenith-style: 19 — the side margin, so the
      // screen shows beside the corners).
      insets: _kBottomMargin,
      // A full stadium at the 63 pt pill (Zenith-style: 34 pt — the
      // package default, superseding build 111's 24 pt).
      borderRadius: _kPillRadius,
      // Build 110 (user 2026-11-21 01:44): the selected tab wears the
      // theme ACCENT again — build 104's nav-follows-accent, back on
      // the new nav (green accent → green icon, gold → gold, blue →
      // blue). Zenith-style (user 2026-11-25): the bubble behind it is
      // the same accent at 14% now, not the build-109 dark bubble.
      // `colorScheme.primary` IS the user's accent (app_theme.dart).
      activeColor: colorScheme.primary,
      // Zenith-style (user 2026-11-25): unselected tabs are the content
      // colour at 65% — white on dark glass, onSurfaceVariant on light.
      // Build 110's warm grey (0xFF9D9A92) is superseded. The icon
      // colour override (Settings → Navigation bar) replaces this.
      inactiveColor:
          inactiveColorOverride ??
          (theme.brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.65)
              : colorScheme.onSurfaceVariant),
      // Zenith-style: 28 dp icons, 10 sp labels (Zenith's tabLabelStyle).
      iconSize: 28,
      labelStyle: TextStyle(
        fontSize: 10,
        letterSpacing: 0.5,
        fontWeight: FontWeight.w600,
        // Clear glass over a poster: a soft light halo keeps the dark
        // label readable without tinting the pill.
        shadows: clearGlass
            ? const [Shadow(color: Color(0xCCFFFFFF), blurRadius: 4)]
            : null,
      ),
    );
    if (!clearGlass) {
      return _rimTreatment(bar, fraction, compactSize);
    }
    return _rimTreatment(
      Theme(
        data: theme.copyWith(brightness: Brightness.dark),
        child: bar,
      ),
      fraction,
      compactSize,
    );
  }

  /// The thin neutral rim around the floating pill (build 109): the
  /// reference app has no gold rim and no gold glow, so the old
  /// accent-coloured rim + glow are gone. The legacy (non-Impeller) bar
  /// is not a floating pill, so it keeps its plain return path. Classic
  /// has no pill at all (its own top divider), so it keeps its plain
  /// return path too.
  Widget _rimTreatment(
    Widget bar,
    double labelFraction,
    bool compactSize,
  ) {
    if (!impellerSupported || classic) return bar;
    return _NavPillRim(
      bar: bar,
      labelFraction: labelFraction,
      compactSize: compactSize,
    );
  }
}

/// The thin neutral rim around the floating dock.
///
/// A separate widget (not inline in [CustomBottomNavBar.build]) so its
/// build reads the tweened [MediaQuery] padding itself: the shell feeds
/// the pill a padding that glides from [CustomBottomNavBar
/// .navPaddingBottom] to [CustomBottomNavBar.hiddenNavPaddingBottom]
/// on the Settings branch, and [CustomBottomNavBar] is passed to the
/// tween as a cached `child` — its own build does not re-run per frame.
/// This widget is a MediaQuery dependent, so it rebuilds on every frame
/// of the glide and the rim sinks with the pill instead of lingering
/// where it was.
///
/// Children, in paint order: the package bar itself (icons, labels,
/// glass — untouched), then the rim (above the glass so it reads on
/// light themes too; 1 px at the pill's exact edge, so it never touches
/// the icons or labels inside). IgnorePointer, so taps still land on
/// the bar.
class _NavPillRim extends StatelessWidget {
  const _NavPillRim({
    required this.bar,
    required this.labelFraction,
    required this.compactSize,
  });

  final Widget bar;

  /// The label fraction the pill is drawn at — the rim narrows with the
  /// pill as the labels collapse (same +30 pt as the package).
  final double labelFraction;

  /// Nuvio's compactSize — the rim is 8 shorter with it, like the pill.
  final bool compactSize;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    // The package's side margin: insets, or half that under 360 px —
    // plus the collapse narrowing, so the rim stays on the pill's edge
    // while it shrinks.
    final horizontalMargin =
        (screenWidth < 360
            ? CustomBottomNavBar._kBottomMargin / 2
            : CustomBottomNavBar._kBottomMargin) +
        30.0 * (1.0 - labelFraction.clamp(0.0, 1.0));
    // The shell's park tween drives padding.bottom, so the rim sinks
    // with the pill instead of lingering where it was.
    final edgePadding = MediaQuery.paddingOf(context).bottom;
    return Positioned.fill(
      child: Stack(
        children: [
          // The package bar itself — icons, labels, glass unchanged.
          bar,
          // Thin neutral rim on the pill's exact outline. White at low
          // alpha: the pill is dark glass in every theme now (light
          // themes get the clear dark glass — see [clearNavGlassFor]),
          // so a white rim reads on all of them. The old accent rim
          // (gold on the default accent) is gone — the reference app
          // has no coloured rim.
          Positioned(
            left: horizontalMargin,
            right: horizontalMargin,
            bottom: edgePadding + CustomBottomNavBar._kBottomMargin,
            // The live pill height (63 expanded, 47 collapsed; 55 / 39
            // compact) — a fixed 63 here would outline a taller box than
            // the shrunken pill.
            height: LiquidGlassNavBar.pillHeightFor(
              labelFraction,
              compactSize: compactSize,
            ),
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    CustomBottomNavBar._kPillRadius,
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether the nav pill must be forced onto the package's clear (dark)
/// glass: on every LIGHT theme. Liquid Glass light was the first (build
/// 85); Frost (build 109, user 2026-11-21 00:46: "nav blurry/milky on
/// Frost — pure liquid glass, clear not frosted") is the only other
/// light theme — Arena Gold / Midnight / Obsidian are dark-only — so a
/// plain brightness check covers both without a new theme flag. Dark
/// themes are already clear.
bool clearNavGlassFor(ThemeData theme) => theme.brightness == Brightness.light;

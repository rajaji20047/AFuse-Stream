import 'package:flutter/foundation.dart';

/// Scroll-aware label state for the Nuvio-style ADAPTIVE nav bar.
///
/// Nuvio's `NuvioNavBarScrollState` (NavigationBar.kt): scrolling down past
/// a threshold hides the bar's labels (icons only, the pill narrows) and
/// scrolling up brings them back. The threshold and the snap behaviour are
/// copied verbatim — 60 px of accumulated scroll in one direction.
///
/// Flutter's [ScrollUpdateNotification.scrollDelta] is positive when the
/// user scrolls down (content moves up), so the signs are flipped from
/// Nuvio's Compose `NestedScrollConnection` (where a downward scroll is a
/// negative `available.y`).
///
/// The shell owns one of these (like Nuvio's tab host owns one) and feeds
/// it from a [NotificationListener] over the branch content; the animated
/// fraction itself lives in the shell's [TweenAnimationBuilder], so this
/// class only tracks the 0/1 target.
class NavBarScrollState {
  /// 1 = labels fully visible (expanded), 0 = icons only (collapsed).
  final ValueNotifier<double> targetFraction = ValueNotifier<double>(1.0);

  double _accumulatedDelta = 0.0;

  /// Nuvio's `SCROLL_THRESHOLD`: 60 px of scroll in one direction before
  /// the labels snap.
  static const double scrollThreshold = 60.0;

  /// Feed a vertical scroll delta (positive = scrolling down).
  void onScrollDelta(double delta) {
    if (delta == 0.0) return;

    _accumulatedDelta += delta;

    if (_accumulatedDelta > scrollThreshold && targetFraction.value != 0.0) {
      // Scrolling down past threshold → snap collapse.
      targetFraction.value = 0.0;
      _accumulatedDelta = 0.0;
    } else if (_accumulatedDelta < -scrollThreshold &&
        targetFraction.value != 1.0) {
      // Scrolling up past threshold → snap expand.
      targetFraction.value = 1.0;
      _accumulatedDelta = 0.0;
    }

    // Reset accumulator if direction changed.
    if (delta > 0.0 && _accumulatedDelta < 0.0) _accumulatedDelta = delta;
    if (delta < 0.0 && _accumulatedDelta > 0.0) _accumulatedDelta = delta;
  }

  /// Show the labels — e.g. when the user scrolls back to the top.
  void expand() {
    targetFraction.value = 1.0;
    _accumulatedDelta = 0.0;
  }

  /// Hide the labels.
  void collapse() {
    targetFraction.value = 0.0;
    _accumulatedDelta = 0.0;
  }

  void dispose() {
    targetFraction.dispose();
  }
}

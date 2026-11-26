import 'package:flutter_test/flutter_test.dart';
import 'package:raja/shared/widgets/nav_bar_scroll_state.dart';

/// Nuvio's ADAPTIVE scroll state, ported to Flutter scroll deltas
/// (positive = scrolling down): 60 px of accumulated scroll in one
/// direction snaps the labels, and a direction change resets the
/// accumulator.
void main() {
  test('starts expanded', () {
    final state = NavBarScrollState();
    expect(state.targetFraction.value, 1.0);
    state.dispose();
  });

  test('scrolling down past 60 px collapses', () {
    final state = NavBarScrollState();
    state.onScrollDelta(30.0);
    expect(state.targetFraction.value, 1.0, reason: 'under threshold');
    state.onScrollDelta(31.0);
    expect(state.targetFraction.value, 0.0, reason: '61 px down');
    state.dispose();
  });

  test('scrolling up past 60 px expands again', () {
    final state = NavBarScrollState();
    state.onScrollDelta(100.0);
    expect(state.targetFraction.value, 0.0);
    state.onScrollDelta(-30.0);
    expect(state.targetFraction.value, 0.0, reason: 'under threshold');
    state.onScrollDelta(-31.0);
    expect(state.targetFraction.value, 1.0, reason: '61 px up');
    state.dispose();
  });

  test('a direction change resets the accumulator', () {
    final state = NavBarScrollState();
    state.onScrollDelta(50.0);
    expect(state.targetFraction.value, 1.0);
    // 50 px down, then up: the up-scroll must not add to the down
    // accumulator — 20 px up leaves the bar expanded.
    state.onScrollDelta(-20.0);
    expect(state.targetFraction.value, 1.0);
    // And the down accumulator is gone: 50 px down again is not enough.
    state.onScrollDelta(50.0);
    expect(state.targetFraction.value, 1.0);
    state.onScrollDelta(11.0);
    expect(state.targetFraction.value, 0.0, reason: '61 px down again');
    state.dispose();
  });

  test('zero delta is a no-op', () {
    final state = NavBarScrollState();
    state.onScrollDelta(0.0);
    expect(state.targetFraction.value, 1.0);
    state.dispose();
  });

  test('expand and collapse set the target directly', () {
    final state = NavBarScrollState();
    state.collapse();
    expect(state.targetFraction.value, 0.0);
    state.expand();
    expect(state.targetFraction.value, 1.0);
    state.dispose();
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:raja/features/settings/presentation/general_settings_provider.dart';
import 'package:raja/features/settings/presentation/widgets/settings_dialogs.dart';

/// Nuvio's nav-bar settings: the fresh-install defaults, the copyWith
/// round-trip (including clearing the icon-colour override), and the
/// dialog labels.
void main() {
  test('fresh install: Adaptive, glow and glass on, no override', () {
    const settings = GeneralSettings();
    expect(settings.navBarStyle, NavBarStyle.adaptive);
    expect(settings.navBarGlowEnabled, isTrue);
    expect(settings.navBarGlassEnabled, isTrue);
    expect(settings.navBarIconColorArgb, isNull);
  });

  test('copyWith keeps the other nav settings', () {
    const settings = GeneralSettings();
    final changed = settings.copyWith(navBarStyle: NavBarStyle.classic);
    expect(changed.navBarStyle, NavBarStyle.classic);
    expect(changed.navBarGlowEnabled, isTrue);
    expect(changed.navBarGlassEnabled, isTrue);
    expect(changed.navBarIconColorArgb, isNull);
  });

  test('the icon-colour override round-trips and clears', () {
    const settings = GeneralSettings();
    final overridden = settings.copyWith(navBarIconColorArgb: 0xFFFF0000);
    expect(overridden.navBarIconColorArgb, 0xFFFF0000);
    // Null means "keep" to a nullable field, so clearing needs the flag
    // — the same shape as the download directory's clear flag.
    final kept = overridden.copyWith();
    expect(kept.navBarIconColorArgb, 0xFFFF0000);
    final cleared = overridden.copyWith(clearNavBarIconColor: true);
    expect(cleared.navBarIconColorArgb, isNull);
  });

  test('style labels', () {
    expect(getNavBarStyleLabel(NavBarStyle.adaptive), 'Adaptive');
    expect(getNavBarStyleLabel(NavBarStyle.expanded), 'Expanded');
    expect(getNavBarStyleLabel(NavBarStyle.compact), 'Compact');
    expect(getNavBarStyleLabel(NavBarStyle.classic), 'Classic');
  });

  test('style hints say what each style does', () {
    expect(
      getNavBarStyleHint(NavBarStyle.adaptive),
      contains('hide on scroll'),
    );
    expect(getNavBarStyleHint(NavBarStyle.expanded), contains('always'));
    expect(getNavBarStyleHint(NavBarStyle.compact), 'Icons only');
    expect(getNavBarStyleHint(NavBarStyle.classic), contains('Flat bar'));
  });
}

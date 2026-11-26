import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:raja/l10n/generated/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/accent_color.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../../shared/widgets/olympus_section_header.dart';
import 'widgets/accent_color_picker.dart';
import 'widgets/olympus_theme_cards.dart';
import 'widgets/settings_widgets.dart';

/// Appearance: everything that changes how the app looks — the app
/// theme, the accent color and Dark Mode — moved out of the main
/// Settings list into their own screen (user 2026-11-26: "Personalize
/// or dark mode poora section vhn se uthakr new option Appearance
/// setting option create krke vhn daalo"). Settings carries one
/// "Appearance" row that opens this screen; the theme cards, the
/// accent swatches and the Dark Mode row are unchanged here, only
/// moved.
///
/// The back button mirrors the other settings sub-screens: pop when
/// this screen was pushed, otherwise go to Settings.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final themeVariant = ref.watch(themeVariantProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              const SettingsRoute().go(context);
            }
          },
        ),
        title: Text(l10n.appearance),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.symmetric(
              vertical: LayoutConstants.spacingSm,
            ).copyWith(
              bottom: LayoutConstants.pillFreeBottomContentPadding(context),
            ),
            children: [
              const OlympusSectionHeader(title: 'APP THEME'),
              OlympusThemeCards(
                current: themeVariant,
                // Build 104: a card tap applies the theme AND its
                // signature accent together, so the tap visibly
                // changes the app (before this the three dark
                // variants differed only in surface shades and a
                // tap looked like nothing happened). A "More
                // themes" chip passes a null accent and leaves
                // the accent alone; the accent row below still
                // overrides it on its own.
                onChanged: (variant, accent) async {
                  await ref
                      .read(themeVariantProvider.notifier)
                      .setVariant(variant);
                  if (accent != null) {
                    await ref
                        .read(accentColorProvider.notifier)
                        .setAccent(accent);
                  }
                },
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              const AccentColorPicker(),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                children: [
                  // Dark Mode: the on/off switch. On Liquid Glass it only changes
                  // the mode (the theme has a dark and a light look). Arena Gold /
                  // Midnight / Obsidian are dark only and Frost is light only, so
                  // there the switch moves to Frost or back to the last dark
                  // variant (see ThemeVariant).
                  SettingsTile(
                    reicon: Reicon.moon,
                    title: 'Dark Mode',
                    subtitle: 'Dark backgrounds, light text',
                    isLast: true,
                    trailing: Switch(
                      value:
                          ref.watch(appThemeModeProvider) == ThemeMode.dark,
                      onChanged: (val) => ref
                          .read(themeVariantProvider.notifier)
                          .setDarkMode(val),
                    ),
                    onTap: () async {
                      final isDark =
                          ref.read(appThemeModeProvider) == ThemeMode.dark;
                      await ref
                          .read(themeVariantProvider.notifier)
                          .setDarkMode(!isDark);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

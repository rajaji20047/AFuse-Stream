import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/theme/olympus.dart';

import 'widgets/settings_widgets.dart';
import 'widgets/general_extra_tiles.dart';
import 'widgets/settings_dialogs.dart';
import 'full_screen_mode_provider.dart';
import 'general_settings_provider.dart';
import 'app_version_provider.dart';
import 'developer_options_provider.dart';

import 'package:raja/l10n/generated/app_localizations.dart';

import '../../../core/providers/locale_provider.dart';
import '../../../core/router/app_router.dart';
import 'cache_provider.dart';

class SettingsScreen extends ConsumerWidget {
  final String? initialCategory;
  const SettingsScreen({super.key, this.initialCategory});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    final versionAsync = ref.watch(appVersionProvider);
    final generalSettings = ref.watch(generalSettingsProvider);

    // Olympus Noir (build 102): no AppBar — the page carries its own
    // "Settings" header at the top of the list, and the bottom
    // pill is hidden on this branch, so the header's back button is the
    // way back to Home (the branch has nothing to pop, so it goes to
    // Home explicitly).
    return Scaffold(
      body: SafeArea(
        top: true,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: ListView(
                // Vertical only. SettingsGroup already insets its title and its
                // card by spacingMd, so a horizontal inset here would be paid
                // for twice and the cards would sit further in than on the
                // Accounts screen, which never added one.
                padding:
                    const EdgeInsets.symmetric(
                      vertical: LayoutConstants.spacingSm,
                    ).copyWith(
                      bottom: LayoutConstants.pillFreeBottomContentPadding(
                        context,
                      ),
                    ),
                children: [
                  _buildOlympusHeader(context),
                  // The look of the app lives on its own screen now:
                  // the theme cards, the accent swatches and Dark Mode
                  // moved to Appearance (user 2026-11-26), reached
                  // from the Appearance row in the group below.
                  _buildGeneralSettingsGroup(
                    context,
                    ref,
                    l10n,
                    generalSettings,
                  ),
                  // b121: the Extensions section is back in Settings at the
                  // owner's request (2026-11-22 ~04:01, going to sleep):
                  // four SEPARATE sub-sections, one per source — SkyStream,
                  // CloudStream, Nuvio, Stremio — each with its own plugin
                  // management (add/remove/refresh repos, install/uninstall).
                  // The 1.0.1 removal ("hum toh plugin section se sab manage
                  // karsakte") no longer holds: the Home plugin section is
                  // troublesome ("bohot dikkat horha"), so Settings carries
                  // the one place per source. The four sections live inside
                  // the Extensions screen, not as top-level Settings rows.
                  const SizedBox(height: LayoutConstants.spacingLg),
                  SettingsGroup(
                    title: 'Extensions',
                    children: [
                      SettingsTile(
                        reicon: Reicon.plug,
                        title: 'Extensions',
                        subtitle: 'SkyStream, CloudStream, Nuvio & Stremio',
                        isLast: true,
                        onTap: () =>
                            const SettingsExtensionsRoute().go(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: LayoutConstants.spacingLg),
                  _buildAppDataSettingsGroup(context, ref, l10n),
                  const SizedBox(height: LayoutConstants.spacingLg),
                  _buildAboutSettingsGroup(context, ref, l10n, versionAsync),
                  const SizedBox(height: LayoutConstants.spacingLg),
                  _buildFuseFooter(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The Olympus Noir page header: back to Home and "Settings".
  /// Simple (user 2026-11-26): the old "Personalize Fuse" title and
  /// its "Your cinema, your rules" line are gone, and the gold bolt
  /// moved to the Appearance screen (user 2026-11-26) — it was
  /// decoration only there too, no tap.
  Widget _buildOlympusHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => goDefaultHome(context),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Settings',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The FUSE footer: gold hairlines either side of the gold bolt and
  /// the letterspaced wordmark.
  Widget _buildFuseFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: kOlympusGold.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(width: 12),
          Image.asset(
            'assets/images/ic_launcher_foreground.png',
            width: 20,
            height: 20,
          ),
          const SizedBox(width: 6),
          const Text(
            'FUSE',
            style: TextStyle(
              color: kOlympusGold,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 3.0,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              color: kOlympusGold.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneralSettingsGroup(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    GeneralSettings generalSettings,
  ) {
    final fullScreenModeEnabled = ref.watch(fullScreenModeProvider);
    // Olympus Noir (build 102): no "General" header. The theme cards,
    // the accent swatches and Dark Mode used to sit above this group;
    // they live on the Appearance screen now (user 2026-11-26), reached
    // from the Appearance row first in the group.
    return SettingsGroup(
      children: [
        // Appearance: the app theme, the accent color and Dark Mode,
        // on their own screen.
        SettingsTile(
          reicon: Reicon.palette,
          title: l10n.appearance,
          subtitle: 'Theme, accent color & Dark Mode',
          onTap: () => const AppearanceSettingsRoute().go(context),
        ),
        SettingsTile(
          reicon: Reicon.globe,
          title: l10n.language,
          subtitle: 'App & metadata language',
          value: l10n.languageName,
          onTap: () =>
              showLanguageDialog(context, ref, ref.read(localeProvider)),
        ),
        SettingsTile(
          reicon: Reicon.home2,
          title: l10n.defaultHomeScreen,
          subtitle: 'Tab shown on launch',
          value: getHomeScreenLabel(generalSettings.defaultHomeScreen, l10n),
          onTap: () => showDefaultHomeScreenDialog(
            context,
            ref,
            generalSettings.defaultHomeScreen,
          ),
        ),
        const HomeRowsSettingsTile(),
        const AppLockSettingsTile(),
        SettingsTile(
          reicon: Reicon.history,
          title: l10n.recordWatchHistory,
          subtitle: 'Keep Continue Watching & progress',
          trailing: Switch(
            value: generalSettings.watchHistoryEnabled,
            onChanged: (val) => ref
                .read(generalSettingsProvider.notifier)
                .setWatchHistoryEnabled(val),
          ),
          onTap: () => ref
              .read(generalSettingsProvider.notifier)
              .setWatchHistoryEnabled(!generalSettings.watchHistoryEnabled),
        ),
        SettingsTile(
          reicon: Reicon.text,
          title: l10n.titlePosition,
          subtitle: 'Where titles sit on posters',
          value: getTitlePositionLabel(generalSettings.titlePosition, l10n),
          onTap: () => showTitlePositionDialog(
            context,
            ref,
            generalSettings.titlePosition,
          ),
        ),
        // Nuvio's nav-bar settings: style (Adaptive/Expanded/Compact),
        // glow, glass and the icon colour override — one
        // dialog, Nuvio's NavigationBarSettingsSheet.
        SettingsTile(
          reicon: Reicon.layout,
          title: 'Navigation bar',
          subtitle: 'Style, glow & glass',
          value: getNavBarStyleLabel(generalSettings.navBarStyle),
          onTap: () => showNavBarSettingsDialog(context, ref),
        ),
        // Only shown where it means something. A phone, a tablet and a
        // television are already the size they are going to be; only a
        // desktop has a window that can change.
        if (_supportsFullScreenMode(context))
          SettingsTile(
            icon: Icons.tv_rounded,
            title: l10n.fullScreenMode,
            subtitle: l10n.fullScreenModeSubtitle,
            trailing: Switch(
              value: fullScreenModeEnabled,
              onChanged: (val) =>
                  ref.read(fullScreenModeProvider.notifier).setEnabled(val),
            ),
            onTap: () => ref
                .read(fullScreenModeProvider.notifier)
                .setEnabled(!fullScreenModeEnabled),
          ),
        SettingsTile(
          reicon: Reicon.playCircle,
          title: l10n.player,
          subtitle: 'Engine, gestures, subtitles, quality',
          onTap: () => const PlayerSettingsRoute().go(context),
        ),
        SettingsTile(
          reicon: Reicon.userCircle,
          title: '${l10n.accounts}, ${l10n.network} & ${l10n.downloads}',
          subtitle: 'Trakt, Simkl, subtitle accounts, DNS, downloads',
          isLast: true,
          onTap: () => const AccountSettingsRoute().go(context),
        ),
      ],
    );
  }

  Widget _buildAppDataSettingsGroup(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final developerOptionsEnabled = ref.watch(developerOptionsProvider);
    return SettingsGroup(
      title: '${l10n.appData} & ${l10n.developer}',
      children: [
        if (!kIsWeb)
          SettingsTile(
            reicon: Reicon.broom,
            title: l10n.clearCache,
            subtitle: ref
                .watch(cacheSizeProvider)
                .when(
                  data: (bytes) =>
                      'Posters & temporary files • ${_formatBytes(bytes)}',
                  loading: () => l10n.calculating,
                  error: (_, _) => l10n.clearCacheSubtitle,
                ),
            onTap: () => showClearCacheDialog(context, ref),
          ),
        SettingsTile(
          reicon: Reicon.rotateLeft,
          title: l10n.resetDataKeepExtensions,
          subtitle: 'Reset settings & library, keep extensions',
          onTap: () => showResetDataDialog(context, ref),
        ),
        SettingsTile(
          reicon: Reicon.triangleWarning,
          title: l10n.factoryReset,
          subtitle: 'Erase everything and start fresh',
          danger: true,
          onTap: () => showFactoryResetDialog(context, ref),
        ),
        // The preview shows Developer Options as a gold toggle (OFF by
        // default) — it turns the QoE stats overlay and debug logging on.
        // The Developer Options screen still holds the rest of the tools
        // (Turnstile test, logs): tapping the row opens it, while the
        // trailing Switch alone flips the flag — the Switch absorbs its
        // own taps, so the row's onTap only fires outside it. (b124
        // shipped the screen with no way to reach it: the row only
        // toggled, and nothing navigated to DeveloperOptionsRoute.)
        SettingsTile(
          reicon: Reicon.terminalSquare,
          title: l10n.developerOptions,
          subtitle: 'Logs, QoE stats overlay, debug info',
          isLast: true,
          trailing: Switch(
            value: developerOptionsEnabled,
            onChanged: (val) =>
                ref.read(developerOptionsProvider.notifier).setEnabled(val),
          ),
          onTap: () => const DeveloperOptionsRoute().go(context),
        ),
      ],
    );
  }

  Widget _buildAboutSettingsGroup(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    AsyncValue<String> versionAsync,
  ) {
    return SettingsGroup(
      title: l10n.about,
      children: [
        SettingsTile(
          reicon: Reicon.code,
          title: l10n.developer,
          subtitle: 'Raja',
          trailing: const SizedBox.shrink(),
          onTap: () => showDeveloperDialog(context),
        ),
        // v9 (public 1.0.0): the credit GPL v3 asks for, at the user's
        // request — the one place the app names the project it is based
        // on. Opens the project page in the browser.
        SettingsTile(
          key: const ValueKey('about-based-on'),
          reicon: Reicon.branchUp,
          title: 'Based on SkyStream',
          subtitle: 'Open source · GPL v3',
          onTap: () => unawaited(openBasedOnProject()),
        ),
        // 1.0.1 (build 67): at the user's request the Telegram row opens
        // SkyStream's community chat. It is SkyStream's chat, not a Fuse
        // channel, and the subtitle says so. (Discord was removed from
        // About at the user's request, 2026-11-17.)
        SettingsTile(
          key: const ValueKey('about-telegram'),
          reicon: Reicon.send,
          title: 'Telegram',
          subtitle: 'SkyStream community chat',
          onTap: () => unawaited(openTelegramChat()),
        ),
        // v5: the "Open-source licences" row was removed from About at the
        // user's request (2026-11-17). The LICENSE file and the licence
        // texts registered with Flutter stay in the app bundle.
        SettingsTile(
          reicon: Reicon.infoCircle,
          title: l10n.version,
          subtitle: 'Fuse for Android',
          value: versionAsync.when(
            // The version alone ("1.0.0"), never the build suffix.
            data: aboutVersionLabel,
            loading: () => l10n.loading,
            error: (err, stack) => l10n.unknown,
          ),
          showChevron: false,
          isLast: true,
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  final value = unitIndex == 0
      ? size.toStringAsFixed(0)
      : size.toStringAsFixed(1);
  return '$value ${units[unitIndex]}';
}

/// Whether the full screen / windowed choice is offered at all.
///
/// It needs a window to make full screen and a form factor worth overriding,
/// which is the three desktops and nowhere else. A phone, a tablet and an
/// Android TV never see the row, so its subtitle never has to hedge about
/// devices that have no window to speak of. Read through [ThemeData.platform]
/// rather than dart:io so a test can state which device it is pretending to
/// be.
bool _supportsFullScreenMode(BuildContext context) {
  if (kIsWeb) return false;
  return switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };
}

/// The project Fuse is based on; the About credit row opens it.
const String kBasedOnProjectUrl = 'https://github.com/akashdh11/skystream';

/// Opens [kBasedOnProjectUrl] in the browser. Best effort.
Future<void> openBasedOnProject() async {
  try {
    await launchUrl(
      Uri.parse(kBasedOnProjectUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // No browser to open it in: nothing to do.
  }
}

/// What About shows for the version: the version alone — "1.0.0 +65"
/// reads as "1.0.0".
String aboutVersionLabel(String version) => version.split(' +').first.trim();

/// SkyStream's community chat on Telegram; the About Telegram row opens it.
const String kTelegramChatUrl = 'https://t.me/skystream7chat';

/// Opens [kTelegramChatUrl] in Telegram or the browser. Best effort.
Future<void> openTelegramChat() async {
  try {
    await launchUrl(
      Uri.parse(kTelegramChatUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // Nothing to open it in: nothing to do.
  }
}

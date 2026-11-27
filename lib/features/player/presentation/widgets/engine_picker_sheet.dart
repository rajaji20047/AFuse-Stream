/// Picking which engine plays this video.
///
/// The top-row switch button opens this sheet instead of jumping straight
/// to the other engine (user 2026-11-26): the viewer picks libmpv Golden or
/// libVLC, the engine already playing marked, and the screen switches only
/// when the pick differs from what is already playing — tapping the current
/// engine just closes the sheet.
///
/// The sheet follows the torrent file sheet's shape: a dark modal bottom
/// sheet with dense rows, so it reads as a picker rather than a new screen.
library;

import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../settings/presentation/player_settings_provider.dart';

/// Opens the engine picker and returns the picked engine, or null when the
/// sheet is dismissed without a pick.
Future<PlayerEngine?> showEnginePickerSheet(
  BuildContext context,
  PlayerEngine current,
) {
  return showModalBottomSheet<PlayerEngine>(
    context: context,
    backgroundColor: const Color(0xFF141414),
    isScrollControlled: true,
    builder: (sheetContext) {
      final l10n = AppLocalizations.of(sheetContext)!;
      // The engine names, in the settings' own words — the picker mirrors
      // the Player settings row, so the two never drift apart.
      String engineName(PlayerEngine engine) => switch (engine) {
        PlayerEngine.mpv => l10n.playerEngineMpv,
        PlayerEngine.vlc => l10n.playerEngineVlc,
        PlayerEngine.exo => l10n.playerEngineExo,
      };
      String engineDetail(PlayerEngine engine) => switch (engine) {
        PlayerEngine.mpv => l10n.playerEngineMpvDetail,
        PlayerEngine.vlc => l10n.playerEngineVlcDetail,
        PlayerEngine.exo => l10n.playerEngineExoDetail,
      };
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                l10n.playerEngine,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // The enum order is the Settings order: the default engine
            // (libmpv) first.
            for (final engine in PlayerEngine.values)
              ListTile(
                dense: true,
                selected: engine == current,
                selectedColor: Colors.white,
                leading: Icon(
                  engine == current
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: Colors.white70,
                ),
                title: Text(
                  engineName(engine),
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  engineDetail(engine),
                  style: const TextStyle(color: Colors.white70),
                ),
                onTap: () => Navigator.of(sheetContext).pop(engine),
              ),
          ],
        ),
      );
    },
  );
}

/// The qualities an HLS stream offers, as the player's Quality tab lists
/// them, and which of them plays.
///
/// Pure, so the arithmetic is tested without an engine: the screen reads the
/// playlist, and the panel draws the rows.
library;

import '../../../core/network/link_probe_service.dart' show HlsVariant;

/// The heights [variants] offer, tallest first, each once: of several
/// variants at one height libVLC plays the highest bitrate, so one row says
/// it. A variant with no RESOLUTION still offers a choice: its bandwidth
/// stands in for its height ([estimatedHeightForBandwidth]), so a master
/// without RESOLUTION lists its renditions by estimate instead of hiding
/// the tab. Only a variant with neither a height nor a usable bandwidth
/// offers nothing.
List<int> qualityLadderOf(Iterable<HlsVariant> variants) {
  final heights = <int>{
    for (final variant in variants)
      if (variant.height case final height? when height > 0)
        height
      else if (estimatedHeightForBandwidth(variant.bandwidth)
          case final estimated?)
        estimated,
  }.toList();
  heights.sort((a, b) => b.compareTo(a));
  return heights;
}

/// The height a rendition without a RESOLUTION most likely is, from its
/// bandwidth in bits per second.
///
/// An estimate, not a measurement: the boundaries sit between the bitrates
/// renditions are usually encoded at (1080p near 5 Mbps, 720p near 2.5,
/// 480p near 1.2, 360p near 0.7, 240p near 0.4), so a rendition lands on the
/// rung its bitrate belongs to and the rows still order tallest first. A
/// row may name the wrong height when a rendition is encoded far from its
/// rung's usual bitrate - a lean 1080p reads as 720p - but the cap it asks
/// for still orders the renditions, and a choice by estimate beats no
/// choice at all. Null below 100 kbps: that is noise, not a rendition.
int? estimatedHeightForBandwidth(int? bandwidth) {
  if (bandwidth == null || bandwidth < 100000) return null;
  if (bandwidth >= 3500000) return 1080;
  if (bandwidth >= 1700000) return 720;
  if (bandwidth >= 900000) return 480;
  if (bandwidth >= 550000) return 360;
  return 240;
}

/// The height of [ladder] (tallest first) that plays under a cap of [cap]:
/// the tallest at or below it, or the lowest when every height is taller -
/// what libVLC and VLCKit do, measured. Null for an empty ladder.
int? heightUnderCap(int cap, List<int> ladder) {
  if (ladder.isEmpty) return null;
  for (final height in ladder) {
    if (height <= cap) return height;
  }
  return ladder.last;
}

/// The height of [ladder] nearest [videoHeight], the picture's height as the
/// engine reports it: a 1088-line decode is the 1080p rendition. Null when
/// either is unknown.
int? nearestLadderHeight(double? videoHeight, List<int> ladder) {
  if (videoHeight == null || videoHeight <= 0 || ladder.isEmpty) return null;
  var nearest = ladder.first;
  for (final height in ladder) {
    if ((height - videoHeight).abs() < (nearest - videoHeight).abs()) {
      nearest = height;
    }
  }
  return nearest;
}

/// The mpv `hls-bitrate` cap for a Quality pick, in bits per second.
///
/// The pick is a height cap, like VLC's: the rendition that plays is the
/// tallest at or below it ([heightUnderCap]), and the cap is that
/// rendition's bandwidth — of several variants at the height, the highest
/// bitrate, the one the player would take. A variant with no RESOLUTION
/// counts at its estimated height ([estimatedHeightForBandwidth]), so a
/// row the ladder offers by estimate caps on the bandwidth that offered
/// it. Auto is 0: mpv reads 0 as no limit (its default), so going back to
/// Auto lifts a pick's cap. Null when there is no ladder to pick from, or
/// no variant at the playing height carries a bandwidth: the caller then
/// leaves the property alone rather than capping on a guess.
int? bitrateCapForPick(
  int? pick,
  List<int> ladder,
  List<HlsVariant> variants,
) {
  if (pick == null) return 0;
  final playing = heightUnderCap(pick, ladder);
  if (playing == null) return null;
  int? cap;
  for (final variant in variants) {
    final bandwidth = variant.bandwidth;
    final height = variant.height ?? estimatedHeightForBandwidth(bandwidth);
    if (height == playing && bandwidth != null) {
      cap = cap == null || bandwidth > cap ? bandwidth : cap;
    }
  }
  return cap;
}

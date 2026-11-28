import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:collection/collection.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../../core/storage/library_repository.dart';
import '../../../../core/storage/history_repository.dart';

import 'package:raja/core/storage/episode_watch_repository.dart';
import 'package:raja/core/storage/storage_service.dart';

import '../../library/presentation/library_provider.dart';
import '../../library/presentation/history_provider.dart';
import '../../addons/presentation/addon_sources_sheet.dart';
import '../../../core/addons/data/addon_client.dart';
import '../../../core/addons/data/addon_stream_service.dart';
import '../../../core/addons/data/builtin_addons.dart';
import '../../../core/addons/models/addon_meta.dart';
import 'playback_launcher.dart';
import '../../../core/services/download_service.dart';
import '../data/metadata_resolution_service.dart';
import 'downloaded_file_provider.dart';
import '../../tracking/data/simkl_service.dart';
import '../../tracking/domain/sync_ids.dart';

part 'details_controller.g.dart';

String episodeSelectionKey(Episode episode) {
  return [
    episode.season,
    episode.episode,
    episode.dubStatus.name,
    episode.url,
  ].join('|');
}

/// The provider already gave everything the header shows (poster,
/// backdrop, description and score): neither Cinemeta nor TMDB has a
/// display field left to fill, so no display metadata is fetched.
bool hasFullDisplaySet(MultimediaItem item) {
  return item.posterUrl.isNotEmpty &&
      item.bannerUrl != null &&
      item.bannerUrl!.isNotEmpty &&
      item.description != null &&
      item.description!.trim().isNotEmpty &&
      item.score != null;
}

/// Whether [meta] would fill at least one display field [item] left empty.
bool _cinemetaFillsAny(MultimediaItem item, AddonMeta meta) {
  final poster = meta.poster;
  if (item.posterUrl.isEmpty && poster != null && poster.isNotEmpty) {
    return true;
  }
  final background = meta.background;
  if ((item.bannerUrl == null || item.bannerUrl!.isEmpty) &&
      background != null &&
      background.isNotEmpty) {
    return true;
  }
  final description = meta.description;
  if ((item.description == null || item.description!.trim().isEmpty) &&
      description != null &&
      description.trim().isNotEmpty) {
    return true;
  }
  if (item.score == null && double.tryParse(meta.imdbRating ?? '') != null) {
    return true;
  }
  if ((item.cast == null || item.cast!.isEmpty) &&
      (meta.castMembers.isNotEmpty || meta.cast.isNotEmpty)) {
    return true;
  }
  return false;
}

/// Returns [item] with Cinemeta's display fields merged into the gaps the
/// provider left (poster, backdrop, description, score, cast). A value
/// the provider gave is never overwritten; a field Cinemeta doesn't have
/// stays empty for TMDB.
MultimediaItem _withCinemetaDisplayGapsFilled(
  MultimediaItem item,
  AddonMeta meta,
) {
  final poster = meta.poster;
  final background = meta.background;
  final description = meta.description;
  final score = item.score ?? double.tryParse(meta.imdbRating ?? '');
  List<Actor>? cast = item.cast;
  if (cast == null || cast.isEmpty) {
    if (meta.castMembers.isNotEmpty) {
      // Character roles when Cinemeta has them; a photo only when it is
      // a full URL (a bare TMDB-style path would not load as-is).
      cast = meta.castMembers
          .map(
            (m) => Actor(
              name: m.name,
              role: m.character.isEmpty ? null : m.character,
              image:
                  m.profilePath != null && m.profilePath!.startsWith('http')
                      ? m.profilePath
                      : null,
            ),
          )
          .toList();
    } else if (meta.cast.isNotEmpty) {
      cast = meta.cast.map((name) => Actor(name: name)).toList();
    }
  }
  return item.copyWith(
    posterUrl:
        item.posterUrl.isEmpty && poster != null && poster.isNotEmpty
            ? poster
            : null,
    bannerUrl:
        (item.bannerUrl == null || item.bannerUrl!.isEmpty) &&
                background != null &&
                background.isNotEmpty
            ? background
            : null,
    description:
        (item.description == null || item.description!.trim().isEmpty) &&
                description != null &&
                description.trim().isNotEmpty
            ? description
            : null,
    score: score,
    cast: cast,
  );
}

/// An [AddonMeta] carrying only a catalog preview's display fields, so a
/// validated title-search hit can land through the same gaps-only merge
/// as a full meta record. No cast: the preview has none.
AddonMeta _previewAsMeta(AddonMetaPreview preview) {
  return AddonMeta(
    id: preview.id,
    type: preview.type,
    name: preview.name,
    poster: preview.poster,
    background: preview.background,
    logo: preview.logo,
    description: preview.description,
    releaseInfo: preview.releaseInfo,
    imdbRating: preview.imdbRating,
    imdbIdField: preview.imdbIdField,
    yearField: preview.yearField,
    genres: preview.genres,
    addonId: preview.addonId,
    addonName: preview.addonName,
    hasDeclaredType: preview.hasDeclaredType,
  );
}

class DetailsState {
  final AsyncValue<MultimediaItem?> details;
  final Map<int, List<Episode>> seasonMap;
  final int selectedSeason;
  final bool isMovie;
  final MultimediaItem? item;
  final bool isLaunching;
  final Episode? targetEpisode;
  final bool isAscending;
  final int selectedRangeIndex;
  final DubStatus selectedDubStatus;
  final Set<String> selectedEpisodeKeys;

  const DetailsState({
    this.details = const AsyncLoading(),
    this.seasonMap = const {},
    this.selectedSeason = 1,
    this.isMovie = false,
    this.item,
    this.isLaunching = false,
    this.targetEpisode,
    this.isAscending = true,
    this.selectedRangeIndex = 0,
    this.selectedDubStatus = DubStatus.none,
    this.selectedEpisodeKeys = const <String>{},
  });

  DetailsState copyWith({
    AsyncValue<MultimediaItem?>? details,
    Map<int, List<Episode>>? seasonMap,
    int? selectedSeason,
    bool? isMovie,
    MultimediaItem? item,
    bool? isLaunching,
    Episode? targetEpisode,
    bool? isAscending,
    int? selectedRangeIndex,
    DubStatus? selectedDubStatus,
    Set<String>? selectedEpisodeKeys,
  }) {
    return DetailsState(
      details: details ?? this.details,
      seasonMap: seasonMap ?? this.seasonMap,
      selectedSeason: selectedSeason ?? this.selectedSeason,
      isMovie: isMovie ?? this.isMovie,
      item: item ?? this.item,
      isLaunching: isLaunching ?? this.isLaunching,
      targetEpisode: targetEpisode ?? this.targetEpisode,
      isAscending: isAscending ?? this.isAscending,
      selectedRangeIndex: selectedRangeIndex ?? this.selectedRangeIndex,
      selectedDubStatus: selectedDubStatus ?? this.selectedDubStatus,
      selectedEpisodeKeys: selectedEpisodeKeys ?? this.selectedEpisodeKeys,
    );
  }
}

@riverpod
class DetailsController extends _$DetailsController {
  @override
  DetailsState build(String itemUrl) {
    ref.listen(activeDownloadsProvider, (prev, next) {
      final details = state.details.asData?.value;
      if (details == null) return;

      // Detect URLs that were active but are no longer active (completed/failed/canceled)
      final previousSet = prev ?? <String>{};
      final finishingUrls = previousSet.difference(next);

      if (finishingUrls.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[DetailsController] Re-checking status immediately after download finished: $finishingUrls',
          );
        }

        // Re-check specific item if its URL finished
        if (finishingUrls.contains(details.url)) {
          ref.read(downloadedFilesProvider.notifier).checkFile(details);
        }

        // Re-check episodes
        final episodes = details.episodes ?? [];
        for (final ep in episodes) {
          if (finishingUrls.contains(ep.url)) {
            ref
                .read(downloadedFilesProvider.notifier)
                .checkFile(details, episode: ep);
          }
        }
      }
    });

    ref.listen(watchHistoryProvider, (prev, next) {
      final details = state.details.asData?.value;
      if (details != null) {
        _processEpisodes(details.episodes, details, isInitial: false);
      }
    });

    ref.listen(episodeWatchRevisionProvider, (prev, next) {
      final details = state.details.asData?.value;
      if (details != null) {
        _processEpisodes(details.episodes, details, isInitial: false);
      }
    });

    final savedAscending =
        ref
            .read(storageServiceProvider)
            .getPlayerSetting<bool>(
              'episode_sort_ascending',
              defaultValue: true,
            ) ??
        true;

    return DetailsState(isAscending: savedAscending);
  }

  void init(MultimediaItem initialItem) {
    if (state.item == null) {
      state = state.copyWith(item: initialItem);
    }
  }

  void setSeason(int season) {
    if (state.seasonMap.containsKey(season)) {
      state = state.copyWith(selectedSeason: season, selectedRangeIndex: 0);
    }
  }

  void toggleSort() {
    final nextAscending = !state.isAscending;
    state = state.copyWith(isAscending: nextAscending);

    unawaited(
      ref
          .read(storageServiceProvider)
          .setPlayerSetting('episode_sort_ascending', nextAscending),
    );
  }

  bool isEpisodeSelected(Episode episode) {
    return state.selectedEpisodeKeys.contains(episodeSelectionKey(episode));
  }

  void toggleEpisodeSelection(Episode episode) {
    final next = Set<String>.from(state.selectedEpisodeKeys);
    final key = episodeSelectionKey(episode);

    if (!next.add(key)) {
      next.remove(key);
    }

    state = state.copyWith(selectedEpisodeKeys: next);
  }

  void selectAllEpisodes() {
    final allEpisodeKeys = state.seasonMap.values
        .expand((episodes) => episodes)
        .map(episodeSelectionKey)
        .toSet();

    if (allEpisodeKeys.isEmpty) {
      return;
    }

    state = state.copyWith(selectedEpisodeKeys: allEpisodeKeys);
  }

  void clearEpisodeSelection() {
    if (state.selectedEpisodeKeys.isEmpty) {
      return;
    }

    state = state.copyWith(selectedEpisodeKeys: const <String>{});
  }

  Future<void> setSelectedEpisodesWatched(String mainUrl, bool watched) async {
    if (state.selectedEpisodeKeys.isEmpty) {
      return;
    }

    final selectedKeys = Set<String>.from(state.selectedEpisodeKeys);

    final selectedEpisodes = state.seasonMap.values
        .expand((episodes) => episodes)
        .where((episode) => selectedKeys.contains(episodeSelectionKey(episode)))
        .toList(growable: false);

    if (selectedEpisodes.isEmpty) {
      clearEpisodeSelection();
      return;
    }

    await ref
        .read(episodeWatchRepositoryProvider)
        .setManyWatched(mainUrl, selectedEpisodes, watched);

    if (!ref.mounted) {
      return;
    }

    state = state.copyWith(selectedEpisodeKeys: const <String>{});

    final currentDetails = state.details.asData?.value;
    if (currentDetails != null) {
      _processEpisodes(
        currentDetails.episodes,
        currentDetails,
        isInitial: false,
      );
    }
  }

  void setRangeIndex(int index) {
    state = state.copyWith(selectedRangeIndex: index);
  }

  void setDubStatus(DubStatus status) {
    state = state.copyWith(selectedDubStatus: status, selectedRangeIndex: 0);
  }

  void setLaunching(bool value) {
    if (state.isLaunching != value) {
      state = state.copyWith(isLaunching: value);
    }
  }

  Future<void> loadDetails(MultimediaItem item, {bool autoPlay = false}) async {
    if (state.details is AsyncData) return;

    state = state.copyWith(details: const AsyncLoading());

    final active = ref.read(activeProviderProvider);
    final manager = ref.read(extensionManagerProvider.notifier);

    try {
      if (item.provider == 'Local' ||
          item.provider == 'Torrent' ||
          item.provider == 'Remote') {
        var itemToUse = item;
        if (itemToUse.episodes == null || itemToUse.episodes!.isEmpty) {
          itemToUse = itemToUse.copyWith(
            episodes: [
              Episode(
                name: itemToUse.title,
                url: itemToUse.url,
                posterUrl: itemToUse.posterUrl,
              ),
            ],
          );
        }

        _processEpisodes(itemToUse.episodes, itemToUse);
        state = state.copyWith(details: AsyncData(itemToUse));
        return;
      }

      SkyStreamProvider? provider;
      if (item.provider != null) {
        try {
          provider = manager.getAllProviders().firstWhere(
            (p) => p.packageName == item.provider || p.name == item.provider,
          );
        } catch (e) {
          if (kDebugMode) debugPrint('DetailsController.loadDetails: $e');
        }
      }

      provider ??= active;

      if (provider != null) {
        // Start the TMDB enrichment now, in parallel with getDetails: the
        // title is already known from the catalog item, and the enrichment
        // used to wait for the (slow) provider fetch first. It patches the
        // ids onto whatever is on screen when it lands, and the post-fetch
        // call below still runs — its searches hit the TMDB/metadata
        // caches, so nothing is fetched twice.
        unawaited(_resolveMetadataInBackground(item));

        final fetchedItem = await provider.getDetails(item.url);
        if (!ref.mounted) return;

        final withProvider = fetchedItem.copyWith(
          provider: provider.packageName,
          tmdbId: fetchedItem.tmdbId ?? item.tmdbId,
          imdbId: fetchedItem.imdbId ?? item.imdbId,
        );

        // Immediately render the UI with raw provider details so it's not blocked
        final sortedEpisodes = _processEpisodes(
          withProvider.episodes,
          withProvider,
          isInitial: true,
        );
        state = state.copyWith(
          details: AsyncData(withProvider.copyWith(episodes: sortedEpisodes)),
          item: withProvider.copyWith(episodes: sortedEpisodes),
        );

        // Run Metadata Resolution in background silently (fire-and-forget).
        unawaited(_resolveMetadataInBackground(withProvider));
      } else {
        throw Exception("No provider selected or found for this item");
      }
    } catch (e, st) {
      if (ref.mounted) {
        state = state.copyWith(
          details: AsyncError(e, st),
          // The provider gave no details, so _processEpisodes never ran
          // and isMovie stayed false — which hides the Play button for
          // a Vega movie (hidePlay: isVega && !isMovie). The catalog
          // item's own content type is the verdict here; a series keeps
          // isMovie false and its Play button stays hidden.
          isMovie: item.contentType == MultimediaContentType.movie,
          // A film is one episode — itself — so the Play button has
          // something to play (mirrors the provider's film synthesis).
          // Set now so Play is enabled at once, not only after the
          // background enrichment lands.
          item: _withFilmEpisode(item),
        );
      }
      // The provider's getMeta failed, but the catalog item still names
      // the title: resolve its TMDB/IMDb ids in the background anyway, so
      // the TMDB display metadata (poster/backdrop/overview/rating) can
      // still load for it. The error itself stays as-is.
      unawaited(_resolveMetadataInBackground(item));
    }
  }

  /// A film is one episode — itself (mirrors the Vega provider's film
  /// synthesis in `VegaBasedProvider._infoToItem`): the details page's
  /// Play button is gated on `episodes` being non-empty, so without one
  /// the button is dead and neither tap (direct play) nor hold (links
  /// sheet) works. A series keeps no episodes here; its Play button
  /// stays hidden by the Vega-series rule.
  MultimediaItem _withFilmEpisode(MultimediaItem item) {
    if (item.contentType != MultimediaContentType.movie) return item;
    if (item.episodes != null && item.episodes!.isNotEmpty) return item;
    return item.copyWith(
      episodes: [Episode(name: item.title, url: item.url)],
    );
  }

  Future<void> _resolveMetadataInBackground(MultimediaItem withProvider) async {
    try {
      if (kDebugMode) {
        debugPrint(
          'DetailsController: Fetching missing IDs in background for ${withProvider.title}...',
        );
      }
      MultimediaItem enrichedItem = withProvider;

      // Resolve when EITHER id is missing: enrichWithIds fills only the
      // missing one (fast path for a missing imdbId, title search for a
      // missing tmdbId). Skipping when only one id existed left the other
      // unresolved, so TMDB display metadata never loaded for those titles.
      final hasBothWesternIds =
          withProvider.tmdbId != null && withProvider.imdbId != null;

      // The provider already gave the full display set: Cinemeta has no
      // display field left to fill. Ids are still resolved when missing
      // (the links sheet and Nuvio need them), but no display metadata
      // is fetched.
      final displayFull = hasFullDisplaySet(withProvider);

      // Cinemeta starts NOW — in parallel with the TMDB id resolution
      // below, never waiting for it. By IMDb id when one is already on
      // the item, else by title search (validated, display-only — see
      // _fetchCinemetaByTitle). Either way its patch lands the moment
      // its own fetch finishes, never behind the id patch (and the TMDB
      // watch it starts) or Simkl.
      Future<AddonMeta?>? cinemetaFuture;
      var cinemetaTitleSearchStarted = false;
      if (!displayFull) {
        if (withProvider.imdbId != null &&
            withProvider.imdbId!.isNotEmpty) {
          cinemetaFuture = _fetchCinemetaMeta(withProvider);
          unawaited(
            cinemetaFuture.then((meta) {
              if (meta != null && ref.mounted) _patchCinemetaDisplay(meta);
            }),
          );
        } else if (_cinemetaTypeFor(withProvider) != null &&
            withProvider.title.trim().isNotEmpty) {
          cinemetaTitleSearchStarted = true;
          unawaited(_fetchCinemetaByTitle(withProvider));
        }
      }

      try {
        if (!hasBothWesternIds) {
          enrichedItem = await ref
              .read(metadataResolutionServiceProvider)
              .enrichWithIds(withProvider);
          if (kDebugMode) {
            debugPrint(
              'DetailsController: Background resolution result -> tmdbId: ${enrichedItem.tmdbId}, imdbId: ${enrichedItem.imdbId}',
            );
          }
        } else {
          if (kDebugMode) {
            debugPrint(
              'DetailsController: Bypassed TMDB resolution (both tmdbId and imdbId already provided by scraper)',
            );
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            'DetailsController: TMDB metadata resolution failed, but continuing: $e',
          );
        }
      }

      // No IMDb id at the start and no title search ran (a blank title,
      // or a type Cinemeta has no meta for), but the resolution above
      // found one: the by-id fetch couldn't have started earlier, so
      // start it now. Its patch still lands on its own completion.
      if (!displayFull &&
          cinemetaFuture == null &&
          !cinemetaTitleSearchStarted &&
          enrichedItem.imdbId != null &&
          enrichedItem.imdbId!.isNotEmpty) {
        cinemetaFuture = _fetchCinemetaMeta(enrichedItem);
        unawaited(
          cinemetaFuture.then((meta) {
            if (meta != null && ref.mounted) _patchCinemetaDisplay(meta);
          }),
        );
      }

      // Simkl / AniList ids, separately: they are unrelated to the TMDB
      // display the id patch below starts, so a slow Simkl lookup must
      // not delay it. They patch syncData on their own when they land.
      unawaited(_patchSimklIds(enrichedItem));

      if (!ref.mounted) return;

      // Patch the resolved ids. This runs as soon as the resolution
      // lands — it never waits for the Cinemeta fetch or Simkl.
      final idsChanged = enrichedItem.tmdbId != withProvider.tmdbId ||
          enrichedItem.imdbId != withProvider.imdbId;
      final currentDetails = state.details.asData?.value;
      if (currentDetails != null) {
        if (idsChanged) {
          // preserve the episodes from the current state just in case
          final updatedItem = currentDetails.copyWith(
            tmdbId: enrichedItem.tmdbId,
            imdbId: enrichedItem.imdbId,
          );
          state = state.copyWith(
            details: AsyncData(updatedItem),
            item: updatedItem,
          );
        }
      } else if (idsChanged) {
        // getDetails failed (details is AsyncError, so there is no
        // fetched item to patch): the enriched ids still belong on the
        // state item, so the screen's TMDB fill and the links sheet can
        // use them. The error itself is left untouched. Re-attach the
        // film episode (set in the catch): the enriched item carries
        // ids but no episodes, and overwriting would kill the Play
        // button the catch just enabled.
        state = state.copyWith(item: _withFilmEpisode(enrichedItem));
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          'DetailsController: Background metadata resolution failed: $e',
        );
      }
    }
  }

  /// Simkl / AniList tracking ids for an anime title, patched separately
  /// when they land: they never gate the TMDB/IMDb id patch (or the TMDB
  /// display watch it starts), and a slow Simkl lookup delays nothing.
  /// Gaps-only, like the id patch — a tracker's own ids always win.
  Future<void> _patchSimklIds(MultimediaItem item) async {
    try {
      final isAnime =
          item.contentType == MultimediaContentType.anime ||
          item.syncData?['anilistId'] != null ||
          item.syncData?['anilist_id'] != null ||
          (item.tags != null &&
              item.tags!.any(
                (t) =>
                    t.toLowerCase() == 'anime' ||
                    t.toLowerCase() == 'animation',
              ));
      if (!isAnime) return;

      final hasAnilistId =
          item.syncData?['anilist'] != null ||
          item.syncData?['anilistId'] != null ||
          item.syncData?['anilist_id'] != null;
      if (hasAnilistId) {
        if (kDebugMode) {
          debugPrint(
            'DetailsController: Bypassed Simkl fetch (AniList ID already provided by scraper)',
          );
        }
        return;
      }

      final resolved = await ref.read(simklServiceProvider).syncIds(item);
      if (resolved.isEmpty || !ref.mounted) return;
      if (kDebugMode) {
        debugPrint('DetailsController: Fetched Simkl IDs: $resolved');
      }

      // Fills the gaps only: an extension's MAL id names the season,
      // Simkl's (looked up by IMDb or TMDB id) the series. Nothing to
      // fill means no state write at all.
      final currentDetails = state.details.asData?.value;
      if (currentDetails != null) {
        if (resolved.entries.any((e) => currentDetails.syncData?[e.key] == null)) {
          final updated = currentDetails.copyWith(
            syncData: withLookedUpIds(currentDetails.syncData, resolved),
          );
          state = state.copyWith(details: AsyncData(updated), item: updated);
        }
        return;
      }
      final currentItem = state.item;
      if (currentItem == null) return;
      if (resolved.entries.any((e) => currentItem.syncData?[e.key] == null)) {
        state = state.copyWith(
          item: currentItem.copyWith(
            syncData: withLookedUpIds(currentItem.syncData, resolved),
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          'DetailsController: Failed to fetch Simkl IDs in background: $e',
        );
      }
    }
  }

  /// Cinemeta display metadata for [item] by title search, for titles
  /// that arrived with no IMDb id: the search runs in parallel with the
  /// TMDB id resolution and never waits for it.
  ///
  /// SAFETY: the hit is display-only. It is accepted only when it scores
  /// >= 0.6 against this title (a weak match is dropped entirely), and
  /// its imdb_id is used ONLY as a transient argument to fetch the full
  /// record for cast — it is never written to the item's tmdbId/imdbId,
  /// which feed streams and links. The preview's display fields land at
  /// once; the full record follows for cast when it arrives.
  Future<void> _fetchCinemetaByTitle(MultimediaItem item) async {
    final type = _cinemetaTypeFor(item);
    final title = item.title.trim();
    if (type == null || title.isEmpty) return;
    try {
      final client = ref.read(addonClientProvider);
      final preview = await client
          .resolveCinemetaPreview(title: title, type: type, year: item.year)
          .timeout(const Duration(seconds: 12));
      if (preview == null || !ref.mounted) return;
      if (!MetadataResolutionService.acceptsTitleMatch(
        sourceTitle: item.title,
        sourceYear: item.year,
        candidate: preview.toMultimediaItem(),
      )) {
        if (kDebugMode) {
          debugPrint(
            'DetailsController: Dropped weak Cinemeta title-search hit '
            '"${preview.name}" for "${item.title}".',
          );
        }
        return;
      }
      // Display fields land now, from the validated preview — the cast
      // fetch below must not delay them.
      _patchCinemetaDisplay(_previewAsMeta(preview));
      if (!ref.mounted) return;
      // The preview carries no cast: the full record, by the hit's
      // imdb_id, transiently. A miss here loses only cast; TMDB still
      // fills the remaining display gaps.
      final imdbId = preview.imdbId;
      if (imdbId == null || imdbId.isEmpty) return;
      final meta = await _fetchCinemetaMetaForId(imdbId, type);
      if (meta != null && ref.mounted) _patchCinemetaDisplay(meta);
    } on TimeoutException {
      return;
    } catch (_) {
      return;
    }
  }

  /// The Cinemeta type for [item]: a film is `movie`, a series or an anime
  /// is `series`. Live streams and untyped items have no Cinemeta meta.
  String? _cinemetaTypeFor(MultimediaItem item) {
    switch (item.contentType) {
      case MultimediaContentType.movie:
        return 'movie';
      case MultimediaContentType.series:
      case MultimediaContentType.anime:
        return 'series';
      case MultimediaContentType.livestream:
      case MultimediaContentType.other:
        return null;
    }
  }

  /// Cinemeta display metadata for [item] by its IMDb id, or null when
  /// Cinemeta doesn't know it, is slow, or fails. Never throws: a miss
  /// just falls through to TMDB.
  Future<AddonMeta?> _fetchCinemetaMeta(MultimediaItem item) async {
    final imdbId = item.imdbId;
    final type = _cinemetaTypeFor(item);
    if (imdbId == null || imdbId.isEmpty || type == null) return null;
    return _fetchCinemetaMetaForId(imdbId, type);
  }

  /// Cinemeta display metadata by IMDb id. Reuses [AddonClient.meta]
  /// (shared Dio, clearance handling, 45-min meta cache + single-flight),
  /// with the same 12 s caller ceiling the add-on meta fallback uses —
  /// no bot check sheet is ever raised for a background enrichment.
  Future<AddonMeta?> _fetchCinemetaMetaForId(
    String imdbId,
    String type,
  ) async {
    try {
      final client = ref.read(addonClientProvider);
      final meta = await client
          .meta(BuiltInAddons.cinemeta, type: type, id: imdbId)
          .timeout(const Duration(seconds: 12));
      if (meta != null) return meta;
      // A wrong type 404s (a film listed as a series, or vice versa):
      // try the other one. A 404 is cheap; a timeout is not retried.
      final other = type == 'movie' ? 'series' : 'movie';
      return await client
          .meta(BuiltInAddons.cinemeta, type: other, id: imdbId)
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Merges Cinemeta display fields into the live details/state item —
  /// gaps only, so a value the provider gave is never overwritten. This
  /// is the middle of the chain (provider → Cinemeta → TMDB): the
  /// screen's TMDB fill then only fills what is STILL empty.
  void _patchCinemetaDisplay(AddonMeta meta) {
    final currentDetails = state.details.asData?.value;
    if (currentDetails != null) {
      if (!_cinemetaFillsAny(currentDetails, meta)) return;
      final updatedItem =
          _withCinemetaDisplayGapsFilled(currentDetails, meta);
      state = state.copyWith(
        details: AsyncData(updatedItem),
        item: updatedItem,
      );
      return;
    }
    // getDetails failed: the state item is the catalog item (with the
    // film episode for a movie). Fill its gaps the same way.
    final currentItem = state.item;
    if (currentItem == null) return;
    if (!_cinemetaFillsAny(currentItem, meta)) return;
    state = state.copyWith(
      item: _withCinemetaDisplayGapsFilled(currentItem, meta),
    );
  }

  List<Episode>? _processEpisodes(
    List<Episode>? episodes,
    MultimediaItem contextItem, {
    bool isInitial = false,
  }) {
    if (episodes == null || episodes.isEmpty) {
      state = state.copyWith(
        isMovie: contextItem.contentType == MultimediaContentType.movie,
        seasonMap: {},
      );
      return episodes;
    }

    bool isMovie =
        contextItem.contentType == MultimediaContentType.movie ||
        contextItem.contentType == MultimediaContentType.livestream;

    if (isMovie) {
      state = state.copyWith(
        isMovie: true,
        seasonMap: {1: episodes},
        selectedSeason: 1,
      );
      return episodes;
    }

    final Map<int, List<Episode>> seasonMap = {};
    for (final ep in episodes) {
      final season = ep.season > 0 ? ep.season : 1;
      seasonMap.putIfAbsent(season, () => []).add(ep);
    }

    final sortedSeasons = seasonMap.keys.toList()..sort();
    int selectedSeason = sortedSeasons.isNotEmpty ? sortedSeasons.first : 1;
    Episode? targetEpisode;

    final historyRepo = ref.read(historyRepositoryProvider);
    final episodeWatchRepo = ref.read(episodeWatchRepositoryProvider);

    final allEpisodes = episodes;
    final lastEpisodeUrl = historyRepo.getLastEpisodeUrl(contextItem.url);

    if (lastEpisodeUrl != null) {
      int lastIndex = allEpisodes.indexWhere((e) => e.url == lastEpisodeUrl);

      if (lastIndex == -1) {
        final mainHistoryItem = ref
            .read(watchHistoryProvider)
            .firstWhereOrNull((h) => h.item.url == contextItem.url);
        if (mainHistoryItem != null &&
            mainHistoryItem.season != null &&
            mainHistoryItem.episode != null) {
          lastIndex = allEpisodes.indexWhere(
            (e) =>
                e.season == mainHistoryItem.season &&
                e.episode == mainHistoryItem.episode,
          );
        }
      }

      if (lastIndex != -1) {
        final matchedEp = allEpisodes[lastIndex];
        if (episodeWatchRepo.isWatched(contextItem.url, matchedEp)) {
          if (lastIndex + 1 < allEpisodes.length) {
            targetEpisode = allEpisodes[lastIndex + 1];
          } else {
            targetEpisode = allEpisodes[lastIndex];
          }
        } else {
          targetEpisode = allEpisodes[lastIndex];
        }
      }
    }

    targetEpisode ??= allEpisodes.firstWhereOrNull(
      (episode) => !episodeWatchRepo.isWatched(contextItem.url, episode),
    );

    targetEpisode ??= allEpisodes.last;

    if (isInitial && targetEpisode.season > 0) {
      selectedSeason = targetEpisode.season;
    } else {
      selectedSeason = state.selectedSeason;
    }

    DubStatus selectedDubStatus = state.selectedDubStatus;
    if (isInitial) {
      final hasSub = episodes.any((e) => e.dubStatus == DubStatus.subbed);
      final hasDub = episodes.any((e) => e.dubStatus == DubStatus.dubbed);
      if (hasSub && hasDub) {
        selectedDubStatus = DubStatus.subbed;
      } else {
        selectedDubStatus = DubStatus.none;
      }
    }

    state = state.copyWith(
      isMovie: false,
      seasonMap: seasonMap,
      selectedSeason: selectedSeason,
      targetEpisode: targetEpisode,
      selectedDubStatus: selectedDubStatus,
    );
    return episodes;
  }

  void toggleLibrary() {
    final item = state.details.value;
    if (item == null) return;

    final libraryRepo = ref.read(libraryRepositoryProvider);
    final wasInLibrary = libraryRepo.isInLibrary(item.url);

    if (wasInLibrary) {
      ref.read(libraryProvider.notifier).removeItem(item.url);
    } else {
      ref.read(libraryProvider.notifier).addItem(item);
    }
  }

  Future<void> handlePlayPress(
    // Only handed on to the launcher, which needs it to push the player;
    // choosing the episode is the part that belongs here.
    // ignore: riverpod_lint/avoid_build_context_in_providers
    BuildContext context,
    MultimediaItem details, {
    Episode? specificEpisode,
    String? overrideUrl,
  }) async {
    if (overrideUrl != null) {
      await ref
          .read(playbackLauncherProvider)
          .play(context, overrideUrl, baseItem: details);
      return;
    }

    if (specificEpisode != null) {
      await ref
          .read(playbackLauncherProvider)
          .play(context, specificEpisode.url, baseItem: details);
      return;
    }

    if (state.isMovie) {
      // Auto-play has no `playable` guard the way the Play button does: a
      // movie whose provider now returns zero episodes must not throw here.
      final episodes = details.episodes;
      if (episodes == null || episodes.isEmpty) return;
      await ref
          .read(playbackLauncherProvider)
          .play(context, episodes.first.url, baseItem: details);
      return;
    }

    if (state.targetEpisode != null) {
      await ref
          .read(playbackLauncherProvider)
          .play(context, state.targetEpisode!.url, baseItem: details);
      return;
    }

    final firstSeason = state.seasonMap.keys.toList()..sort();
    if (firstSeason.isNotEmpty) {
      final ep = state.seasonMap[firstSeason.first]?.first;
      if (ep != null) {
        await ref
            .read(playbackLauncherProvider)
            .play(context, ep.url, baseItem: details);
      }
    }
  }

  /// The links box, as the Stremio section opens it: every installed source
  /// (plugins, Nuvio providers, Stremio add-ons) asked for this title's
  /// streams, listed for a pick instead of playing the first answer.
  /// Reached by holding Play on the details page and by double-tapping an
  /// episode. [details] is the resolved item; [specificEpisode] narrows the
  /// ask to one episode, or null for the title's target (movie / next up).
  Future<void> openLinksSheet(
    // Only handed on to the sheet, which needs it to show the dialog;
    // choosing what to ask is the part that belongs here.
    // ignore: riverpod_lint/avoid_build_context_in_providers
    BuildContext context,
    MultimediaItem details, {
    Episode? specificEpisode,
  }) async {
    // The background TMDB/IMDb enrichment may not have landed yet: with
    // no id at all Nuvio is never asked and the sheet only shows the
    // "no TMDB or IMDb id" note. Reuse the enriched state item when it has
    // one, else resolve now before building the request.
    var resolvedDetails = details;
    if (resolvedDetails.tmdbId == null && resolvedDetails.imdbId == null) {
      final stateItem = state.item;
      if (stateItem != null &&
          stateItem.url == details.url &&
          (stateItem.tmdbId != null || stateItem.imdbId != null)) {
        resolvedDetails = stateItem;
      } else {
        try {
          resolvedDetails = await ref
              .read(metadataResolutionServiceProvider)
              .enrichWithIds(details);
        } catch (_) {
          // Enrichment failed: open the sheet with the raw ids, as before.
        }
      }
    }
    final type = switch (resolvedDetails.contentType) {
      MultimediaContentType.movie => 'movie',
      MultimediaContentType.series || MultimediaContentType.anime => 'series',
      MultimediaContentType.livestream => 'tv',
      MultimediaContentType.other => 'other',
    };
    await AddonSourcesSheet.open(
      context,
      item: resolvedDetails,
      request: AddonStreamRequest(
        type: type,
        contentId: resolvedDetails.url,
        season: specificEpisode?.season,
        episode: specificEpisode?.episode,
        imdbId: resolvedDetails.imdbId,
        tmdbId: resolvedDetails.tmdbId,
        title: resolvedDetails.title,
        year: resolvedDetails.year,
      ),
      episode: specificEpisode,
      merged: true,
    );
  }
}

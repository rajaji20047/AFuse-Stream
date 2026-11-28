import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/notification_service.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/models/tmdb_details.dart';
import '../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../core/utils/image_fallbacks.dart';
import '../../../core/utils/image_utils.dart';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:raja/core/utils/responsive_breakpoints.dart';

import '../../library/presentation/library_provider.dart';
import '../../library/presentation/library_state.dart';

import '../data/tmdb_details_provider.dart';
import 'details_controller.dart';
import "widgets/details_layout_widgets.dart";
import "widgets/vega_details_widgets.dart";
import "widgets/details_desktop_hero.dart";
import "widgets/hero_details_widgets.dart";
import "widgets/premium_details_widgets.dart";
import 'widgets/movie_cast_list.dart';
import "../../../shared/widgets/loading_indicator.dart";
import "../../../shared/widgets/check_line.dart";
import "../../../core/extensions/extension_manager.dart";

import 'package:raja/l10n/generated/app_localizations.dart';

class DetailsScreen extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final bool autoPlay;

  const DetailsScreen({super.key, required this.item, this.autoPlay = false});

  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  bool _didTriggerAutoPlay = false;

  /// How far the phone page has scrolled; the top bar's backing follows it
  /// (v9), so content never shows through the clock or the back button.
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0);

  bool _onPageScroll(ScrollNotification notification) {
    // Only the page itself: rows inside it scroll sideways.
    if (notification.depth == 0 &&
        notification.metrics.axis == Axis.vertical) {
      _scrollOffset.value = notification.metrics.pixels;
    }
    return false;
  }

  @override
  void dispose() {
    _scrollOffset.dispose();
    super.dispose();
  }

  /// What a bot check met while this title loads is filed under: its
  /// plugin's, else the active one's.
  String? _checkSource() {
    final wanted = widget.item.provider;
    final match = wanted == null
        ? null
        : ref
              .read(extensionManagerProvider.notifier)
              .getAllProviders()
              .where((p) => p.packageName == wanted || p.name == wanted)
              .firstOrNull;
    return (match ?? ref.read(activeProviderProvider))?.checkSource;
  }

  Future<void> _copyAnimeTitle(BuildContext context, String title) async {
    await Clipboard.setData(ClipboardData(text: title));
    await HapticFeedback.selectionClick();

    if (!context.mounted) {
      return;
    }

    ref
        .read(notificationServiceProvider)
        .showSuccess(
          'Copied to clipboard',
          title: title,
          icon: Icons.content_copy_rounded,
          duration: const Duration(milliseconds: 2200),
        );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(detailsControllerProvider(widget.item.url).notifier)
          .loadDetails(widget.item, autoPlay: widget.autoPlay);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(detailsControllerProvider(widget.item.url), (prev, next) {
      if (!widget.autoPlay || _didTriggerAutoPlay) return;
      final prevState = prev ?? const DetailsState();
      final nextState = next;
      if (prevState.details.isLoading != true || !nextState.details.hasValue) {
        return;
      }
      final item = nextState.details.value!;
      _didTriggerAutoPlay = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref
            .read(detailsControllerProvider(widget.item.url).notifier)
            .handlePlayPress(context, item);
      });
    });
    final isBookmarked = ref.watch(
      libraryProvider.select(
        (state) =>
            state is LibrarySuccess &&
            state.items.any((i) => i.url == widget.item.url),
      ),
    );
    final libraryNotifier = ref.read(libraryProvider.notifier);
    final isLarge = context.isTabletOrLarger;

    final detailsAsync = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.details),
    );
    final details = detailsAsync.value;
    final isMovie = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.isMovie),
    );
    // When getDetails failed the controller keeps the enriched catalog
    // item (with its resolved tmdbId) on the state item: it is the
    // fallback the TMDB fill below reads, so TMDB metadata still loads
    // even though the provider gave no details.
    final stateItem = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.item),
    );
    final rawItem = details ?? stateItem ?? widget.item;
    // TMDB details for the Cast row (photos + character roles, like Browse)
    // AND to fill the display gaps the plugin left (poster, backdrop,
    // overview, rating). The tmdbId is resolved in the background by
    // DetailsController; until it lands — or when TMDB has no credits —
    // the plugin's own cast is the fallback (CastCarousel's text line).
    // The TMDB details belong to the resolved title by construction, so no
    // name-matching is needed. The merge below only fills EMPTY plugin
    // fields; a plugin value is never overwritten.
    // In the error path state.isMovie was never set (no episodes were
    // processed), so a movie would be fetched as 'tv' and TMDB would
    // return nothing for its id. The item's own content type is the
    // fallback: it only changes the error path, the success path still
    // reads isMovie.
    final tmdbType =
        isMovie || rawItem.contentType == MultimediaContentType.movie
            ? 'movie'
            : 'tv';
    final tmdb = rawItem.tmdbId != null
        ? ref
              .watch(
                tmdbDetailsProvider(
                  MovieDetailsParams(rawItem.tmdbId!, tmdbType),
                ),
              )
              .value
        : null;
    final tmdbCast = tmdb?.tmdbCast;
    final item = _withTmdbDisplayGapsFilled(rawItem, tmdb);
    final selectedEpisodeCount = ref.watch(
      detailsControllerProvider(widget.item.url)
          .select((state) => state.selectedEpisodeKeys.length),
    );

    final l10n = AppLocalizations.of(context)!;

    // ── Desktop / TV: Immersive hero layout ──
    if (isLarge) {
      return _buildDesktopLayout(
        context,
        item,
        details,
        detailsAsync,
        isMovie,
        isBookmarked,
        libraryNotifier,
        l10n,
        selectedEpisodeCount,
        tmdbCast,
      );
    }

    // ── Mobile: "Hero" layout ──
    // A full-bleed banner carrying the source tag, the title and the round
    // Download button; the back and bookmark buttons float over it and stay put
    // as the page scrolls. Play lives in the pill under the hero.
    return Scaffold(
      bottomNavigationBar: selectedEpisodeCount == 0
          ? null
          : _buildEpisodeSelectionBar(context, selectedEpisodeCount),
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onPageScroll,
            child: CustomScrollView(
              slivers: _buildMobileSlivers(
                context,
                item,
                details,
                detailsAsync,
                isMovie,
                l10n,
                tmdbCast,
              ),
            ),
          ),
          // Mobile: back/bookmark excluded from D-pad traversal.
          // Users navigate back via hardware Back key on TV remotes.
          DetailsHeroTopBar(
            scrollOffset: _scrollOffset,
            leading: Focus(
              descendantsAreTraversable: false,
              child: DetailsHeroTopBar.button(
                key: const ValueKey('details-back'),
                icon: Icons.arrow_back_rounded,
                onPressed: () => context.pop(),
              ),
            ),
            actions: [
              Focus(
                descendantsAreTraversable: false,
                child: DetailsHeroTopBar.button(
                  key: const ValueKey('details-bookmark'),
                  icon: isBookmarked
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  iconColor: isBookmarked
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
                  onPressed: () {
                    if (isBookmarked) {
                      libraryNotifier.removeItem(item.url);
                    } else {
                      libraryNotifier.addItem(item);
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The banner's artwork: the backdrop, else the poster.
  Widget _buildHeroImage(BuildContext context, MultimediaItem item) {
    final height = detailsHeroBannerHeight(MediaQuery.sizeOf(context));
    final url =
        AppImageFallbacks.optional(item.bannerUrl) ??
        AppImageFallbacks.poster(item.posterUrl, label: item.title) ??
        '';
    if (url.isEmpty) {
      return ThumbnailErrorPlaceholder(label: item.title, isBackdrop: true);
    }
    return Hero(
      tag: 'banner_${item.url}',
      child: CachedNetworkImage(
        imageUrl: url,
        httpHeaders: artworkHeaders(item),
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        // Bound decoded bitmap; plugin backdrops are often at source
        // resolution. Without this, 4K-source posters burn ~33 MB per
        // detail page. The box is the window width by the banner's height.
        memCacheWidth: ImageUtils.coverDecodeWidth(
          context,
          width: MediaQuery.sizeOf(context).width,
          height: height,
          sourceAspectRatio: ImageUtils.backdropAspectRatio,
        ),
        placeholder: (context, url) =>
            Container(color: Theme.of(context).dividerColor),
        errorWidget: (_, _, _) =>
            ThumbnailErrorPlaceholder(label: item.title, isBackdrop: true),
      ),
    );
  }

  Widget _buildEpisodeSelectionBar(BuildContext context, int selectedCount) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final controller = ref.read(
      detailsControllerProvider(widget.item.url).notifier,
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Material(
          elevation: 10,
          shadowColor: Colors.black.withValues(alpha: 0.30),
          color: colors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 112,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  Widget actionButton({
                    required String label,
                    required IconData icon,
                    required VoidCallback onPressed,
                    required bool outlined,
                  }) {
                    final style = outlined
                        ? OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            visualDensity: VisualDensity.compact,
                          )
                        : FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            visualDensity: VisualDensity.compact,
                          );

                    if (outlined) {
                      return OutlinedButton.icon(
                        onPressed: onPressed,
                        icon: Icon(icon, size: 21),
                        label: Text(label),
                        style: style,
                      );
                    }

                    return FilledButton.icon(
                      onPressed: onPressed,
                      icon: Icon(icon, size: 21),
                      label: Text(label),
                      style: style,
                    );
                  }

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.checklist_rounded,
                            color: colors.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '$selectedCount selected',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Cancel selection',
                            visualDensity: VisualDensity.compact,
                            onPressed: controller.clearEpisodeSelection,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: actionButton(
                              label: 'Watched',
                              icon: Icons.visibility_rounded,
                              outlined: false,
                              onPressed: () async {
                                await controller.setSelectedEpisodesWatched(
                                  widget.item.url,
                                  true,
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: actionButton(
                              label: 'Unwatched',
                              icon: Icons.visibility_off_rounded,
                              outlined: true,
                              onPressed: () async {
                                await controller.setSelectedEpisodesWatched(
                                  widget.item.url,
                                  false,
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            tooltip: 'Select all episodes',
                            onPressed: controller.selectAllEpisodes,
                            icon: const Icon(Icons.select_all_rounded),
                            style: IconButton.styleFrom(
                              minimumSize: const Size(48, 48),
                              maximumSize: const Size(48, 48),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────
  //  DESKTOP / TV  — Immersive hero layout
  // ─────────────────────────────────────────────────────────────────

  Widget _buildDesktopLayout(
    BuildContext context,
    MultimediaItem item,
    MultimediaItem? details,
    AsyncValue<MultimediaItem?> detailsState,
    bool isMovie,
    bool isBookmarked,
    dynamic libraryNotifier,
    AppLocalizations l10n,
    int selectedEpisodeCount,
    List<TmdbCast>? tmdbCast,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      bottomNavigationBar: selectedEpisodeCount == 0
          ? null
          : _buildEpisodeSelectionBar(context, selectedEpisodeCount),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        // Back button — D-pad reachable (Up from Play)
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
          style: IconButton.styleFrom(
            backgroundColor: isDark ? Colors.black45 : Colors.white54,
            foregroundColor: textColor,
          ),
        ),
        actions: [
          // Bookmark — D-pad reachable
          IconButton(
            icon: Icon(
              isBookmarked
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
              color: isBookmarked
                  ? Theme.of(context).colorScheme.primary
                  : textColor,
            ),
            onPressed: () {
              if (isBookmarked) {
                libraryNotifier.removeItem(item.url);
              } else {
                libraryNotifier.addItem(item);
              }
            },
            style: IconButton.styleFrom(
              backgroundColor: isDark ? Colors.black45 : Colors.white54,
              foregroundColor: textColor,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: DetailsDesktopHero(
        displayItem: item,
        baseItem: widget.item,
        details: details,
        detailsState: detailsState,
        isMovie: isMovie,
        itemUrl: widget.item.url,
        // A Vega series hides the hero's generic Play button: its episode
        // pills below are the whole play surface (official Vega rule: no
        // standalone Play button on the details page). A Vega movie keeps
        // the generic Play button: it has no Vega-only UI of its own.
        hidePlay:
            !isMovie &&
            (isVegaDetailsItem(item) ||
                (details != null && isVegaDetailsItem(details))),
        child: _buildDesktopContentBelow(
          context,
          item,
          details,
          detailsState,
          isMovie,
          l10n,
          tmdbCast,
        ),
      ),
    );
  }

  /// Content rendered below the hero section: season chips, episodes,
  /// cast, trailers, and recommendations.
  Widget _buildDesktopContentBelow(
    BuildContext context,
    MultimediaItem item,
    MultimediaItem? details,
    AsyncValue<MultimediaItem?> detailsState,
    bool isMovie,
    AppLocalizations l10n,
    List<TmdbCast>? tmdbCast,
  ) {
    // Vega-only details UI, as on the phone page: every other provider
    // renders the shared UI below exactly as before.
    final isVega =
        isVegaDetailsItem(item) ||
        (details != null && isVegaDetailsItem(details));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Loading / Error / Season chips
        if (detailsState is AsyncLoading)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Center(child: AppLoadingIndicator()),
              CheckLine(source: _checkSource()),
            ],
          )
        else if (detailsState is AsyncError)
          Text(
            "Error: ${detailsState.error}",
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (!isMovie && details?.episodes != null)
          if (isVega)
            VegaSeriesEpisodesSection(
              parentItem: item,
              itemUrl: widget.item.url,
            )
          else
            DetailsSeasonListWrapper(itemUrl: widget.item.url),

        const SizedBox(height: 16),

        // Episode grid (non-sliver version); a Vega series shows its own
        // episode pills above.
        if (!isVega || isMovie)
          DetailsDesktopEpisodeColumn(
            parentItem: item,
            itemUrl: widget.item.url,
            isMovie: isMovie,
          ),

        const SizedBox(height: 32),

        // Cast — TMDB credits (photos + roles) win; the plugin's own cast
        // is the fallback text line when TMDB cannot resolve.
        if (tmdbCast != null && tmdbCast.isNotEmpty) ...[
          MovieCastList(cast: tmdbCast),
        ] else if (item.cast != null && item.cast!.isNotEmpty) ...[
          CastCarousel(cast: item.cast!),
        ],

        // Trailers
        if (item.trailers != null && item.trailers!.isNotEmpty) ...[
          const SizedBox(height: 32),
          TrailersSection(trailers: item.trailers!),
        ],

        // Recommendations
        if (item.recommendations != null &&
            item.recommendations!.isNotEmpty) ...[
          const SizedBox(height: 32),
          RecommendationsCarousel(
            items: item.recommendations!,
            onItemTap: (rec) {
              DetailsRoute($extra: DetailsRouteExtra(item: rec))
                  .push<void>(context);
            },
          ),
        ],

        const SizedBox(height: 100),
      ],
    );
  }

  List<Widget> _buildMobileSlivers(
    BuildContext context,
    MultimediaItem item,
    MultimediaItem? details,
    AsyncValue<MultimediaItem?> detailsState,
    bool isMovie,
    AppLocalizations l10n,
    List<TmdbCast>? tmdbCast,
  ) {
    final theme = Theme.of(context);
    final isLoading = detailsState is AsyncLoading;
    final provider = item.provider;
    // Vega-only details UI (episode pills for a series; a Vega movie has
    // no Vega-only UI and plays through the generic Play button): every
    // other provider renders the shared UI below exactly as before.
    final isVega =
        isVegaDetailsItem(item) ||
        (details != null && isVegaDetailsItem(details));
    final infoColumns = detailsInfoColumns(
      l10n,
      item,
      isMovie: isMovie,
      isLoading: isLoading,
      episodeCount: details?.episodes?.length,
    );
    final description = item.description?.trim();

    return [
      SliverToBoxAdapter(
        child: DetailsHeroBanner(
          height: detailsHeroBannerHeight(MediaQuery.sizeOf(context)),
          image: _buildHeroImage(context, item),
          title: item.title,
          onTitleLongPress: () => _copyAnimeTitle(context, item.title),
          sourceTag: provider != null && provider.isNotEmpty
              ? DetailsProviderChip(providerName: provider, hero: true)
              : null,
          // The round button is Download now; Play lives in the pill under
          // the hero. Nothing to download (a series, a livestream) means no
          // round button at all — the banner drops its overhang with it.
          playFab: item.comingSoon ||
                  !detailsShowDownload(
                    item: widget.item,
                    details: details,
                    isMovie: isMovie,
                  )
              ? null
              : DetailsHeroDownloadButton(
                  item: widget.item,
                  details: details,
                  itemUrl: widget.item.url,
                ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.comingSoon) ...[
                const ComingSoonLabel(),
                const SizedBox(height: 12),
              ],
              if (infoColumns.isNotEmpty) ...[
                DetailsInfoStrip(
                  columns: [for (final c in infoColumns) c.column],
                ),
                const SizedBox(height: 12),
              ],
              // Download is the round button on the banner; what stays here is
              // the watched-so-far bar and Play — except for a Vega series,
              // whose episode pills are the whole play surface (official
              // Vega rule: no standalone Play button on the details page).
              // A Vega movie keeps the generic Play button: it has no
              // Vega-only UI of its own.
              if (!item.comingSoon)
                DetailsActionButtons(
                  item: widget.item,
                  details: details,
                  itemUrl: widget.item.url,
                  showPlay: false,
                  hidePlay: isVega && !isMovie,
                ),
              if (nextAiringAhead(item)) ...[
                const SizedBox(height: 12),
                NextAiringWidget(nextAiring: item.nextAiring!),
              ],
              const SizedBox(height: 12),
              // Type, age rating and whatever the strip had no room for.
              MetadataBar(
                item: item,
                isLoading: isLoading,
                hide: {
                  'provider',
                  'year',
                  'status',
                  'duration',
                  for (final c in infoColumns) c.field,
                },
              ),
              const SizedBox(height: 12),
              ExpandableSynopsis(
                text: description == null || description.isEmpty
                    ? l10n.noDescription
                    : description,
              ),
              if (item.tags != null && item.tags!.isNotEmpty) ...[
                const SizedBox(height: 12),
                TagsRow(tags: item.tags!),
              ],
              const SizedBox(height: 20),
              if (detailsState is AsyncLoading)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Center(child: AppLoadingIndicator()),
                    CheckLine(source: _checkSource()),
                  ],
                )
              else if (detailsState is AsyncError)
                Container(
                  padding: const EdgeInsets.all(16),
                  color: theme.colorScheme.error.withValues(alpha: 0.1),
                  child: Text(
                    AppLocalizations.of(context)!
                        .errorPrefix(detailsState.error.toString()),
                  ),
                )
              else if (!isMovie && details?.episodes != null)
                if (isVega)
                  VegaSeriesEpisodesSection(
                    parentItem: item,
                    itemUrl: widget.item.url,
                  )
                else
                  DetailsSeasonListWrapper(itemUrl: widget.item.url),
            ],
          ),
        ),
      ),
      // A Vega series shows its own episode pills above, so the shared
      // episode rows stay hidden for it; every other title is unchanged.
      if (!isVega || isMovie)
        SliverToBoxAdapter(
          child: DetailsEpisodeRowSection(
            parentItem: item,
            itemUrl: widget.item.url,
            isMovie: isMovie,
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cast — TMDB credits (photos + roles) win; the plugin's own
              // cast is the fallback text line when TMDB cannot resolve.
              if (tmdbCast != null && tmdbCast.isNotEmpty) ...[
                const SizedBox(height: 16),
                MovieCastList(cast: tmdbCast),
              ] else if (item.cast != null && item.cast!.isNotEmpty) ...[
                const SizedBox(height: 16),
                CastCarousel(cast: item.cast!),
              ],
              if (item.trailers != null && item.trailers!.isNotEmpty) ...[
                const SizedBox(height: 32),
                TrailersSection(trailers: item.trailers!),
              ],
              if (item.recommendations != null &&
                  item.recommendations!.isNotEmpty) ...[
                const SizedBox(height: 32),
                RecommendationsCarousel(
                  items: item.recommendations!,
                  onItemTap: (rec) {
                    DetailsRoute($extra: DetailsRouteExtra(item: rec))
                        .push<void>(context);
                  },
                ),
              ],
              const SizedBox(height: 50),
            ],
          ),
        ),
      ),
    ];
  }
}

/// Fill the display gaps a plugin left (poster, backdrop, overview, rating)
/// from the already-fetched TMDB details. Fill-gaps only: a non-empty plugin
/// value is never overwritten, and an empty TMDB value never overwrites
/// anything. The plugin item's url/provider/episodes/streams are untouched,
/// so playback and the source sheets keep working on plugin data. The page
/// is never blocked on TMDB: while the details are still loading (or TMDB
/// has no match) the item is returned unchanged and the plugin data renders.
MultimediaItem _withTmdbDisplayGapsFilled(
  MultimediaItem item,
  TmdbDetails? tmdb,
) {
  if (tmdb == null) return item;
  final posterUrl = item.posterUrl.isEmpty && tmdb.posterUrl.isNotEmpty
      ? tmdb.posterUrl
      : null;
  final bannerUrl =
      (item.bannerUrl == null || item.bannerUrl!.isEmpty) &&
              tmdb.bannerUrl != null &&
              tmdb.bannerUrl!.isNotEmpty
          ? tmdb.bannerUrl
          : null;
  final description =
      (item.description == null || item.description!.trim().isEmpty) &&
              (tmdb.description ?? '').trim().isNotEmpty
          ? tmdb.description
          : null;
  final score =
      item.score == null && (tmdb.score ?? 0) > 0 ? tmdb.score : null;
  if (posterUrl == null &&
      bannerUrl == null &&
      description == null &&
      score == null) {
    return item;
  }
  return item.copyWith(
    posterUrl: posterUrl,
    bannerUrl: bannerUrl,
    description: description,
    score: score,
  );
}

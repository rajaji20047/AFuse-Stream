/// Vega-only details page UI: the series episodes UI (Resume pill,
/// season dropdown, Find episode, episode pills) from the user's
/// screenshots. A Vega movie shows no Vega-only UI at all: it plays
/// through the generic details Play button like any other movie.
///
/// Every widget here renders ONLY for a Vega provider item; all other
/// providers keep the shared details UI exactly as it is. The playing
/// rule is the shared one: one tap plays directly, holding Play opens
/// the links sheet.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/providers/vega_based_provider.dart';
import '../../../../core/services/download_service.dart';
import '../../../../core/storage/history_repository.dart';
import '../details_controller.dart';
import '../download_launcher.dart';
import '../downloaded_file_provider.dart';
import 'details_layout_widgets.dart';
import 'download_management_dialog.dart';
import 'download_progress_dialog.dart';

import 'package:raja/l10n/generated/app_localizations.dart';

/// Whether [item] came from a Vega provider: Vega items carry the
/// provider's package name (`vega.<value>`) in [MultimediaItem.provider].
bool isVegaDetailsItem(MultimediaItem item) =>
    item.provider?.startsWith('vega.') ?? false;

/// The installed Vega provider for [item], or null when it is not
/// installed or is not a Vega provider.
VegaBasedProvider? vegaProviderFor(WidgetRef ref, MultimediaItem item) {
  final packageName = item.provider;
  if (packageName == null || !packageName.startsWith('vega.')) return null;
  final provider =
      ref.read(extensionManagerProvider.notifier).getProvider(packageName);
  return provider is VegaBasedProvider ? provider : null;
}

/// The row label for one Vega stream: the provider's own tag when it
/// gave one ("480p • MP4 • 310 MB"), else server + quality ("HubCloud
/// 1080p"), else the server alone. Never a value the provider did not
/// give: an adaptive stream with no tag reads as its server, not a
/// guessed quality.
String vegaStreamLabel(StreamResult stream) {
  final tag = stream.tag?.trim();
  if (tag != null && tag.isNotEmpty) return tag;
  final server = stream.source.trim();
  final quality = stream.quality;
  final qualityText =
      quality != null && quality > 0 ? '${quality}p' : '';
  if (server.isEmpty) return qualityText;
  if (qualityText.isEmpty || server.contains(qualityText)) return server;
  return '$server $qualityText';
}

/// The episode pill label: "Episode N", or the episode's own name when
/// it carries no number.
String vegaEpisodeLabel(AppLocalizations l10n, Episode episode) =>
    episode.episode > 0
        ? l10n.episodeWithNumber(episode.episode)
        : episode.name;

/// A Vega series' episodes as in the reference: a Resume pill when the
/// viewer is mid-episode, a season dropdown, a Find episode field with a
/// sort button, and one wide pill per episode with Play and Download.
///
/// Play on a pill is the episode's tap today (direct play); holding it
/// opens the links sheet for that episode; Download is the episode's
/// download path today.
class VegaSeriesEpisodesSection extends ConsumerStatefulWidget {
  const VegaSeriesEpisodesSection({
    super.key,
    required this.parentItem,
    required this.itemUrl,
  });

  final MultimediaItem parentItem;
  final String itemUrl;

  @override
  ConsumerState<VegaSeriesEpisodesSection> createState() =>
      _VegaSeriesEpisodesSectionState();
}

class _VegaSeriesEpisodesSectionState
    extends ConsumerState<VegaSeriesEpisodesSection> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// The selected stream's label for the season dropdown, loaded in the
  /// background for the target episode. Null until (or unless) the load
  /// lands: the label then stays the season alone, never a guessed
  /// quality.
  String? _qualitySuffix;
  String? _suffixFor;

  /// Episodes whose on-disk state has already been asked for, so the
  /// downloaded badge is not re-checked on every rebuild.
  final Set<String> _checkedDownloadKeys = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Best-effort background load of the target episode's streams, only
  /// to label the season dropdown. Never blocks the UI: a failed or
  /// empty load leaves the label at the season alone.
  void _maybeLoadQualitySuffix(DetailsState state) {
    final target = state.targetEpisode;
    if (target == null) return;
    final key = '${state.selectedSeason}:${target.url}';
    if (_suffixFor == key) return;
    _suffixFor = key;
    final provider = vegaProviderFor(ref, widget.parentItem);
    if (provider == null) return;
    unawaited(_loadSuffix(provider, target.url, key));
  }

  Future<void> _loadSuffix(
    VegaBasedProvider provider,
    String url,
    String key,
  ) async {
    List<StreamResult> streams;
    try {
      streams = await provider.loadStreams(url);
    } catch (_) {
      return;
    }
    if (!mounted || _suffixFor != key || streams.isEmpty) return;
    var best = streams.first;
    for (final s in streams) {
      final q = s.quality ?? -1;
      final bestQ = best.quality ?? -1;
      if (q > bestQ) best = s;
    }
    final suffix = vegaStreamLabel(best);
    if (suffix.isEmpty) return;
    if (mounted) setState(() => _qualitySuffix = suffix);
  }

  List<Episode> _visibleEpisodes(DetailsState state) {
    var episodes =
        state.seasonMap[state.selectedSeason] ?? const <Episode>[];
    if (!state.isAscending) episodes = episodes.reversed.toList();
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      episodes = episodes.where((e) {
        final number = e.episode > 0 ? e.episode.toString() : '';
        return number.contains(q) || e.name.toLowerCase().contains(q);
      }).toList();
    }
    return episodes;
  }

  void _playEpisode(Episode episode) {
    ref
        .read(detailsControllerProvider(widget.itemUrl).notifier)
        .handlePlayPress(context, widget.parentItem, specificEpisode: episode);
  }

  void _openEpisodeSheet(Episode episode, MultimediaItem details) {
    ref
        .read(detailsControllerProvider(widget.itemUrl).notifier)
        .openLinksSheet(context, details, specificEpisode: episode);
  }

  void _downloadEpisode(
    Episode episode,
    File? downloadedFile,
    bool isDownloading,
    MultimediaItem details,
  ) {
    if (downloadedFile != null) {
      DownloadManagementDialog.show(
        context,
        details,
        downloadedFile,
        episode: episode,
      );
    } else if (isDownloading) {
      DownloadProgressDialog.show(
        context,
        '${widget.parentItem.title} - ${episode.name}',
        episode.url,
      );
    } else {
      ref
          .read(downloadLauncherProvider)
          .launch(context, widget.parentItem, episodeUrl: episode.url);
    }
  }

  /// Asks once per episode whether a file is already on disk, so the
  /// pill's Download icon shows the downloaded state like the episode
  /// card does.
  void _checkDownloadedFiles(List<Episode> episodes) {
    if (episodes.any((e) => !_checkedDownloadKeys.contains(e.url))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final notifier = ref.read(downloadedFilesProvider.notifier);
        for (final episode in episodes) {
          if (_checkedDownloadKeys.add(episode.url)) {
            unawaited(
              notifier.checkFile(widget.parentItem, episode: episode),
            );
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(detailsControllerProvider(widget.itemUrl));
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final episodes = _visibleEpisodes(state);
    final seasons = state.seasonMap.keys.toList()..sort();
    final seasonNames = state.details.value?.seasonNames;
    final target = state.targetEpisode;
    _maybeLoadQualitySuffix(state);
    _checkDownloadedFiles(episodes);
    final details = state.details.value ?? widget.parentItem;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (target != null) _buildResumePill(context, target),
        if (seasons.isNotEmpty)
          _buildSeasonDropdown(
            context,
            seasons,
            seasonNames,
            state.selectedSeason,
          ),
        const SizedBox(height: 12),
        _buildFindRow(context, state.isAscending),
        const SizedBox(height: 12),
        if (episodes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              l10n.noEpisodesFound,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: episodes.length,
            itemBuilder: (context, index) =>
                _buildEpisodePill(context, episodes[index], details),
          ),
      ],
    );
  }

  /// The Resume pill: only when the target episode has a saved position
  /// past the first seconds. Tapping resumes that episode.
  Widget _buildResumePill(BuildContext context, Episode target) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final pos = ref.watch(historyRepositoryProvider).getEpisodePosition(
      target.url,
      mainUrl: widget.parentItem.url,
      season: target.season,
      episode: target.episode,
    );
    if (pos <= 5000) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _playEpisode(target),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.play_arrow_rounded,
                  size: 28,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.resume,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    Text(
                      vegaEpisodeLabel(l10n, target),
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The season picker: the season, plus the selected stream's label
  /// when the background load has landed for the target episode.
  Widget _buildSeasonDropdown(
    BuildContext context,
    List<int> seasons,
    List<SeasonName>? seasonNames,
    int selectedSeason,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    String labelFor(int season) {
      final base = seasonChipLabel(l10n, season, seasonNames);
      if (season == selectedSeason && _qualitySuffix != null) {
        return '$base • $_qualitySuffix';
      }
      return base;
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: DropdownButton<int>(
        value: selectedSeason,
        isExpanded: true,
        underline: const SizedBox(),
        icon: Icon(
          Icons.keyboard_arrow_down_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        style: theme.textTheme.bodyLarge,
        dropdownColor: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        selectedItemBuilder: (context) => [
          for (final s in seasons)
            Text(labelFor(s), overflow: TextOverflow.ellipsis),
        ],
        items: [
          for (final s in seasons)
            DropdownMenuItem(
              value: s,
              child: Text(
                seasonChipLabel(l10n, s, seasonNames),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (season) {
          if (season != null) {
            ref
                .read(detailsControllerProvider(widget.itemUrl).notifier)
                .setSeason(season);
          }
        },
      ),
    );
  }

  /// "Find episode" filters the pills below by number or name; the sort
  /// button flips the order, as the episode row's sort does.
  Widget _buildFindRow(BuildContext context, bool isAscending) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            onChanged: (q) => setState(() => _query = q),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: l10n.findEpisode,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainer,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => ref
                .read(detailsControllerProvider(widget.itemUrl).notifier)
                .toggleSort(),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                Icons.swap_vert_rounded,
                color: isAscending
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// One wide pill per episode: Play circle left, "Episode N" centre,
  /// Download right.
  Widget _buildEpisodePill(
    BuildContext context,
    Episode episode,
    MultimediaItem details,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isDownloading =
        ref.watch(activeDownloadsProvider).contains(episode.url);
    final downloadedFile = ref.watch(downloadedFilesProvider)[episode.url];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Material(
                color: theme.colorScheme.primary,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _playEpisode(episode),
                  onLongPress: () => _openEpisodeSheet(episode, details),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 24,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () => _playEpisode(episode),
                onLongPress: () => _openEpisodeSheet(episode, details),
                behavior: HitTestBehavior.opaque,
                child: Center(
                  child: Text(
                    vegaEpisodeLabel(l10n, episode),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                downloadedFile != null
                    ? Icons.download_done_sharp
                    : Icons.download_rounded,
              ),
              tooltip: l10n.download,
              onPressed: () => _downloadEpisode(
                episode,
                downloadedFile,
                isDownloading,
                details,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

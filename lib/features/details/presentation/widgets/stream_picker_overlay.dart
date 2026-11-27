/// Stremio-style stream picker overlay: the same resolved streams as the
/// All Sources sheet, presented as a full-screen picker over the title's
/// backdrop — provider chips, Play best, ranked rows — instead of the
/// sheet. Reached by tapping Play on the details page.
///
/// Data is the sheet's data, not a second resolver: the overlay subscribes
/// to the same merged resolve ([mergedSourceServiceProvider]) and ranks
/// with the same functions ([rankAddonStreams] with `byQuality: true`,
/// then [arrangeAddonSources]) as [AddonSourcesSheet], so the rows and
/// their order match the sheet. Playing a row (or Play best) calls the
/// same [playAddonLinks] the sheet calls, with the full playable list
/// riding along pick-first as the player's other sources.
///
/// Known gap vs the sheet (deliberate, first version): the sheet re-asks
/// add-ons whose bot check cleared after they answered ([SiteCheck]
/// reruns); the overlay resolves once and its refresh button re-asks with
/// `forceRefresh`. An add-on that only answers after a clearance shows in
/// the All Sources sheet (long-press Play) but not here.
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/addons/data/addon_repository.dart';
import '../../../../core/addons/data/addon_stream_service.dart';
import '../../../../core/addons/data/merged_source_service.dart';
import '../../../../core/addons/models/addon_stream_source.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/storage/settings_repository.dart';
import '../../../../core/utils/source_language.dart';
import '../../../../core/utils/stream_quality_sorter.dart';
import '../../../../core/widgets/app_snack_bar.dart';
import '../../../addons/presentation/addon_direct_play.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../../sources/domain/last_used_source.dart';
import '../../../sources/presentation/source_sheet_widgets.dart';

/// The overlay's sort: the sheet's ranking, or pure quality order.
enum _PickerSort { bestMatch, highestQuality }

/// The provider a stream belongs to, for the provider chips: the inner
/// provider the stream names (MovieBox, VegaMovies…) when it has one,
/// else the add-on itself. Mirrors the All Sources sheet.
String _providerOf(AddonStreamSource s) {
  final inner = s.providerName?.trim();
  if (inner != null && inner.isNotEmpty) return inner;
  return s.addonName.trim();
}

class StreamPickerOverlay extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final AddonStreamRequest request;
  final Episode? episode;

  /// Saved position in milliseconds (0 = none): the Resume pill shows
  /// only past 5 s, the same threshold the Play button uses.
  final int resumePositionMs;

  const StreamPickerOverlay({
    super.key,
    required this.item,
    required this.request,
    this.episode,
    this.resumePositionMs = 0,
  });

  static Future<void> open(
    BuildContext context, {
    required MultimediaItem item,
    required AddonStreamRequest request,
    Episode? episode,
    int resumePositionMs = 0,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StreamPickerOverlay(
          item: item,
          request: request,
          episode: episode,
          resumePositionMs: resumePositionMs,
        ),
      ),
    );
  }

  @override
  ConsumerState<StreamPickerOverlay> createState() =>
      _StreamPickerOverlayState();
}

class _StreamPickerOverlayState extends ConsumerState<StreamPickerOverlay> {
  StreamSubscription<AddonStreamProgress>? _sub;
  AddonStreamProgress _result = const AddonStreamProgress(isLoading: true);
  bool _disposed = false;

  /// The add-on / provider this title last played on, for the resume pill
  /// and for putting that source first — the sheet's "Last used".
  String? _lastUsedKey;

  /// The mobile-data limit in force, and the preferred source language:
  /// the sheet's ranking inputs, read the same way it reads them.
  int? _capHeight;
  SourceLanguage _language = SourceLanguage.off;

  /// Provider filter (null = All) and quality filter.
  String? _provider;
  SourceQualityFilter _quality = SourceQualityFilter.all;

  _PickerSort _sort = _PickerSort.bestMatch;

  /// Debrid conversion status while a picked torrent resolves.
  String? _debridStatus;

  bool get _isResuming => widget.resumePositionMs > 5000;

  @override
  void initState() {
    super.initState();
    final settings = _settingsOrNull();
    _lastUsedKey = settings == null
        ? null
        : readLastUsedSource(settings, widget.item.url);
    unawaited(_readCapAndLanguage());
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }

  SettingsRepository? _settingsOrNull() {
    try {
      return ref.read(settingsRepositoryProvider);
    } catch (_) {
      return null;
    }
  }

  Future<void> _readCapAndLanguage() async {
    try {
      final settings = await ref.read(playerSettingsProvider.future);
      final cap = await mobileDataCapInForce(settings);
      final height = qualityPreferenceHeight(cap);
      final language = settings.preferredSourceLanguage;
      if (_disposed || !mounted) return;
      if (height == _capHeight && language == _language) return;
      setState(() {
        _capHeight = height;
        _language = language;
      });
    } catch (_) {
      // No limit known is no limit applied.
    }
  }

  Future<void> _start({bool forceRefresh = false}) async {
    if (ref.read(addonRepositoryProvider).isLoading) {
      await ref.read(addonRepositoryProvider.notifier).load();
    }
    if (_disposed) return;
    setState(() => _result = const AddonStreamProgress(isLoading: true));
    await _sub?.cancel();
    final answers = ref
        .read(mergedSourceServiceProvider)
        .resolve(
          request: widget.request,
          forceRefresh: forceRefresh,
          personWaiting: true,
        );
    _sub = answers.listen((progress) {
      if (_disposed) return;
      setState(() => _result = _ranked(progress));
    });
  }

  /// The sheet's ranking of one progress: by quality, then score, with
  /// wrong-film suspects last — the same call the sheet makes, so the
  /// order matches it row for row.
  AddonStreamProgress _ranked(AddonStreamProgress progress) {
    final streams = rankAddonStreams(
      progress.streams,
      title: widget.request.title,
      year: widget.request.year,
      byQuality: true,
    );
    return AddonStreamProgress(
      streams: streams,
      statuses: progress.statuses,
      completedCount: progress.completedCount,
      totalCount: progress.totalCount,
      isLoading: progress.isLoading,
      error: progress.error,
    );
  }

  /// The sheet's filters: external links never list, then the provider
  /// chip and the quality filter.
  List<AddonStreamSource> get _filtered => _result.streams.where((s) {
    if (s.isExternal) return false;
    if (!_quality.matchesScore(s.qualityScore)) return false;
    if (_provider != null && _providerOf(s) != _provider) return false;
    return true;
  }).toList(growable: false);

  /// Best match is the sheet's final arrangement (last-used first, then
  /// the data-saver cap and the preferred language); Highest quality is
  /// the ranked list as-is, pure quality order.
  List<AddonStreamSource> get _visible {
    if (_sort == _PickerSort.highestQuality) return _filtered;
    return arrangeAddonSources(
      _filtered,
      lastUsedKey: _lastUsedKey,
      capHeight: _capHeight,
      language: _language,
    );
  }

  List<AddonStreamSource> get _playable =>
      _visible.where((s) => s.isPlayable).toList(growable: false);

  /// All playable streams before the provider / quality filters: the
  /// header's total.
  int get _totalPlayable => _result.streams
      .where((s) => !s.isExternal && s.isPlayable)
      .length;

  AddonStreamSource? get _best => _playable.firstOrNull;

  /// Provider chips: every provider the resolved streams name, "All"
  /// first. Labels come from all streams, not the filtered ones, so a
  /// chip never vanishes because another chip is selected.
  List<String> get _providerLabels => [
    'All',
    ...addonStreamProviderLabels(_result.streams),
  ];

  Future<void> _play(AddonStreamSource stream) async {
    // The picked row plays first and the rest of the visible playable
    // list rides along as the player's other sources, mirroring the
    // sheet's _play: the player gets the full list pick-first, so its
    // Sources tab lists them.
    final ordered = <AddonStreamSource>[
      stream,
      ..._playable.where((s) => s.dedupeKey != stream.dedupeKey),
    ];
    final played = await playAddonLinks(
      context,
      ref,
      item: widget.item,
      request: widget.request,
      links: ordered,
      selected: stream,
      episode: widget.episode,
      onStatus: (status) {
        if (mounted) setState(() => _debridStatus = status);
      },
      // The overlay goes before the player comes up.
      beforeLaunch: () => Navigator.of(context).pop(),
    );
    if (!played && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(content: const Text('This source has no playable link.')),
      );
    }
  }

  Future<void> _playBest() async {
    final best = _best;
    if (best == null) return;
    await _play(best);
  }

  /// Resume plays the source this title last played on when it is among
  /// the answers, else the best stream; the player continues from the
  /// saved position either way.
  Future<void> _playResume() async {
    final target = resumeSourceFor(_playable, _lastUsedKey) ?? _best;
    if (target == null) return;
    await _play(target);
  }

  /// The language a stream states outright (Hindi, Telugu, Tamil…), or
  /// null when it names none. Never a guess.
  SourceLanguage? _languageOf(AddonStreamSource stream) {
    final text = [
      stream.name,
      stream.title,
      stream.description,
      stream.filename,
    ].whereType<String>().join(' ');
    for (final language in SourceLanguage.values) {
      if (language == SourceLanguage.off) continue;
      if (textStatesLanguage(text, language)) return language;
    }
    return null;
  }

  String _rowTitle(AddonStreamSource stream) {
    final name = (stream.name ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isNotEmpty) return name;
    return stream.headline;
  }

  String _rowSubtitle(AddonStreamSource stream) {
    var subtitle = stream.subtitleLine;
    final name = (stream.name ?? '').trim();
    if (name.isNotEmpty && subtitle.startsWith(name)) {
      subtitle = subtitle
          .substring(name.length)
          .replaceFirst(RegExp(r'^\s*·\s*'), '')
          .trim();
    }
    return subtitle;
  }

  String _formatResume(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final mins = minutes % 60;
      return '$hours:${mins.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _openFilters() async {
    final picked = await showModalBottomSheet<SourceQualityFilter>(
      context: context,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Quality',
                  style: Theme.of(sheetContext).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in SourceQualityFilter.values)
                      if (option != SourceQualityFilter.auto)
                        SourceFilterChip(
                          text: option.label,
                          selected: _quality == option,
                          onSelected: (_) =>
                              Navigator.of(sheetContext).pop(option),
                          outline: cs.outline,
                        ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null && mounted) setState(() => _quality = picked);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final backdrop = widget.item.backdropImageUrl;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (backdrop.isNotEmpty)
            CachedNetworkImage(
              imageUrl: backdrop,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            ),
          // The backdrop shows through at the top; the list sits on black.
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x59000000),
                  Color(0xB3000000),
                  Color(0xF2000000),
                ],
                stops: [0.0, 0.35, 0.7],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _topBar(context),
                Expanded(child: _content(context, cs)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 16, 4),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.45),
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, ColorScheme cs) {
    final best = _best;
    final loading = _result.isLoading && _result.streams.isEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (_isResuming) _resumePill(),
        _providerRow(),
        if (best != null) ...[
          const SizedBox(height: 14),
          _playBestButton(context, cs, best),
        ],
        if (_debridStatus != null) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _debridStatus!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        _sortAndFiltersRow(context, cs),
        const SizedBox(height: 12),
        Text(
          '${_playable.length} OF $_totalPlayable STREAMS · ${_sort == _PickerSort.bestMatch ? 'BEST MATCH FIRST' : 'HIGHEST QUALITY FIRST'}',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 10),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_playable.isEmpty)
          _emptyState()
        else
          for (var i = 0; i < _playable.length; i++) ...[
            _streamRow(context, cs, _playable[i], isFirst: i == 0),
            const SizedBox(height: 10),
          ],
        if (_result.error != null) ...[
          const SizedBox(height: 8),
          Text(
            _result.error!,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }

  Widget _resumePill() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: () => unawaited(_playResume()),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
              ),
            ),
            child: Text(
              'Resume from ${_formatResume(widget.resumePositionMs)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _providerRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            tooltip: 'Refresh',
            onPressed: () => unawaited(_start(forceRefresh: true)),
          ),
          for (final label in _providerLabels)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SourceFilterChip(
                text: label,
                selected: (_provider == null && label == 'All') ||
                    _provider == label,
                onSelected: (_) => setState(() {
                  _provider = label == 'All' ? null : label;
                }),
                outline: Colors.white.withValues(alpha: 0.35),
              ),
            ),
        ],
      ),
    );
  }

  Widget _playBestButton(
    BuildContext context,
    ColorScheme cs,
    AddonStreamSource best,
  ) {
    final detail = best.isDirect
        ? '${best.qualityLabel} · Instant'
        : best.isTorrent
        ? '${best.qualityLabel} · Torrent'
        : best.qualityLabel;
    return InkWell(
      onTap: () => unawaited(_playBest()),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.22),
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                color: Colors.black.withValues(alpha: 0.87),
                size: 28,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Play best for this device',
                    style: TextStyle(
                      color: cs.onPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: TextStyle(
                      color: cs.onPrimary.withValues(alpha: 0.8),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sortAndFiltersRow(BuildContext context, ColorScheme cs) {
    final qualityActive = _quality != SourceQualityFilter.all;
    return Row(
      children: [
        PopupMenuButton<_PickerSort>(
          onSelected: (sort) {
            if (mounted) setState(() => _sort = sort);
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _PickerSort.bestMatch,
              child: Text('Best match'),
            ),
            PopupMenuItem(
              value: _PickerSort.highestQuality,
              child: Text('Highest quality'),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  _sort == _PickerSort.bestMatch
                      ? 'Best match'
                      : 'Highest quality',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: Colors.white,
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        InkWell(
          onTap: () => unawaited(_openFilters()),
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: qualityActive
                    ? cs.primary
                    : Colors.white.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.tune_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  qualityActive
                      ? 'Filters · ${_quality.label}'
                      : 'Filters',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Text(
            _result.isLoading
                ? 'Still looking for streams…'
                : 'No streams found for this title.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => unawaited(_start(forceRefresh: true)),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }

  Widget _streamRow(
    BuildContext context,
    ColorScheme cs,
    AddonStreamSource stream, {
    required bool isFirst,
  }) {
    final language = _languageOf(stream);
    final subtitle = _rowSubtitle(stream);
    return InkWell(
      onTap: () => unawaited(_play(stream)),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    _rowTitle(stream),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isFirst) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Best match',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: cs.onPrimary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                QualityBadge(resolution: stream.qualityLabel),
                if (language != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      language.label,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

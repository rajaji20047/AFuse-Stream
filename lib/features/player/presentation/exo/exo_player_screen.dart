/// ExoPlayer, via better_player_plus (Media3 on Android).
///
/// The third engine, alongside libmpv (the default) and libVLC. It plays
/// through the package's [BetterPlayerController] — no native Kotlin of our
/// own — and resolves and opens streams exactly like the other two screens:
/// the same [resolvePlayback], the same [playbackHeaders], the same startup
/// list, the same progress recording, the same engine switch.
///
/// What it does NOT do (v1): a network-buffer size mapping (the
/// settings' MB value has no ms equivalent in the package's buffering
/// configuration, so the package default runs), an auto-advance countdown
/// (the ended card offers Next and waits for the tap, where mpv counts
/// down), and a manual cast button (no cast feature exists in the app).
/// The fit button works through a Flutter wrapper, not the controller —
/// the configuration's fit is fixed at creation, so the wrapper owns
/// the shape (see [_fit]).
library;

import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../../core/providers/device_info_provider.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../../core/services/notification_service.dart';
import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../details/data/metadata_resolution_service.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/episode_navigator.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/skip_segments.dart';
import '../../domain/sleep_timer.dart';
import '../../domain/source_row_status.dart';
import '../../domain/stream_resolver.dart';
import '../../../skip/data/skip_service.dart';
import '../mpv/golden_drawer.dart';
import '../player_brightness.dart';
import '../player_platform_service.dart';
import '../vlc/chrome_visibility_controller.dart';
import '../vlc/ended_card.dart';
import '../vlc/player_rail.dart';
import '../vlc/player_startup_view.dart';
import '../vlc/transient_overlay.dart';
import '../widgets/engine_picker_sheet.dart';
import '../widgets/player_control_components.dart';
import '../widgets/player_stream_widgets.dart';
import '../widgets/resolve_diagnostic_text.dart';

/// The ExoPlayer screen: [BetterPlayer] with Fuse's own chrome on top.
///
/// The package's built-in controls are off
/// ([BetterPlayerControlsConfiguration.showControls] false) — the top bar,
/// the seek strip and the sheets are the same Fuse pieces the other
/// players use, so the viewer sees one player, not three.
class ExoPlayerScreen extends ConsumerStatefulWidget {
  const ExoPlayerScreen({
    required this.item,
    required this.videoUrl,
    this.episode,
    this.preloadedStreams,
    super.key,
  });

  /// The title being played — a film, or the series an episode belongs to.
  final MultimediaItem item;

  /// The route's token for the link to play: a plugin URL, a local path,
  /// or a torrent magnet.
  final String videoUrl;

  /// The episode being played, for series. Null for a film.
  final Episode? episode;

  /// Streams the route already resolved, handed to the engine switch so
  /// the next engine reopens on the playing source instead of resolving
  /// from scratch.
  final List<StreamResult>? preloadedStreams;

  @override
  ConsumerState<ExoPlayerScreen> createState() => _ExoPlayerScreenState();
}

enum _Stage { resolving, playing, failed }

/// Which axis a pan has committed to: undecided until the finger has
/// travelled 10 px, so a diagonal start never becomes two gestures.
enum _PanAxis { none, horizontal, vertical }

class _ExoPlayerScreenState extends ConsumerState<ExoPlayerScreen> {
  final PlayerPlatformService _platform = PlayerPlatformService();
  final GlobalKey _betterPlayerKey = GlobalKey();

  ProviderReader get _read => ref.read;

  _Stage _stage = _Stage.resolving;
  String? _error;
  bool _disposed = false;
  bool _leaving = false;
  bool _leavingForEngineSwitch = false;

  // -- the resolve -----------------------------------------------------------
  List<StreamResult> _streams = const [];
  List<ProbeOutcome?> _probes = const [];
  int _streamIndex = 0;
  int? _pickedIndex;
  final Set<int> _failedStreams = <int>{};
  bool _resolveDone = false;
  bool _startedPlaying = false;
  int _resolveToken = 0;
  Duration _openStart = Duration.zero;

  // -- the episode -----------------------------------------------------------
  Episode? _currentEpisode;
  String _currentVideoUrl = '';
  bool _advancing = false;

  // -- the controller --------------------------------------------------------
  BetterPlayerController? _controller;
  bool _videoListenerAttached = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _isPlaying = false;
  // The playing edge the wakelock follows (see [_syncWakelock]): only
  // a flip touches the platform lock, never a position tick.
  bool _wasPlaying = false;
  bool _isBuffering = false;
  bool _isLive = false;
  bool _inPip = false;
  int _openToken = 0;

  // -- the chrome (the same pieces the VLC screen uses) ----------------------
  // The chrome clock: visible on entry, gone 3 s into playback, back on
  // any poke. A sheet holds it up while it is open.
  late final ChromeVisibilityController _chrome;
  // The lock: when set, only the unlock chip shows.
  final ValueNotifier<bool> _locked = ValueNotifier<bool>(false);
  // The sleep timer (moon): the engine-agnostic domain timer, same as mpv.
  late final SleepTimer _sleepTimer;
  // The picture fit: the configuration's fit is fill, and this wrapper
  // owns the shape — contain letterboxes through an aspect box, cover
  // crops through a FittedBox, fill stretches to the screen. The
  // controller exposes no runtime fit change, so the fit never
  // re-creates it.
  BoxFit _fit = BoxFit.contain;
  Size? _videoSize;
  // A seek in flight: the bar shows the drag target, not the position.
  Duration? _seekPreview;
  // A seek the engine has not arrived at yet: the bar shows this, not the
  // engine's stale position, so the thumb never snaps back while a seek is
  // on its way (VLC's pendingSeekTarget, same rule). Cleared once the
  // engine arrives (within a second) or after five seconds, so a seek
  // that never lands cannot freeze the thumb.
  Duration? _pendingSeekTarget;
  DateTime? _pendingSeekTargetSetAt;
  // The subtitle on screen, by name — the sheet's checkmark. The package
  // exposes the list but not the selection, so the screen tracks it.
  String? _selectedSubtitleName;

  // -- gestures (the same single-recognizer layer VLC uses) -----------------
  // The pan anchor, the scale recognizer's axis, and the pinch state: one
  // recognizer owns the pan and the pinch together, so a drag can never
  // steal the first finger before a pinch starts.
  Offset? _panAnchor;
  double? _panAnchorLocalX;
  _PanAxis _panAxis = _PanAxis.none;
  bool _pinching = false;
  double _pinchStartScale = 1.0;
  // The pinch zoom, 0.5–3.0, applied to the video layer.
  final ValueNotifier<double> _videoScale = ValueNotifier<double>(1.0);
  // The vertical rail: which level a swipe is driving, and its start.
  bool? _dragIsVolume;
  bool _dragIsSeek = false;
  bool _dragReady = false;
  double _dragPending = 0;
  double _dragStart = 0;
  int _dragId = 0;
  // The horizontal swipe-seek's origin and target.
  double? _horizontalDragStartX;
  Duration? _horizontalDragStartPosition;
  Duration? _horizontalDragTarget;
  // The long-press speed boost's saved speed.
  double? _speedBeforeBoost;
  // The toast and the rail, rendered by TransientOverlay so a write at
  // pointer rate rebuilds one overlay and nothing else.
  final TransientValue<String> _toast = TransientValue<String>();
  final TransientValue<PlayerRail> _rail = TransientValue<PlayerRail>();
  final TransientValue<SeekBurst> _seekBurst = TransientValue<SeekBurst>();
  int _seekBurstRevision = 0;
  // The screen brightness, mirrored from the last read. The app's
  // brightness is a process-wide override, so leaving the player gives
  // it back.
  double _brightness = 0.5;
  bool _brightnessOverridden = false;
  late final PlayerBrightness _brightnessControl =
      PlatformPlayerBrightness();
  // The engine volume, 0..1, mirrored here: the package caps setVolume
  // at 1.0, so there is no boost past 100% the way mpv/VLC offer it.
  double _volume = 1.0;

  // -- progress --------------------------------------------------------------
  PlaybackTracker? _tracker;
  PlaybackProgressRecorder? _recorder;
  ProgressSample? _sample;
  int _sessionToken = 0;

  // -- skip segments ---------------------------------------------------------
  // The bands the viewer can jump over (IntroDB/AniSkip crowd answer, or
  // the playing source's own intervals). Manual, like the other players:
  // a Skip button offers the jump while inside a band; nothing jumps
  // unasked.
  List<SkipSegment> _skipSegments = const [];
  List<SkipSegment> _crowdSkipSegments = const [];
  String? _skipSegmentsStreamUrl;

  // -- ended -----------------------------------------------------------------
  EndedKind? _ended;

  StreamResult? get _selected =>
      _streams.isEmpty ? null : _streams[_streamIndex];

  /// What the seek bar shows: the drag target, then a seek the engine has
  /// not arrived at, then the engine's own position — so the thumb never
  /// snaps back to the old place while a seek is on its way.
  Duration get _displayPosition =>
      _seekPreview ?? _pendingSeekTarget ?? _position;

  bool get _isSeries =>
      widget.item.contentType == MultimediaContentType.series;

  /// "S1 E3 · Episode name", for the startup list.
  String? get _episodeLine {
    final episode = _currentEpisode;
    if (!_isSeries || episode == null) return null;
    return 'S${episode.season} E${episode.episode} · ${episode.name}';
  }

  bool get _hasNextEpisode =>
      nextEpisodeFor(
        item: widget.item,
        current: _currentEpisode,
        videoUrl: _currentVideoUrl,
      ).next !=
      null;

  Episode? get _previousEpisode => previousEpisodeFor(
    item: widget.item,
    current: _currentEpisode,
    videoUrl: _currentVideoUrl,
  );

  /// The startup list's current row: the one being opened, or null while
  /// the probe race is still running.
  int? get _startupCurrentIndex {
    if (_streams.isEmpty) return null;
    if (!_resolveDone && _pickedIndex == null) return null;
    return _streamIndex;
  }

  /// The startup list's rows, in the original's own terms — the same
  /// helpers the mpv screen feeds its list with.
  List<StartupRow> get _startupRows {
    return <StartupRow>[
      for (var i = 0; i < _streams.length; i++)
        StartupRow(
          label: _startupRowLabel(_streams[i]),
          server: sourceServer(_streams[i]),
          quality: sourceQualityLabel(_streams[i]),
          size: sourceSizeLabel(_streams[i]),
          reachability: sourceReachabilityOf(
            _streams[i],
            _probes[i],
            hasPlayed: _startedPlaying && i == _streamIndex,
          ),
          playState: sourcePlayStateOf(
            isCurrent: i == _streamIndex && (_resolveDone || _pickedIndex == i),
            hasPicture: _startedPlaying,
            failed: _failedStreams.contains(i),
          ),
        ),
    ];
  }

  /// The plugin's own label for the source, led by its provider, with the
  /// quality after it — "HubCloud · 1080p".
  String _startupRowLabel(StreamResult stream) {
    final base = sourceRowLabel(stream);
    final quality = stream.quality;
    return quality != null && quality > 0 ? '$base · ${quality}p' : base;
  }

  @override
  void initState() {
    super.initState();
    PlayerPlatformService.notePlayerEntry();
    _currentEpisode = widget.episode;
    _currentVideoUrl = widget.videoUrl;
    _isLive = widget.item.contentType == MultimediaContentType.livestream;
    // Immersive, like the other players: the system bars stay hidden
    // while the video is up.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Held for startup, then handed to playback (see [_syncWakelock]):
    // resolving can take minutes with nothing playing yet, and a screen
    // that sleeps through it never gets to the video. VLC takes the
    // lock the same way; the package's allowedScreenSleep flag does not
    // — it only enables the lock inside the package's own fullscreen
    // route, which Fuse never pushes.
    unawaited(WakelockPlus.enable());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _pinLandscape();
    });
    _platform.startRotationSensor();
    _attachPip();
    _chrome = ChromeVisibilityController(isPlaying: () => _isPlaying);
    _sleepTimer = SleepTimer()..onFire = _onSleepTimerFired;
    unawaited(_resolveAndOpen());
  }

  @override
  void dispose() {
    _disposed = true;
    _chrome.dispose();
    _sleepTimer.dispose();
    _locked.dispose();
    _toast.dispose();
    _rail.dispose();
    _seekBurst.dispose();
    _videoScale.dispose();
    // The brightness override is process-wide: leaving gives it back.
    if (_brightnessOverridden) _brightnessControl.reset();
    _flushProgress();
    try {
      _tracker?.finish();
    } catch (_) {}
    _platform.detachPipListener();
    _platform.stopRotationSensor();
    _disposeController();
    // The screen is gone: the display may sleep again. An engine switch
    // disables here and the new engine takes the lock in its own init.
    unawaited(WakelockPlus.disable());
    // An engine switch hands the new player the landscape pin (see
    // [_restoreOrientation]): only a real exit gives the pin back.
    if (!_leavingForEngineSwitch) _restoreOrientation();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _disposeController() {
    final controller = _controller;
    _controller = null;
    _videoListenerAttached = false;
    if (controller == null) return;
    try {
      controller.videoPlayerController?.removeListener(_onVideoValue);
    } catch (_) {}
    // autoDispose is true (the default), so dispose() releases the
    // video controller underneath.
    controller.dispose();
  }

  // -- orientation -----------------------------------------------------------

  /// Pins the landscape pair at entry, exactly as the other players do:
  /// unconditionally, so entering in landscape still pins a side (the
  /// pair set when already landscape is a no-op visually), and the
  /// rotation sensor then flips between the two sides.
  void _pinLandscape() {
    final profile = ref.read(deviceProfileProvider).asData?.value;
    final form = playerFormFactorOf(profile);
    if (form == PlayerFormFactor.tv) return;
    _platform.pinOrientation(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _restoreOrientation() {
    if (_leavingForEngineSwitch) return;
    _platform.restoreOrientation();
  }

  /// Flips the handset the other way for the rest of this video (rotate
  /// button). As the VLC player does: the platform service owns the flip,
  /// so it reads the real orientation and toggles landscape <-> portrait.
  void _flipOrientation() {
    final profile = ref.read(deviceProfileProvider).asData?.value;
    _platform.flipOrientation(playerFormFactorOf(profile));
  }

  // -- resolve + open --------------------------------------------------------

  /// Resolves the links, then opens the first one — the same call the
  /// other players make, with the same 30 s timeout and the same
  /// cancellation token, so a resolve still running cannot overrule a
  /// pick the viewer made in the startup list.
  Future<void> _resolveAndOpen() async {
    final token = ++_resolveToken;
    if (_disposed) return;
    setState(() {
      _stage = _Stage.resolving;
      _error = null;
      _resolveDone = false;
    });
    final resume = resumePointFor(
      read: _read,
      item: widget.item,
      episode: _currentEpisode,
      videoUrl: _currentVideoUrl,
    );
    _openStart = resume?.position ?? Duration.zero;
    try {
      final resolved = await resolvePlayback(
        read: _read,
        item: widget.item,
        videoUrl: _currentVideoUrl,
        preloadedStreams: widget.preloadedStreams,
        isCancelled: () => _disposed || token != _resolveToken,
        onCandidates: (streams) {
          if (_disposed || token != _resolveToken) return;
          setState(() {
            _streams = streams;
            _probes = List<ProbeOutcome?>.filled(streams.length, null);
          });
        },
        onProbe: (index, outcome) {
          if (_disposed || token != _resolveToken) return;
          setState(() {
            if (index < _probes.length) _probes[index] = outcome;
          });
        },
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          'Timed out while fetching links',
        ),
      );
      if (_disposed || token != _resolveToken) return;
      _streams = resolved.streams;
      _streamIndex = resolved.index;
      _resolveDone = true;
      // The tracker and recorder ride one session token, so a sample
      // from a stale open is discarded rather than written.
      _tracker = PlaybackTracker(
        read: _read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: ++_sessionToken,
      );
      _recorder = PlaybackProgressRecorder(
        read: _read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: _sessionToken,
      );
      unawaited(_loadSkipSegments(_currentEpisode));
      if (mounted) setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (_disposed || token != _resolveToken) return;
      unawaited(_openStream(_streamIndex, start: _openStart));
    } on StreamResolutionException catch (failure) {
      if (_disposed || token != _resolveToken) return;
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _stage = _Stage.failed;
        _error = describeStreamFailure(l10n, failure);
      });
    } on TimeoutException catch (e) {
      if (_disposed || token != _resolveToken) return;
      setState(() {
        _stage = _Stage.failed;
        _error = e.message;
      });
    } catch (e) {
      if (_disposed || token != _resolveToken) return;
      setState(() {
        _stage = _Stage.failed;
        _error = e.toString();
      });
    }
  }

  /// Opens [index] in a fresh controller, at [start].
  ///
  /// The old controller is disposed first — one video at a time — and the
  /// open is guarded by [_openToken], so a failover that lands while an
  /// open is still in flight does not open the same source twice.
  Future<void> _openStream(int index, {Duration start = Duration.zero}) async {
    if (_disposed || _streams.isEmpty) return;
    if (index < 0 || index >= _streams.length) return;
    final token = ++_openToken;
    // A new open is a new session: stale progress samples are discarded.
    _sessionToken++;
    _streamIndex = index;
    _position = start;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _isPlaying = false;
    _wasPlaying = false;
    _isBuffering = false;
    _ended = null;
    // A new source has not played yet: the spinner shows until its first
    // frame, and any pending seek from the old source is dropped.
    _startedPlaying = false;
    _pendingSeekTarget = null;
    _pendingSeekTargetSetAt = null;
    _disposeController();
    // Every open keeps the display on until playback decides — the
    // config's autoPlay is always true here, so every open plays.
    // (VLC: autoPlay ? enable : disable.)
    unawaited(WakelockPlus.enable());
    final stream = _streams[index];
    final settings =
        ref.read(playerSettingsProvider).value ?? const PlayerSettings();
    _applyVegaSkipSegments(stream.url);
    final controller = BetterPlayerController(
      BetterPlayerConfiguration(
        autoPlay: true,
        // Fill: the wrapper below owns the shape (see [_fit]). The
        // package's own fit is fixed at controller creation, so a
        // runtime fit change must live in Flutter, not in the config.
        fit: BoxFit.fill,
        // The screen must stay awake while the video plays — but this
        // flag alone does not hold it: better_player_plus only enables
        // the wakelock inside its own fullscreen route, which Fuse never
        // pushes (fullscreen is managed here). The screen holds the lock
        // directly with WakelockPlus, mirroring VLC (see [_syncWakelock]).
        allowedScreenSleep: false,
        startAt: start > Duration.zero ? start : null,
        // Fuse draws its own chrome; the package's controls stay off.
        controlsConfiguration: const BetterPlayerControlsConfiguration(
          showControls: false,
        ),
        eventListener: _onBetterPlayerEvent,
      ),
      betterPlayerDataSource: _buildDataSource(stream, settings),
    );
    if (_disposed || token != _openToken) {
      controller.dispose();
      return;
    }
    _controller = controller;
    _chrome.poke();
    setState(() {
      _stage = _Stage.playing;
    });
  }

  /// The data source for [stream]: the same headers the probe and the
  /// other players open with — provider headers, stored clearance
  /// cookies and the browser UA — so a Vega file-host link keeps the
  /// same client identity it was probed with (the 60af065 lesson).
  BetterPlayerDataSource _buildDataSource(
    StreamResult stream,
    PlayerSettings settings,
  ) {
    final subtitles = _subtitleSources(stream, settings);
    String? selectedName;
    for (final source in subtitles) {
      if (source.selectedByDefault == true) {
        selectedName = source.name;
        break;
      }
    }
    _selectedSubtitleName = selectedName;
    return BetterPlayerDataSource.network(
      stream.url,
      headers: playbackHeaders(stream),
      subtitles: subtitles,
      // The network() factory leaves these null (== false) unless they
      // are passed: without them the HLS/DASH track lists stay empty and
      // the Quality / Audio sheets have nothing to show.
      useAsmsTracks: true,
      useAsmsAudioTracks: true,
      useAsmsSubtitles: true,
      liveStream: _isLive,
      videoFormat: _videoFormatFor(stream.url),
      drmConfiguration: _drmFor(stream),
    );
  }

  /// The format hint, from the URL's own extension — the package detects
  /// it itself when the URL carries none.
  BetterPlayerVideoFormat? _videoFormatFor(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8')) return BetterPlayerVideoFormat.hls;
    if (lower.contains('.mpd')) return BetterPlayerVideoFormat.dash;
    if (lower.contains('.ism')) return BetterPlayerVideoFormat.ss;
    return null;
  }

  /// Widevine from [StreamResult.licenseUrl], ClearKey from
  /// [StreamResult.drmKid]/[StreamResult.drmKey]. The ClearKey JSON is
  /// built by the package's own util (both values hex, as the bridge
  /// stores them); a non-hex pair is not a crash — the config is dropped
  /// and the open fails over like any other undecryptable source.
  BetterPlayerDrmConfiguration? _drmFor(StreamResult stream) {
    final licenseUrl = stream.licenseUrl;
    if (licenseUrl != null && licenseUrl.isNotEmpty) {
      return BetterPlayerDrmConfiguration(
        drmType: BetterPlayerDrmType.widevine,
        licenseUrl: licenseUrl,
        // The license request carries the same identity as the stream.
        headers: playbackHeaders(stream),
      );
    }
    final kid = stream.drmKid;
    final key = stream.drmKey;
    if (kid != null && kid.isNotEmpty && key != null && key.isNotEmpty) {
      try {
        return BetterPlayerDrmConfiguration(
          drmType: BetterPlayerDrmType.clearKey,
          clearKey: BetterPlayerClearKeyUtils.generateKey({kid: key}),
        );
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// The stream's external subtitles as package sources. OFF by default
  /// (the standing rule): with [SubtitleDefault.off] nothing is
  /// pre-selected and the viewer picks from the Subtitles sheet; with
  /// auto, the first track in the viewer's language is pre-selected.
  List<BetterPlayerSubtitlesSource> _subtitleSources(
    StreamResult stream,
    PlayerSettings settings,
  ) {
    final files = stream.subtitles;
    if (files == null || files.isEmpty) return const [];
    final auto = settings.subtitleDefault == SubtitleDefault.auto;
    final preferred = settings.preferredAudioLanguage.toLowerCase();
    var picked = false;
    return files.map((file) {
      var selected = false;
      if (auto && !picked) {
        final lang = (file.lang ?? '').toLowerCase();
        if (preferred.isEmpty || lang.startsWith(preferred)) {
          selected = true;
          picked = true;
        }
      }
      return BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.network,
        name: file.label,
        urls: [file.url],
        selectedByDefault: selected,
      );
    }).toList(growable: false);
  }

  /// A row picked on the startup list, before anything is playing: open
  /// that source instead of the one the auto-open chose. The list stays
  /// up until the picked source plays, so a pick that fails falls over
  /// to the next one the same way.
  void _pickFromStartup(int index) {
    if (_disposed || index < 0 || index >= _streams.length) return;
    if (index == _streamIndex && !_startedPlaying) return;
    _pickedIndex = index;
    var start = _position;
    if (start <= Duration.zero && !_startedPlaying) {
      final resume = resumePointFor(
        read: _read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
      );
      start = resume?.position ?? Duration.zero;
    }
    unawaited(_openStream(index, start: start));
  }

  /// The next untried source after a failure, near where the viewer was
  /// rather than from the top; every source tried is the failed stage.
  void _tryNextStream() {
    if (_disposed) return;
    final next = _streamIndex + 1;
    if (next >= _streams.length) {
      setState(() {
        _stage = _Stage.failed;
        _error = 'No working source found.';
      });
      return;
    }
    final resumeAt = _position > const Duration(seconds: 5)
        ? _position
        : _openStart;
    unawaited(_openStream(next, start: resumeAt));
  }

  /// A row picked in the Sources sheet while playing: reopen on that
  /// source, keeping the position.
  void _pickSource(int index) {
    if (_disposed || index < 0 || index >= _streams.length) return;
    if (index == _streamIndex) return;
    unawaited(_openStream(index, start: _position));
  }

  // -- playback events -------------------------------------------------------

  /// The package's event stream, delivered through the configuration's
  /// [BetterPlayerConfiguration.eventListener]. There is no `eventStream`
  /// on the controller — this is the delivery mechanism.
  void _onBetterPlayerEvent(BetterPlayerEvent event) {
    if (_disposed) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.initialized:
        _attachVideoListener();
        _applyAudioAutoSelect();
        if (mounted) setState(() {});
      case BetterPlayerEventType.play:
        if (!_isPlaying) setState(() => _isPlaying = true);
      case BetterPlayerEventType.pause:
        if (_isPlaying) {
          setState(() => _isPlaying = false);
          _flushProgress();
        }
      case BetterPlayerEventType.bufferingStart:
        if (!_isBuffering) setState(() => _isBuffering = true);
      case BetterPlayerEventType.bufferingEnd:
        if (_isBuffering) setState(() => _isBuffering = false);
      case BetterPlayerEventType.finished:
        _onEnded();
      case BetterPlayerEventType.exception:
        // The open failed (a dead link, an undecryptable DRM stream):
        // fail over to the next source rather than stranding the viewer.
        // Guarded by the failed set so one bad source fails over once.
        if (!_failedStreams.contains(_streamIndex)) {
          _failedStreams.add(_streamIndex);
          _tryNextStream();
        }
      case BetterPlayerEventType.pipStart:
        if (!_inPip) setState(() => _inPip = true);
      case BetterPlayerEventType.pipStop:
        if (_inPip) setState(() => _inPip = false);
      case BetterPlayerEventType.changedTrack:
      case BetterPlayerEventType.changedSubtitles:
        // The track lists changed under the sheets: repaint them.
        if (mounted) setState(() {});
      default:
        break;
    }
  }

  void _attachVideoListener() {
    final vc = _controller?.videoPlayerController;
    if (vc == null || _videoListenerAttached) return;
    _videoListenerAttached = true;
    vc.addListener(_onVideoValue);
  }

  /// The video's own value, on every tick: position, duration, buffered
  /// range, playing and buffering. Feeds the tracker and the recorder.
  void _onVideoValue() {
    if (_disposed || !mounted) return;
    final value = _controller?.videoPlayerController?.value;
    if (value == null) return;
    final wasPlaying = _isPlaying;
    _position = value.position;
    if (value.duration != null) _duration = value.duration!;
    _buffered = value.buffered.isEmpty
        ? Duration.zero
        : value.buffered.last.end;
    _isPlaying = value.isPlaying;
    _isBuffering = value.isBuffering;
    if (value.size != null) _videoSize = value.size;
    // The pending seek target clears once the engine arrives (within a
    // second) or after five seconds, so a seek that never lands cannot
    // freeze the thumb.
    final pending = _pendingSeekTarget;
    if (pending != null) {
      final converged =
          (_position - pending).abs() <= const Duration(seconds: 1);
      final stale =
          _pendingSeekTargetSetAt != null &&
          DateTime.now().difference(_pendingSeekTargetSetAt!) >
              const Duration(seconds: 5);
      if (converged || stale) {
        _pendingSeekTarget = null;
        _pendingSeekTargetSetAt = null;
      }
    }
    if (_isPlaying && !_startedPlaying) _startedPlaying = true;
    _syncWakelock();
    if (_isPlaying) {
      final sample = ProgressSample(
        position: _position,
        duration: _duration,
        token: _sessionToken,
      );
      _sample = sample;
      _tracker?.onPlaying(sample);
      _recorder?.record(sample, lastStreamUrl: _selected?.url);
    } else if (wasPlaying) {
      _tracker?.onPaused();
      _flushProgress();
    }
    if (mounted) setState(() {});
  }

  /// Fans the playing/not-playing edge out to the wakelock — VLC's
  /// `_syncPlayingState` in miniature, same rule.
  ///
  /// Only on the flip: the wakelock is a platform call with no business
  /// running on every position tick. The lock follows playback rather
  /// than the screen's lifetime, so a player parked on pause lets the
  /// display sleep.
  ///
  /// Only a real stop releases the screen. The engine also reports
  /// not-playing across every setMedia — failover, the next episode —
  /// and a reopen can take minutes; dropping the lock there is exactly
  /// the case initState took it out for. [_startedPlaying] is false
  /// until the first frame, so a not-playing edge before it keeps the
  /// lock.
  void _syncWakelock() {
    if (_isPlaying == _wasPlaying) return;
    _wasPlaying = _isPlaying;
    unawaited(
      _isPlaying
          ? WakelockPlus.enable()
          : (_startedPlaying
                ? WakelockPlus.disable()
                : Future<void>.value()),
    );
  }

  /// Writes the last known-good sample, bypassing the rate limit.
  void _flushProgress() {
    final sample = _sample;
    final recorder = _recorder;
    if (sample == null || recorder == null) return;
    recorder.record(sample, lastStreamUrl: _selected?.url, force: true);
  }

  // -- skip segments ---------------------------------------------------------

  /// The crowd answer for this episode (IntroDB/AniSkip), then the
  /// playing source's own intervals outrank it (see
  /// [_applyVegaSkipSegments]). Background only, never awaited by the
  /// open path.
  Future<void> _loadSkipSegments(Episode? episode) async {
    if (episode == null) return;
    var item = widget.item;
    if (item.imdbId == null) {
      try {
        item = await ref
            .read(metadataResolutionServiceProvider)
            .enrichWithIds(item);
      } catch (_) {
        // Keep the original item.
      }
    }
    final segments = await fetchSkipSegments(
      read: _read,
      item: item,
      episode: episode,
    );
    if (_disposed) return;
    _crowdSkipSegments = segments;
    setState(() {
      if (!_applyVegaSkipSegments(_selected?.url)) {
        if (segments.isNotEmpty) _skipSegments = segments;
      }
    });
  }

  /// The playing source's own intervals outrank the crowd; a source that
  /// reports none keeps the crowd answer. Returns true when a Vega answer
  /// was applied.
  bool _applyVegaSkipSegments(String? streamUrl) {
    if (streamUrl == null) return false;
    if (_skipSegmentsStreamUrl == streamUrl) return _skipSegments.isNotEmpty;
    _skipSegmentsStreamUrl = streamUrl;
    final segments = vegaSkipSegments(
      read: _read,
      streamUrl: streamUrl,
      durationSeconds: _duration.inMilliseconds / 1000.0,
    );
    if (segments.isNotEmpty) {
      _skipSegments = segments;
      return true;
    }
    return false;
  }

  /// The band covering the position, if any — the Skip button's target.
  SkipSegment? get _currentSkipSegment {
    if (_skipSegments.isEmpty || _isLive) return null;
    return segmentAt(_skipSegments, _position);
  }

  // -- ended / episodes ------------------------------------------------------

  void _onEnded() {
    if (_disposed) return;
    _flushProgress();
    try {
      _tracker?.finish();
    } catch (_) {}
    // The sleep timer forbids offering the next episode for this ending.
    if (_sleepTimer.consumeEpisodeEnd()) {
      _showEnded(EndedKind.finished);
      return;
    }
    // v1: no auto-advance countdown — the ended card offers Next, and
    // the viewer taps it. (mpv counts down; Exo waits for the tap.)
    _showEnded(_hasNextEpisode ? EndedKind.declinedNext : EndedKind.finished);
  }

  void _showEnded(EndedKind kind) {
    if (_disposed || !mounted || _ended == kind) return;
    // The card unmounts the whole controls subtree, and the unlock chip
    // goes with it, so a lock left standing here would have nothing on
    // screen to undo it.
    _locked.value = false;
    setState(() => _ended = kind);
  }

  /// Plays the finished media again, from the top.
  void _startOver() {
    if (_disposed) return;
    _sample = null;
    _sleepTimer.noteResumed();
    unawaited(_openStream(_streamIndex, start: Duration.zero));
  }

  /// The next episode, or the previous one, from the chrome's arrows.
  Future<void> _advance() async {
    if (_disposed || _advancing) return;
    final next = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    ).next;
    if (next == null) return;
    await _pickEpisode(next);
  }

  Future<void> _goToPreviousEpisode() async {
    if (_disposed || _advancing) return;
    final previous = _previousEpisode;
    if (previous == null) return;
    await _pickEpisode(previous);
  }

  Future<void> _pickEpisode(Episode next) async {
    if (_disposed || _advancing || next == _currentEpisode) return;
    _advancing = true;
    try {
      _flushProgress();
      try {
        _tracker?.finish();
      } catch (_) {}
      rollForwardHistory(read: _read, item: widget.item, next: next);
      await _startEpisode(next);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _startEpisode(Episode next) async {
    // A resolve or an open still in flight for the old episode is stale
    // from here on (see [_resolveToken]).
    _resolveToken++;
    _currentEpisode = next;
    _currentVideoUrl = next.url;
    _sample = null;
    _streams = const [];
    _streamIndex = 0;
    _failedStreams.clear();
    _probes = const [];
    _pickedIndex = null;
    _resolveDone = false;
    _startedPlaying = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _openStart = Duration.zero;
    _tracker = null;
    _recorder = null;
    _skipSegments = const <SkipSegment>[];
    _crowdSkipSegments = const <SkipSegment>[];
    _skipSegmentsStreamUrl = null;
    _ended = null;
    _disposeController();
    await _resolveAndOpen();
  }

  // -- back / engine switch --------------------------------------------------

  void _goBack() {
    if (_leaving) return;
    _leaving = true;
    _flushProgress();
    _disposeController();
    _restoreOrientation();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _switchEngine(PlayerEngine target) async {
    await ref.read(playerSettingsProvider.notifier).setPlayerEngine(target);
    if (!mounted) return;
    // The dispose that follows this replacement must not release the
    // new player's landscape pin (see [_restoreOrientation]).
    _leavingForEngineSwitch = true;
    PlayerRoute(
      $extra: PlayerRouteExtra(
        item: widget.item,
        videoUrl: _currentVideoUrl,
        episode: _currentEpisode,
        // The playing source rides first: the resolver treats a
        // handed-in list as already ranked and probes from its head, so
        // an unrotated list reopens on source #1 instead of the source
        // that was playing.
        preloadedStreams: _streams.isEmpty
            ? null
            : rotateStreamToFirst(_streams, _streamIndex),
      ),
    ).pushReplacement(context);
  }

  /// The top-row switch button opens the engine picker; picking the engine
  /// already playing is a no-op, so the video is never reopened for
  /// nothing.
  Future<void> _showEnginePicker() async {
    final current =
        ref.read(playerSettingsProvider).value?.playerEngine ??
        PlayerEngine.mpv;
    final picked = await showEnginePickerSheet(context, current);
    if (!mounted || picked == null || picked == current) return;
    await _switchEngine(picked);
  }

  // -- PiP -------------------------------------------------------------------

  /// Routes the PiP window's transport buttons and mode changes back to
  /// the screen (Android only; the channel is inert elsewhere).
  ///
  /// The handler is keyed by channel name, so it is process-wide — a
  /// second call replaces the first. Detached in [dispose].
  void _attachPip() {
    _platform.attachPipListener(
      onAction: (action) => switch (action) {
        PipAction.play => unawaited(_togglePlay(force: true)),
        PipAction.pause => unawaited(_togglePlay(force: false)),
        PipAction.seekForward =>
          _seekRelative(PlayerPlatformService.pipSeekStep),
        PipAction.seekBackward =>
          _seekRelative(-PlayerPlatformService.pipSeekStep),
      },
      onModeChanged: (inPip) {
        if (!mounted || _disposed) return;
        if (inPip == _inPip) return;
        setState(() => _inPip = inPip);
      },
    );
  }

  /// Enters the Android PiP window through the package's own PiP — the
  /// window belongs to the BetterPlayer view, so the package's call is
  /// the one that opens it. The chrome comes off optimistically in the
  /// same frame the request is made; the `pipStart` event (or the mode
  /// change) confirms it.
  Future<void> _enterPip() async {
    // The package's PiP call is the same on both platforms: iOS rides
    // the system's own path behind the package's controller.
    final controller = _controller;
    if (controller == null) return;
    try {
      final supported = await controller.isPictureInPictureSupported();
      if (!supported) return;
    } catch (_) {
      return;
    }
    if (_disposed || !mounted) return;
    setState(() => _inPip = true);
    // enablePictureInPicture returns a nullable future: null when the
    // platform has no PiP to enter.
    final pipFuture = controller.enablePictureInPicture(_betterPlayerKey);
    if (pipFuture != null) unawaited(pipFuture);
  }

  // -- transport -------------------------------------------------------------

  Future<void> _togglePlay({bool? force}) async {
    final controller = _controller;
    if (controller == null) return;
    final wantPlay = force ?? !_isPlaying;
    if (wantPlay) {
      _sleepTimer.noteResumed();
      await controller.play();
    } else {
      await controller.pause();
    }
  }

  Future<void> _seekTo(Duration target) async {
    final controller = _controller;
    if (controller == null) return;
    final clamped = target.isNegative
        ? Duration.zero
        : (_duration > Duration.zero && target > _duration
              ? _duration
              : target);
    // The thumb rides the target until the engine arrives there (see
    // [_displayPosition]).
    _pendingSeekTarget = clamped;
    _pendingSeekTargetSetAt = DateTime.now();
    await controller.seekTo(clamped);
  }

  void _seekRelative(Duration delta) {
    unawaited(_seekTo(_position + delta));
  }

  /// Cycles contain → cover → fill. The wrapper owns the shape (see
  /// [_fit]), so this never re-creates the controller.
  void _cycleFit() {
    setState(() {
      _fit = switch (_fit) {
        BoxFit.contain => BoxFit.cover,
        BoxFit.cover => BoxFit.fill,
        _ => BoxFit.contain,
      };
    });
  }

  // -- audio / sleep ---------------------------------------------------------

  /// The viewer's preferred audio language, applied once the track list
  /// lands — the same rescue the other players do, in miniature: a
  /// stream that opens on the wrong language is switched, not left.
  void _applyAudioAutoSelect() {
    final controller = _controller;
    if (controller == null) return;
    final preferred = (ref.read(playerSettingsProvider).value ??
            const PlayerSettings())
        .preferredAudioLanguage;
    if (preferred.isEmpty) return;
    final tracks = controller.betterPlayerAsmsAudioTracks;
    if (tracks == null || tracks.isEmpty) return;
    final current = controller.betterPlayerAsmsAudioTrack;
    if (current != null &&
        (current.language ?? '').toLowerCase().startsWith(
          preferred.toLowerCase(),
        )) {
      return;
    }
    final match = tracks.where(
      (t) => (t.language ?? '').toLowerCase().startsWith(
        preferred.toLowerCase(),
      ),
    );
    if (match.isEmpty) return;
    controller.setAudioTrack(match.first);
  }

  /// The sleep timer fired: pause, and say so. Playing again ends the
  /// sleep (see [_togglePlay] → `noteResumed`).
  void _onSleepTimerFired() {
    if (_disposed) return;
    unawaited(_controller?.pause());
    if (!mounted) return;
    ref
        .read(notificationServiceProvider)
        .showInfo(
          AppLocalizations.of(context)!.playerSleepTimerPaused,
          icon: Icons.bedtime_rounded,
        );
  }

  /// The moon button's picker: 15/30/45/60 minutes, end of episode, off.
  /// A side drawer like the other sheets, not a bottom sheet.
  Future<void> _showSleepPicker() async {
    final l10n = AppLocalizations.of(context)!;
    await _showSidePanel(
      title: l10n.playerSleepTimer,
      child: ListenableBuilder(
        listenable: _sleepTimer,
        builder: (context, _) {
          final mode = _sleepTimer.mode;
          final remaining = _sleepTimer.remaining;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (mode != SleepTimerMode.off)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      remaining != null
                          ? l10n.playerSleepTimerRemaining(
                              formatSleepRemaining(remaining),
                            )
                          : l10n.playerSleepTimerEndOfEpisodeArmed,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                for (final minutes in <int>[15, 30, 45, 60])
                  ListTile(
                    dense: true,
                    title: Text(
                      l10n.playerSleepTimerMinutes(minutes),
                      style: const TextStyle(color: Colors.white),
                    ),
                    leading: Icon(
                      _sleepTimer.selectedDuration ==
                              Duration(minutes: minutes)
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: Colors.white70,
                    ),
                    onTap: () {
                      _sleepTimer.start(Duration(minutes: minutes));
                      Navigator.of(context).pop();
                    },
                  ),
                ListTile(
                  dense: true,
                  title: Text(
                    l10n.playerSleepTimerEndOfEpisode,
                    style: const TextStyle(color: Colors.white),
                  ),
                  leading: Icon(
                    mode == SleepTimerMode.endOfEpisode
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: Colors.white70,
                  ),
                  onTap: () {
                    _sleepTimer.armEndOfEpisode();
                    Navigator.of(context).pop();
                  },
                ),
                ListTile(
                  dense: true,
                  title: Text(
                    l10n.playerSleepTimerOff,
                    style: const TextStyle(color: Colors.white),
                  ),
                  leading: Icon(
                    mode == SleepTimerMode.off
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: Colors.white70,
                  ),
                  onTap: () {
                    _sleepTimer.cancel();
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // -- sheets ----------------------------------------------------------------

  /// The side drawer the player sheets share: a right-anchored panel
  /// sliding in from the right edge, the same presentation mpv's
  /// GoldenDrawer and VLC's PlayerPanel use — so the function boxes never
  /// come up from below. Dense rows, white text, so every sheet reads as
  /// a picker, not a screen.
  Future<void> _showListSheet({
    required String title,
    required List<Widget> children,
  }) {
    return _showSidePanel(
      title: title,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  /// A right-anchored side drawer over the player, sliding in from the
  /// right edge (mpv/VLC's presentation). The video keeps playing behind
  /// it, a tap beside it closes it, and the chrome is held open while it
  /// is up so the button that opened it is still there to take focus back.
  Future<void> _showSidePanel({
    required String title,
    required Widget child,
  }) {
    _chrome.poke(hold: true);
    return Navigator.of(context).push<void>(
      _SidePanelRoute(
        barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        builder: (routeContext) {
          final width = goldenDrawerWidth(
            MediaQuery.sizeOf(routeContext).width,
          );
          return GoldenDrawer(
            title: title,
            onClose: () => Navigator.of(routeContext).pop(),
            width: width,
            child: child,
          );
        },
      ),
    ).whenComplete(() => _chrome.release());
  }

  /// One dense picker row: radio glyph, title, optional subtitle.
  ///
  /// Hand-built (InkWell + Row + Text), not a [ListTile]: in build #11
  /// the Sources/Quality/Audio drawers rendered their rows as error
  /// views ("Null check operator used on a null value") while the
  /// drawer's own header rendered fine, and every data read feeding the
  /// rows is null-safe in source — so the row widget itself is replaced
  /// with primitives that cannot throw from a framework null check.
  /// Same look as before: dense row, radio glyph, white title.
  Widget _sheetRow({
    required String title,
    String? subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: Colors.white70,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One disabled row for a panel whose list has not loaded yet: the
  /// panel opens with this instead of an empty drawer.
  Widget _sheetEmptyRow(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Text(
        message,
        style: const TextStyle(color: Colors.white54, fontSize: 14),
      ),
    );
  }

  /// The resolved sources, so the viewer can move to another one without
  /// leaving the player.
  Future<void> _showSourcesSheet() async {
    final l10n = AppLocalizations.of(context)!;
    await _showListSheet(
      title: l10n.sources,
      children: [
        if (_streams.isEmpty)
          _sheetEmptyRow(l10n.noResultsFound)
        else
          for (var i = 0; i < _streams.length; i++)
            _sheetRow(
              title: _startupRowLabel(_streams[i]),
              subtitle: sourceServer(_streams[i]),
              selected: i == _streamIndex,
              onTap: () {
                Navigator.of(context).pop();
                _pickSource(i);
              },
            ),
      ],
    );
  }

  /// The HLS/DASH renditions, with Auto on top. Only ever opened when
  /// there is a ladder to pick from (see the Quality button's gate).
  Future<void> _showQualitySheet() async {
    final controller = _controller;
    if (controller == null) return;
    final tracks = controller.betterPlayerAsmsTracks;
    final selected = controller.betterPlayerAsmsTrack;
    // One row per rendition height, tallest first; Auto is the
    // package's default track (a 0-size track).
    final byHeight = <int, BetterPlayerAsmsTrack>{};
    for (final track in tracks) {
      final height = track.height ?? 0;
      if (height > 0) byHeight.putIfAbsent(height, () => track);
    }
    final heights = byHeight.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final selectedHeight = selected?.height ?? 0;
    await _showListSheet(
      title: 'Quality',
      children: [
        _sheetRow(
          title: 'Auto',
          selected: selectedHeight <= 0,
          onTap: () {
            Navigator.of(context).pop();
            unawaited(
              controller.setTrack(BetterPlayerAsmsTrack.defaultTrack()),
            );
          },
        ),
        for (final height in heights)
          _sheetRow(
            title: '${height}p',
            selected: selectedHeight == height,
            onTap: () {
              Navigator.of(context).pop();
              final track = byHeight[height];
              if (track != null) {
                unawaited(controller.setTrack(track));
              }
            },
          ),
      ],
    );
  }

  /// The external subtitles, plus Off. The package's list carries the
  /// selection; the screen tracks the name for the button's lit state.
  Future<void> _showSubtitlesSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = _controller;
    if (controller == null) return;
    final sources = controller.betterPlayerSubtitlesSourceList;
    final none = sources.where(
      (s) => s.type == BetterPlayerSubtitlesSourceType.none,
    );
    final offSource = none.isEmpty
        ? BetterPlayerSubtitlesSource(
            type: BetterPlayerSubtitlesSourceType.none,
          )
        : none.first;
    final named = sources
        .where((s) => s.type != BetterPlayerSubtitlesSourceType.none)
        .toList(growable: false);
    await _showListSheet(
      title: l10n.subtitles,
      children: [
        _sheetRow(
          title: l10n.off,
          selected: _selectedSubtitleName == null,
          onTap: () {
            Navigator.of(context).pop();
            setState(() => _selectedSubtitleName = null);
            controller.setupSubtitleSource(offSource);
          },
        ),
        for (final source in named)
          _sheetRow(
            title: source.name ?? 'Subtitle',
            selected: _selectedSubtitleName == source.name,
            onTap: () {
              Navigator.of(context).pop();
              setState(() => _selectedSubtitleName = source.name);
              controller.setupSubtitleSource(source);
            },
          ),
      ],
    );
  }

  /// The HLS/DASH audio tracks, by language. Only ever opened when there
  /// is more than one to pick from (see the Audio button's gate).
  Future<void> _showAudioSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = _controller;
    if (controller == null) return;
    final tracks = controller.betterPlayerAsmsAudioTracks ?? const [];
    final selected = controller.betterPlayerAsmsAudioTrack;
    await _showListSheet(
      title: l10n.audio,
      children: [
        if (tracks.isEmpty)
          _sheetEmptyRow(l10n.noAudioTracks)
        else
          for (final track in tracks)
            _sheetRow(
              title:
                  track.label ??
                  track.language ??
                  'Audio ${track.id ?? ''}',
              subtitle: track.language,
              selected: selected?.id == track.id,
              onTap: () {
                Navigator.of(context).pop();
                controller.setAudioTrack(track);
              },
            ),
      ],
    );
  }

  /// The series' episodes, so the viewer can jump without leaving.
  Future<void> _showEpisodesSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final episodes = effectiveEpisodes(widget.item, _currentEpisode);
    await _showListSheet(
      title: l10n.episodes,
      children: [
        for (final episode in episodes)
          _sheetRow(
            title: 'S${episode.season} E${episode.episode} · ${episode.name}',
            selected: episode == _currentEpisode,
            onTap: () {
              Navigator.of(context).pop();
              unawaited(_pickEpisode(episode));
            },
          ),
      ],
    );
  }

  /// The playback speeds, 0.25x–2x. The package refuses anything outside
  /// that range, so the list never offers one.
  Future<void> _showSpeedSheet() async {
    final controller = _controller;
    if (controller == null) return;
    final current =
        controller.videoPlayerController?.value.speed ?? 1.0;
    const speeds = <double>[0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    await _showListSheet(
      title: 'Speed',
      children: [
        for (final speed in speeds)
          _sheetRow(
            title: _formatSpeed(speed),
            selected: current == speed,
            onTap: () {
              Navigator.of(context).pop();
              unawaited(controller.setSpeed(speed));
            },
          ),
      ],
    );
  }

  String _formatSpeed(double speed) {
    if (speed == speed.truncateToDouble()) return '${speed.toInt()}x';
    return '${speed}x';
  }

  // -- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings =
        ref.watch(playerSettingsProvider).value ?? const PlayerSettings();
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final form = playerFormFactorOf(profile);
    final isTv = form == PlayerFormFactor.tv;
    final showSwitch = settings.showPlayerSwitchButton;

    return PopScope(
      // Android's system Back leaves exactly as the on-screen arrow
      // does: stop the film, portrait, then the pop.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // The video, or black behind the resolving / failed stages.
            // The pinch zoom scales the picture around its centre, 0.5–
            // 3.0, and sticks where the fingers left it.
            if (_stage == _Stage.playing && _controller != null)
              ValueListenableBuilder<double>(
                valueListenable: _videoScale,
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: _buildVideoLayer(),
              )
            else
              Container(color: Colors.black),

            // Resolving: the source list. It stays up until the first
            // source actually plays — the list is the control, and the
            // first open is automatic. Portrait, until the video itself
            // starts playing.
            if (_stage == _Stage.resolving)
              PlayerStartupView(
                title: widget.item.title,
                episodeLine: _episodeLine,
                logoUrl: widget.item.logoUrl,
                backdropUrl: widget.item.backdropImageUrl,
                sourceName: _selected?.displaySource,
                status: _streams.isEmpty ? 'Getting links…' : null,
                attempt: _streams.isEmpty
                    ? null
                    : (index: _streamIndex + 1, total: _streams.length),
                rows: _startupRows,
                currentIndex: _startupCurrentIndex,
                onPick: _pickFromStartup,
                onBack: _goBack,
                isTv: isTv,
              ),

            // Failed: every link tried, or the resolve itself failed.
            if (_stage == _Stage.failed) _buildFailedView(l10n),

            // The chrome, in the VLC screen's own shape: the top bar, the
            // centre transport and the bottom bar, in the same places.
            // Unmounted while the ended card is up, and while the PiP
            // window owns the picture.
            if (_stage == _Stage.playing && _ended == null && !_inPip)
              _buildChrome(
                l10n,
                settings,
                isTv: isTv,
                showSwitch: showSwitch,
              ),

            // The ended card, over the video.
            if (_stage == _Stage.playing && _ended != null)
              Center(
                child: EndedCard(
                  title: _isSeries
                      ? (_currentEpisode?.name ?? widget.item.title)
                      : widget.item.title,
                  kind: _ended!,
                  onStartOver: _startOver,
                  onClose: _goBack,
                  onNextEpisode: _ended == EndedKind.declinedNext
                      ? () {
                          setState(() => _ended = null);
                          unawaited(_advance());
                        }
                      : null,
                  isTv: isTv,
                ),
              ),

            // The Skip button, bottom-right and outside the chrome on
            // purpose: a band can start while the bars are hidden, and
            // putting the one time-limited control behind a tap would
            // defeat it.
            if (_stage == _Stage.playing &&
                _ended == null &&
                !_inPip &&
                _currentSkipSegment != null)
              RepaintBoundary(
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16, bottom: 96),
                    child: FilledButton(
                      onPressed: () {
                        final segment = _currentSkipSegment;
                        if (segment == null) return;
                        unawaited(
                          _seekTo(
                            Duration(
                              milliseconds: (segment.endTime * 1000).round(),
                            ),
                          ),
                        );
                      },
                      child: Text(
                        switch (_currentSkipSegment!.type) {
                          SkipType.intro => l10n.skipIntro,
                          SkipType.outro => l10n.skipOutro,
                          SkipType.recap => l10n.skipRecap,
                          SkipType.unknown => l10n.skipIntro,
                        },
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The video layer, shaped by [_fit]. The configuration's fit is fill
  /// (see [_openStream]), so the wrapper owns the shape and the fit
  /// never re-creates the controller: contain letterboxes through the
  /// package's own aspect box, cover crops through a FittedBox, fill
  /// stretches to the screen.
  Widget _buildVideoLayer() {
    final controller = _controller!;
    final player = BetterPlayer(
      key: _betterPlayerKey,
      controller: controller,
    );
    return switch (_fit) {
      BoxFit.cover => SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: _videoSize?.width ?? 16,
            height: _videoSize?.height ?? 9,
            child: player,
          ),
        ),
      ),
      BoxFit.fill => SizedBox.expand(child: player),
      _ => Center(child: player),
    };
  }

  /// Failed: every link tried, or the resolve itself failed — the same
  /// shape as the other players, with the resolve diagnostic underneath
  /// for a screenshot.
  Widget _buildFailedView(AppLocalizations l10n) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.white54,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                _error ?? l10n.playerNothingToPlay,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const ResolveDiagnosticText(),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    onPressed: () {
                      setState(() {
                        _stage = _Stage.resolving;
                        _error = null;
                        _failedStreams.clear();
                      });
                      unawaited(_resolveAndOpen());
                    },
                    child: Text(l10n.retry),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _goBack,
                    child: Text(l10n.cancel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The chrome, in the VLC screen's own shape: a gesture layer, the
  /// centre transport, and the top and bottom bars at opposite edges —
  /// the same widgets, in the same places, so the engine is invisible.
  /// No badge, no "EXO" anywhere.
  Widget _buildChrome(
    AppLocalizations l10n,
    PlayerSettings settings, {
    required bool isTv,
    required bool showSwitch,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: _chrome,
      builder: (context, chromeVisible, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: _locked,
          builder: (context, isLocked, _) {
            return Stack(
              fit: StackFit.expand,
              children: [
                // The gesture layer: one scale recognizer owns the pan and
                // the pinch together (VLC's rule), so a drag can never steal
                // the first finger before a pinch starts. Tap toggles the
                // chrome, double-tap seeks on the outer thirds and toggles
                // play/pause in the centre third, a vertical swipe drives
                // the Left/Right Gesture rails, a horizontal swipe seeks,
                // a pinch zooms, and a long press on the right half holds
                // 2x. Locked, only a bare tap survives — it asks to see
                // the unlock chip.
                if (isLocked)
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _chrome.poke,
                  )
                else
                  Listener(
                    onPointerDown: _onPointerDown,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _chrome.toggle,
                      onDoubleTapDown: settings.doubleTapEnabled
                          ? (d) => _doubleTapSeek(d.localPosition.dx, settings)
                          : null,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: (d) => _onScaleUpdate(d, settings),
                      onScaleEnd: _onScaleEnd,
                      onLongPressStart: (d) =>
                          _startSpeedBoost(d.localPosition.dx),
                      onLongPressEnd: (_) => _endSpeedBoost(),
                      onLongPressCancel: _endSpeedBoost,
                    ),
                  ),

                // Buffering spinner, over the video, chrome or not: while
                // the picture has not started yet, and whenever the engine
                // starves mid-playback. The shared indicator VLC shows for
                // a stalled or held picture — never a dead black screen
                // with no feedback.
                if (_isBuffering || !_startedPlaying)
                  const PlayerBufferingIndicator(),

                // The gesture readouts, over the video: the seek toast,
                // the volume/brightness rail, and the double-tap burst.
                // Each is mounted once and driven by its own notifier, so
                // a write at pointer rate rebuilds one overlay and
                // nothing else.
                TransientOverlay<PlayerRail>(
                  value: _rail,
                  builder: (_, rail) => rail,
                ),
                TransientOverlay<String>(
                  value: _toast,
                  builder: (_, message) => PlayerToast(
                    message,
                    // Nudged up off the centre play/pause disc, so a
                    // swipe readout or the 2x label never lands on it.
                    alignment: const Alignment(0, -0.42),
                  ),
                ),
                TransientOverlay<SeekBurst>(
                  value: _seekBurst,
                  builder: (_, burst) => PlayerSeekBurst(
                    forward: burst.forward,
                    seconds: burst.seconds,
                    revision: burst.revision,
                  ),
                ),

                // The centre transport: −10 s, play/pause, +10 s. Withheld
                // while locked rather than left to an IgnorePointer, which
                // only tracks the chrome: a lock reveals the chrome to show
                // its chip, so the glyph would be up and hit-testable dead
                // centre.
                if (!isLocked)
                  Center(
                    child: AnimatedOpacity(
                      opacity: chromeVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !chromeVisible,
                        child: RepaintBoundary(
                          child: _buildCenterControls(l10n, settings),
                        ),
                      ),
                    ),
                  ),

                // Both bars, at opposite screen edges, one fade per bar
                // rather than one around the Column: a single opacity layer
                // around both is window-sized; two are each bar-sized, and
                // the spacer between them is in neither.
                IgnorePointer(
                  ignoring: !chromeVisible,
                  child: Column(
                    children: [
                      _fading(
                        _absorbGestures(
                          _buildTopBar(
                            l10n,
                            isTv: isTv,
                            showSwitch: showSwitch,
                          ),
                        ),
                        chromeVisible,
                      ),
                      const Expanded(child: SizedBox.expand()),
                      _fading(
                        _absorbGestures(
                          _buildBottomBar(l10n, settings, isTv: isTv),
                        ),
                        chromeVisible,
                      ),
                    ],
                  ),
                ),

                // The one control a locked player has, and the only way
                // back into the player short of leaving it. Rides the
                // chrome's own clock: a touch anywhere pokes the chrome,
                // the chip appears with it, and both go away together.
                // Bottom-centre because a thumb reaches the middle of the
                // bottom edge on any handset.
                if (isLocked)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 32),
                        child: AnimatedOpacity(
                          opacity: chromeVisible ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: IgnorePointer(
                            ignoring: !chromeVisible,
                            child: PlayerActionButton(
                              icon: Icons.lock_open_rounded,
                              label: l10n.unlock,
                              onTap: () => _locked.value = false,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// The top bar: back, title, episode line, and the trailing row — the
  /// moon (sleep timer), the lock, and the engine switch. The switch is
  /// only there when the viewer left the button on; null drops it and
  /// its gap, so the row never holds an empty space.
  Widget _buildTopBar(
    AppLocalizations l10n, {
    required bool isTv,
    required bool showSwitch,
  }) {
    return PlayerTopBar(
      title: widget.item.title,
      subtitle: _episodeLine,
      onBack: _goBack,
      isTv: isTv,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The sleep timer (moon): lit while one is armed. The timer
          // ticks every second, so only this button rebuilds on it.
          ListenableBuilder(
            listenable: _sleepTimer,
            builder: (context, _) => PlayerIconButton(
              icon: Icons.bedtime_rounded,
              tooltip: l10n.playerSleepTimer,
              isTv: isTv,
              highlight: _sleepTimer.isActive,
              onPressed: _showSleepPicker,
            ),
          ),
          PlayerIconButton(
            icon: Icons.lock_outline_rounded,
            tooltip: l10n.lock,
            isTv: isTv,
            onPressed: () {
              // The chip that undoes this rides the chrome's clock, so
              // the press that locks has to be the press that starts it.
              _chrome.poke();
              _locked.value = true;
            },
          ),
          if (showSwitch)
            PlayerIconButton(
              icon: Icons.swap_horiz_rounded,
              tooltip: 'Switch player',
              onPressed: _showEnginePicker,
              isTv: isTv,
              iconSize: isTv ? 34 : 30,
            ),
        ],
      ),
    );
  }

  /// The centre transport: −10 s, play/pause, +10 s. The step is the
  /// viewer's seek duration; a live edge steps only inside a window,
  /// and on a bare live edge the discs stand alone.
  Widget _buildCenterControls(
    AppLocalizations l10n,
    PlayerSettings settings,
  ) {
    final step = settings.seekDuration;
    return PlayerCenterControls(
      playing: _isPlaying,
      playLabel: _isPlaying ? l10n.pause : l10n.play,
      onPlayPause: () {
        _chrome.poke();
        unawaited(_togglePlay());
      },
      rewindIcon: _stepIcon(step, forward: false),
      forwardIcon: _stepIcon(step, forward: true),
      rewindLabel: l10n.playerRewindSeconds(step),
      forwardLabel: l10n.playerForwardSeconds(step),
      onRewind: _isLive
          ? null
          : () {
              _chrome.poke();
              _seekRelative(Duration(seconds: -step));
            },
      onForward: _isLive
          ? null
          : () {
              _chrome.poke();
              _seekRelative(Duration(seconds: step));
            },
    );
  }

  /// The seek step's disc: 5/10/30 s get their own glyph, anything else
  /// falls back to a rotate arrow.
  IconData _stepIcon(int step, {required bool forward}) {
    return switch ((step, forward)) {
      (5, false) => Icons.replay_5_rounded,
      (10, false) => Icons.replay_10_rounded,
      (30, false) => Icons.replay_30_rounded,
      (5, true) => Icons.forward_5_rounded,
      (10, true) => Icons.forward_10_rounded,
      (30, true) => Icons.forward_30_rounded,
      (_, false) => Icons.rotate_left_rounded,
      (_, true) => Icons.rotate_right_rounded,
    };
  }

  /// A double-tap: the outer thirds seek ±step, the centre third toggles
  /// play/pause. The seek shows its burst on the half that was tapped.
  void _doubleTapSeek(double dx, PlayerSettings settings) {
    final width = MediaQuery.sizeOf(context).width;
    final step = settings.seekDuration;
    if (dx < width / 3) {
      _seekRelative(Duration(seconds: -step));
      _showSeekBurst(forward: false, seconds: step);
    } else if (dx > width * 2 / 3) {
      _seekRelative(Duration(seconds: step));
      _showSeekBurst(forward: true, seconds: step);
    } else {
      unawaited(_togglePlay());
    }
  }

  /// The double-tap seek readout, on the half that was tapped.
  void _showSeekBurst({required bool forward, required int seconds}) {
    _seekBurst.show(
      SeekBurst(
        forward: forward,
        seconds: seconds,
        revision: ++_seekBurstRevision,
      ),
      hideAfter: const Duration(milliseconds: 900),
    );
  }

  void _showToast(String message) =>
      _toast.show(message, hideAfter: const Duration(milliseconds: 900));

  /// Holds playback at double speed while the finger is down on the RIGHT
  /// half (mpv's rule). Live streams are excluded: there is nothing ahead
  /// to race towards. The saved speed is restored exactly on release.
  void _startSpeedBoost(double dx) {
    if (_isLive || _speedBeforeBoost != null) return;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0 || dx < width / 2) return;
    if (!_isPlaying) return;
    _speedBeforeBoost =
        _controller?.videoPlayerController?.value.speed ?? 1.0;
    unawaited(_controller?.setSpeed(2.0));
    _showToast('2x');
  }

  void _endSpeedBoost() {
    final previous = _speedBeforeBoost;
    if (previous == null) return;
    _speedBeforeBoost = null;
    unawaited(_controller?.setSpeed(previous));
    _toast.clear();
  }

  /// Lands the pan's anchor: a [Listener] reports the pointer's down
  /// immediately, before any arena resolution.
  void _onPointerDown(PointerDownEvent event) {
    if (_panAxis != _PanAxis.none || _pinching) return;
    _panAnchor = event.position;
    _panAnchorLocalX = event.localPosition.dx;
  }

  /// The one scale gesture: pan with one finger, pinch with two.
  void _onScaleStart(ScaleStartDetails d) {
    _cancelSwipeSeek();
    _railDragEnd();
    _panAxis = _PanAxis.none;
    if (d.pointerCount >= 2) {
      _pinching = true;
      _pinchStartScale = _videoScale.value;
      _endSpeedBoost();
      return;
    }
    final wasPinching = _pinching;
    _pinching = false;
    if (wasPinching || _panAnchor == null) {
      _panAnchor = d.focalPoint;
      _panAnchorLocalX = d.localFocalPoint.dx;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d, PlayerSettings settings) {
    if (d.pointerCount >= 2) {
      if (!_pinching) {
        _pinching = true;
        _pinchStartScale = _videoScale.value;
        _cancelSwipeSeek();
        _railDragEnd();
        _endSpeedBoost();
      }
      final scale = (_pinchStartScale * d.scale).clamp(0.5, 3.0).toDouble();
      if (scale != _videoScale.value) _videoScale.value = scale;
      return;
    }
    if (_pinching || d.pointerCount != 1) return;
    if (_panAxis == _PanAxis.none) {
      final anchor = _panAnchor ?? d.focalPoint;
      final travel = d.focalPoint - anchor;
      if (travel.distance < 10) return;
      _panAxis = travel.dx.abs() >= travel.dy.abs()
          ? _PanAxis.horizontal
          : _PanAxis.vertical;
      if (_panAxis == _PanAxis.horizontal) {
        _beginSwipeSeek(anchor.dx, settings);
        _updateSwipeSeek(d.focalPoint.dx, settings);
      } else {
        unawaited(_beginRail(_panAnchorLocalX ?? d.localFocalPoint.dx));
        _updateRail(travel.dy);
      }
      return;
    }
    if (_panAxis == _PanAxis.horizontal) {
      _updateSwipeSeek(d.focalPoint.dx, settings);
    } else {
      _updateRail(d.focalPointDelta.dy);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (d.pointerCount >= 2) {
      _pinching = true;
      _pinchStartScale = _videoScale.value;
      _cancelSwipeSeek();
      _railDragEnd();
      _endSpeedBoost();
      _panAxis = _PanAxis.none;
      return;
    }
    if (_pinching) {
      final settled = _videoScale.value.clamp(0.5, 3.0).toDouble();
      if (settled != _videoScale.value) _videoScale.value = settled;
      _pinching = false;
      _panAxis = _PanAxis.none;
      _panAnchor = null;
      _panAnchorLocalX = null;
      return;
    }
    if (_panAxis == _PanAxis.horizontal) {
      _endSwipeSeek();
    } else if (_panAxis == _PanAxis.vertical) {
      _railDragEnd();
    }
    _panAxis = _PanAxis.none;
    _panAnchor = null;
    _panAnchorLocalX = null;
  }

  /// Starts a vertical rail from the down point's half: the Left/Right
  /// Gesture setting decides what each side drives (brightness, volume,
  /// seek, or none — the same setting VLC honours). Defaults: brightness
  /// on the left, volume on the right.
  Future<void> _beginRail(double localX) async {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    final isRight = localX >= width / 2;
    final settings =
        ref.read(playerSettingsProvider).value ?? const PlayerSettings();
    final gesture = isRight ? settings.rightGesture : settings.leftGesture;
    if (gesture == PlayerGesture.none) {
      _dragIsVolume = null;
      _dragIsSeek = false;
      return;
    }
    if (gesture == PlayerGesture.seek) {
      if (_isLive || _duration <= Duration.zero) {
        _dragIsVolume = null;
        _dragIsSeek = false;
        return;
      }
      _dragIsVolume = null;
      _dragIsSeek = true;
      _dragReady = true;
      _dragPending = 0;
      return;
    }
    final isVolume = gesture == PlayerGesture.volume;
    final id = ++_dragId;
    _dragIsVolume = isVolume;
    _dragReady = false;
    _dragPending = 0;
    if (isVolume) {
      // The engine volume is synchronous: ready at once.
      _dragStart = _volume;
      _dragReady = true;
    } else {
      final level = await _brightnessControl.read();
      if (!mounted || id != _dragId) return;
      if (level != null) _brightness = level;
      _dragStart = _brightness;
      _dragReady = true;
    }
    final pending = _dragPending;
    _dragPending = 0;
    if (pending != 0) _railTravel(isVolume, pending);
  }

  /// A full screen height of travel covers the whole range.
  void _updateRail(double primaryDelta) {
    final height = MediaQuery.sizeOf(context).height;
    if (height <= 0) return;
    final travel = -primaryDelta / height;
    if (_dragIsSeek) {
      if (!_dragReady) {
        _dragPending += travel;
        return;
      }
      _seekRailTravel(travel);
      return;
    }
    final isVolume = _dragIsVolume;
    if (isVolume == null) return;
    if (!_dragReady) {
      _dragPending += travel;
      return;
    }
    _railTravel(isVolume, travel);
  }

  /// Moves the swipe's level by [travel], a share of the screen's height,
  /// and applies it.
  void _railTravel(bool isVolume, double travel, {bool live = true}) {
    if (isVolume) {
      // Engine volume, 0..1: the package caps setVolume at 1.0, so there
      // is no boost past 100% here.
      _dragStart = (_dragStart + travel).clamp(0.0, 1.0);
      _volume = _dragStart;
      unawaited(_controller?.setVolume(_dragStart));
      _rail.show(
        PlayerRail(
          icon: _volumeIcon(_dragStart),
          value: _dragStart,
          label: '${(_dragStart * 100).round()}%',
          onLeft: true,
        ),
        hideAfter: live ? null : const Duration(milliseconds: 900),
      );
    } else {
      _dragStart = (_dragStart + travel).clamp(0.0, 1.0);
      _brightness = _dragStart;
      _brightnessOverridden = true;
      _brightnessControl.set(_brightness);
      _rail.show(
        PlayerRail(
          icon: _brightnessIcon(_brightness),
          value: _brightness,
          label: '${(_brightness * 100).round()}%',
          onLeft: false,
        ),
        hideAfter: live ? null : const Duration(milliseconds: 500),
      );
    }
  }

  /// Slides the playhead by [travel], a share of the screen's height.
  /// A full height is 90 seconds — the same scale the horizontal
  /// swipe-seek uses per full width — so the two seek gestures agree.
  /// Up is forward. The rail sits on the right edge and shows the target.
  void _seekRailTravel(double travel) {
    final delta = Duration(milliseconds: (travel * 90000).round());
    if (delta == Duration.zero) return;
    _seekRelative(delta);
    final target = _pendingSeekTarget ?? _position;
    _rail.show(
      PlayerRail(
        icon: Icons.fast_forward_rounded,
        value: _duration > Duration.zero
            ? (target.inMilliseconds / _duration.inMilliseconds).clamp(
                0.0,
                1.0,
              )
            : 0,
        label: _formatTime(target),
        onLeft: false,
      ),
    );
  }

  void _railDragEnd() {
    _dragIsVolume = null;
    _dragIsSeek = false;
    _rail.clearAfter(const Duration(milliseconds: 1500));
  }

  /// Starts a horizontal swipe-seek at global x [startX].
  void _beginSwipeSeek(double startX, PlayerSettings settings) {
    if (_isLive || !settings.swipeSeekEnabled || _duration <= Duration.zero) {
      return;
    }
    _horizontalDragStartX = startX;
    _horizontalDragStartPosition = _pendingSeekTarget ?? _position;
    _horizontalDragTarget = _horizontalDragStartPosition;
  }

  /// Moves the swipe-seek's target to global x [globalX]. The position is
  /// not sought yet — the end does that — so a swipe that becomes a pinch
  /// commits nothing.
  void _updateSwipeSeek(double globalX, PlayerSettings settings) {
    final startX = _horizontalDragStartX;
    final startPos = _horizontalDragStartPosition;
    if (startX == null || startPos == null || !settings.swipeSeekEnabled) {
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    final deltaFraction = (globalX - startX) / width;
    final seekDelta = Duration(milliseconds: (deltaFraction * 90000).round());
    var target = startPos + seekDelta;
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target >= _duration) {
      target = _duration - const Duration(seconds: 1);
      if (target < Duration.zero) target = Duration.zero;
    }
    _horizontalDragTarget = target;
    final diffSeconds = (target - startPos).inSeconds;
    _showToast(
      diffSeconds < 0
          ? '${diffSeconds}s (${_formatTime(target)})'
          : '+${diffSeconds}s (${_formatTime(target)})',
    );
  }

  /// Ends a swipe-seek: seeks to the target its updates arrived at.
  void _endSwipeSeek() {
    final target = _horizontalDragTarget;
    final start = _horizontalDragStartPosition;
    _horizontalDragStartX = null;
    _horizontalDragStartPosition = null;
    _horizontalDragTarget = null;
    if (target != null) {
      if (start != null &&
          (target - start).abs() < const Duration(milliseconds: 500)) {
        return;
      }
      unawaited(_seekTo(target));
      _chrome.poke();
    }
  }

  /// Drops a swipe-seek without seeking: a second finger turned the gesture
  /// into a pinch, or a new gesture superseded a stale one.
  void _cancelSwipeSeek() {
    _horizontalDragStartX = null;
    _horizontalDragStartPosition = null;
    _horizontalDragTarget = null;
  }

  static IconData _volumeIcon(double level) {
    if (level <= 0) return Icons.volume_off_rounded;
    if (level < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  static IconData _brightnessIcon(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped < 0.33) return Icons.brightness_5_rounded;
    if (clamped < 0.67) return Icons.brightness_6_rounded;
    return Icons.brightness_7_rounded;
  }

  /// The bottom bar: the seek strip on top, then the control row —
  /// audio, subtitles, speed, PiP, quality, fit, episodes, sources —
  /// in the screenshot's order, right-anchored and scrolling on
  /// everything but a television. Each button is absent rather than
  /// disabled when it has nothing to do.
  Widget _buildBottomBar(
    AppLocalizations l10n,
    PlayerSettings settings, {
    required bool isTv,
  }) {
    final controller = _controller;
    final audioTracks = controller?.betterPlayerAsmsAudioTracks;
    final hasAudio = audioTracks != null && audioTracks.length > 1;
    final hasQuality = (controller?.betterPlayerAsmsTracks ?? const [])
        .any((t) => (t.height ?? 0) > 0);
    final hasSubtitles =
        (_selected?.subtitles?.isNotEmpty ?? false) ||
        (controller?.betterPlayerSubtitlesSourceList ?? const []).any(
          (s) => s.type != BetterPlayerSubtitlesSourceType.none,
        );
    final speed =
        controller?.videoPlayerController?.value.speed ?? 1.0;

    return PlayerBottomBar(
      isTv: isTv,
      // Everything but a television can drag the strip, so everything
      // but a television gets one line.
      scrollingActions: !isTv,
      // Its own boundary: the scrubber repaints on every position tick,
      // which would otherwise repaint the whole bottom bar, scrim and
      // every icon button.
      progressBar: RepaintBoundary(child: _buildSeekBar(isTv: isTv)),
      leading: [
        if (_previousEpisode != null)
          PlayerIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous episode',
            isTv: isTv,
            onPressed: () {
              _chrome.poke();
              unawaited(_goToPreviousEpisode());
            },
          ),
        if (_hasNextEpisode)
          PlayerIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: 'Next episode',
            isTv: isTv,
            onPressed: () {
              _chrome.poke();
              unawaited(_advance());
            },
          ),
      ],
      actions: [
        if (hasAudio)
          PlayerIconButton(
            icon: Icons.audiotrack_rounded,
            tooltip: l10n.audio,
            isTv: isTv,
            onPressed: () {
              _chrome.poke();
              unawaited(_showAudioSheet());
            },
          ),
        if (hasSubtitles)
          PlayerIconButton(
            icon: Icons.closed_caption_rounded,
            tooltip: l10n.subtitles,
            isTv: isTv,
            highlight: _selectedSubtitleName != null,
            onPressed: () {
              _chrome.poke();
              unawaited(_showSubtitlesSheet());
            },
          ),
        // Speed is meaningless on a live edge, so the button is absent
        // there rather than present and inert.
        if (!_isLive && settings.showPlaybackSpeed)
          PlayerIconButton(
            icon: Icons.speed,
            tooltip: '${_formatSpeed(speed)}x',
            isTv: isTv,
            highlight: speed != 1.0,
            onPressed: () {
              _chrome.poke();
              unawaited(_showSpeedSheet());
            },
          ),
        if (defaultTargetPlatform == TargetPlatform.android &&
            settings.showPip)
          PlayerIconButton(
            icon: Icons.picture_in_picture_alt_rounded,
            tooltip: l10n.pip,
            isTv: isTv,
            onPressed: () {
              _chrome.poke();
              unawaited(_enterPip());
            },
          ),
        if (hasQuality)
          PlayerIconButton(
            icon: Icons.high_quality_rounded,
            tooltip: 'Quality',
            isTv: isTv,
            onPressed: () {
              _chrome.poke();
              unawaited(_showQualitySheet());
            },
          ),
        if (settings.showResize)
          PlayerIconButton(
            icon: Icons.aspect_ratio_rounded,
            tooltip: l10n.resize,
            isTv: isTv,
            onPressed: () {
              _chrome.poke();
              _cycleFit();
            },
          ),
        if (_isSeries)
          PlayerIconButton(
            icon: Icons.list_rounded,
            tooltip: l10n.episodes,
            isTv: isTv,
            onPressed: () {
              _chrome.poke();
              unawaited(_showEpisodesSheet());
            },
          ),
        PlayerIconButton(
          icon: Icons.dns_rounded,
          tooltip: l10n.sources,
          isTv: isTv,
          onPressed: () {
            _chrome.poke();
            unawaited(_showSourcesSheet());
          },
        ),
      ],
    );
  }

  /// The seek strip: the time, the scrubber, the duration. The shared
  /// [PlayerScrubber] VLC and mpv use — so the thumb, the buffered band
  /// and the skip-segment bands are the same widget, not a second design.
  /// A live edge has no scrubber — a LIVE badge keeps the row's height,
  /// so nothing jumps when the badge lands.
  Widget _buildSeekBar({required bool isTv}) {
    final displayPosition = _displayPosition;
    final durationMs = _duration.inMilliseconds;
    final bufferedFraction = durationMs <= 0
        ? 0.0
        : (_buffered.inMilliseconds / durationMs).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(
            _formatTime(displayPosition),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _isLive
              ? const Align(
                  alignment: Alignment.centerLeft,
                  child: _LiveBadge(),
                )
              : PlayerScrubber(
                  position: displayPosition,
                  duration: _duration,
                  hasDuration: _duration > Duration.zero,
                  bufferRatio: bufferedFraction,
                  canSeek: !_isLive,
                  skipSegments: _skipSegments,
                  isTv: isTv,
                  onChangeStart: (ms) {
                    _chrome.poke(hold: true);
                    setState(
                      () => _seekPreview =
                          Duration(milliseconds: ms.round()),
                    );
                  },
                  onChanged: (ms) {
                    setState(
                      () => _seekPreview =
                          Duration(milliseconds: ms.round()),
                    );
                  },
                  onChangeEnd: (ms) {
                    _chrome.release();
                    final target = Duration(milliseconds: ms.round());
                    setState(() => _seekPreview = null);
                    unawaited(_seekTo(target));
                  },
                ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: Text(
            _formatTime(_duration),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  String _formatTime(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final two = (int n) => n.toString().padLeft(2, '0');
    if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
    return '$minutes:${two(seconds)}';
  }

  /// No RepaintBoundary of its own: RenderAnimatedOpacity is one for as
  /// long as alpha > 0, which is exactly when the bar is on screen, and
  /// at alpha 0 it paints nothing to protect.
  Widget _fading(Widget bar, bool visible) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: const Duration(milliseconds: 200),
    child: bar,
  );

  /// Swallows taps and drags so they never reach the chrome-toggle layer
  /// underneath the bars.
  Widget _absorbGestures(Widget child) => GestureDetector(
    onTap: () {},
    onLongPress: () {},
    onVerticalDragStart: (_) {},
    onHorizontalDragStart: (_) {},
    child: child,
  );
}

/// The LIVE badge on the seek strip, for a real livestream.
class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A modal that leaves the video playing behind it.
///
/// [PopupRoute] rather than `showModalBottomSheet`: this one has to keep
/// the route below built and visible, own its own transition (a slide,
/// never a window-sized fade), and take its shape from the window — the
/// same presentation VLC's player panel uses.
class _SidePanelRoute extends PopupRoute<void> {
  _SidePanelRoute({required this.builder, required this.barrierLabel});

  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  /// A plain colour, drawn by the framework's own barrier.
  @override
  Color get barrierColor => const Color(0x73000000);

  @override
  bool get barrierDismissible => true;

  /// mpv's drawer time: 280 ms, ease-out.
  @override
  Duration get transitionDuration => const Duration(milliseconds: 280);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position:
          Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
          ),
      child: child,
    );
  }
}

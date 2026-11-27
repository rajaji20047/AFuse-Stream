import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cloudflare WARP as a local HTTP proxy.
///
/// The native side ([WarpModule] in Kotlin) runs the `usque` binary as a
/// subprocess exposing an HTTP proxy on 127.0.0.1:<port>. This service is
/// the Dart half: it drives the native module over the
/// `dev.rajaji.raja/warp` MethodChannel, holds the live proxy port the
/// Dio client routes through ([proxyPort]), and owns the persisted
/// on/off setting.
///
/// There is no system VPN here and no VpnService permission: only the
/// app's own Dart HTTP traffic (Dio) goes through the proxy. The video
/// players fetch streams natively (MPV/VLC/Exo), so a blocked file host
/// is still fetched direct by the player — WARP unblocks the provider
/// and API fetches, which is where ISP blocking bites. That matches
/// Vega, whose OkHttp factory routes the same way.
class WarpService {
  WarpService._();

  static final WarpService instance = WarpService._();

  static const _channel = MethodChannel('dev.rajaji.raja/warp');

  /// SharedPreferences key for the persisted on/off setting.
  static const enabledKey = 'warp_enabled';

  /// The local HTTP proxy port WARP is listening on, or null when off.
  ///
  /// Read on the Dio hot path (dio_client_provider.dart) — a plain
  /// field, not a provider, so a toggle takes effect on the next
  /// connection without rebuilding Dio. Kept in sync with the native
  /// side by [getStatus] (and cleared whenever a call fails).
  int? _proxyPort;

  int? get proxyPort => _proxyPort;

  /// True while the proxy is up (Dart-side view).
  bool get isWarpOn => _proxyPort != null;

  /// Guards concurrent starts (boot init + settings open racing).
  Future<WarpStatus>? _startFuture;

  /// Starts the proxy (idempotent: already-running returns the live
  /// status, a concurrent start shares the in-flight future).
  Future<WarpStatus> start() {
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;
    final future = _startNow();
    _startFuture = future;
    return future.whenComplete(() {
      if (identical(_startFuture, future)) _startFuture = null;
    });
  }

  Future<WarpStatus> _startNow() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'startWarp',
      );
      final status = result == null
          ? WarpStatus.stopped
          : WarpStatus.fromMap(result);
      _proxyPort = status.running ? status.port : null;
      return status;
    } on PlatformException catch (e) {
      _proxyPort = null;
      throw WarpException(e.message ?? e.code);
    } on MissingPluginException {
      _proxyPort = null;
      throw const WarpException('WARP is not available in this build');
    }
  }

  /// Stops the proxy.
  Future<WarpStatus> stop() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'stopWarp',
      );
      final status = result == null
          ? WarpStatus.stopped
          : WarpStatus.fromMap(result);
      _proxyPort = null;
      return status;
    } on PlatformException catch (e) {
      _proxyPort = null;
      throw WarpException(e.message ?? e.code);
    } on MissingPluginException {
      _proxyPort = null;
      throw const WarpException('WARP is not available in this build');
    }
  }

  /// Reads the live native status and syncs [_proxyPort] with it, so a
  /// proxy that died on its own stops being routed to.
  Future<WarpStatus> getStatus() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getStatus',
      );
      final status = result == null
          ? WarpStatus.stopped
          : WarpStatus.fromMap(result);
      _proxyPort = status.running ? status.port : null;
      return status;
    } on PlatformException catch (e) {
      _proxyPort = null;
      throw WarpException(e.message ?? e.code);
    } on MissingPluginException {
      _proxyPort = null;
      throw const WarpException('WARP is not available in this build');
    }
  }

  /// Persists the on/off choice and applies it. The choice is stored
  /// only after the native call succeeds, so a failed start cannot
  /// leave prefs saying on while the UI says off.
  Future<WarpStatus> setEnabled(bool value) async {
    final status = value ? await start() : await stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, value);
    return status;
  }

  /// Boot: if WARP was left on, bring the proxy back up. Best-effort —
  /// a failed start at boot must never break launch, and the start keeps
  /// running in the background past the init timeout.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(enabledKey) ?? false) {
        try {
          await start();
        } catch (e) {
          if (kDebugMode) debugPrint('[WARP] Boot start failed: $e');
        }
      }
    } catch (_) {
      // Prefs unreadable: WARP stays off.
    }
  }
}

/// The native side's answer to start/stop/status.
class WarpStatus {
  final bool running;
  final int? port;
  final String? transport;

  const WarpStatus({required this.running, this.port, this.transport});

  static const stopped = WarpStatus(running: false);

  factory WarpStatus.fromMap(Map<String, dynamic> map) {
    return WarpStatus(
      running: map['running'] as bool? ?? false,
      port: map['port'] as int?,
      transport: map['transport'] as String?,
    );
  }
}

/// A WARP failure, with the native side's message for the UI.
class WarpException implements Exception {
  final String message;

  const WarpException(this.message);

  @override
  String toString() => 'WarpException: $message';
}

/// Settings-screen state for WARP.
class WarpSettings {
  final bool enabled;
  final bool running;
  final int? port;
  final bool busy;

  const WarpSettings({
    this.enabled = false,
    this.running = false,
    this.port,
    this.busy = false,
  });

  WarpSettings copyWith({
    bool? enabled,
    bool? running,
    int? port,
    bool? busy,
    bool clearPort = false,
  }) {
    return WarpSettings(
      enabled: enabled ?? this.enabled,
      running: running ?? this.running,
      port: clearPort ? null : (port ?? this.port),
      busy: busy ?? this.busy,
    );
  }
}

/// Hand-written (no codegen) provider for [WarpSettings], mirroring the
/// DoH settings provider's shape: an async build (prefs + live native
/// status) and a [setEnabled] the settings tile drives.
final warpSettingsProvider =
    AsyncNotifierProvider<WarpSettingsNotifier, WarpSettings>(
      WarpSettingsNotifier.new,
    );

class WarpSettingsNotifier extends AsyncNotifier<WarpSettings> {
  @override
  Future<WarpSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(WarpService.enabledKey) ?? false;
    // If WARP should be on, make sure the proxy is actually up before
    // reporting — main.dart already kicked off the start at boot, so
    // this is usually a fast status read, and a concurrent start is
    // shared with it.
    WarpStatus status = WarpStatus.stopped;
    try {
      status = enabled
          ? await WarpService.instance.start()
          : await WarpService.instance.getStatus();
    } catch (_) {
      status = WarpStatus.stopped;
    }
    return WarpSettings(
      enabled: enabled,
      running: status.running,
      port: status.port,
    );
  }

  /// Turns WARP on/off. Returns true when the requested state is in
  /// effect. Throws [WarpException] when the native side fails, so the
  /// tile can show the reason; the state is restored to the previous
  /// choice on failure.
  Future<bool> setEnabled(bool value) async {
    final current = state.asData?.value ?? const WarpSettings();
    state = AsyncData(current.copyWith(busy: true));
    try {
      final status = await WarpService.instance.setEnabled(value);
      state = AsyncData(
        WarpSettings(
          enabled: value,
          running: status.running,
          port: status.port,
        ),
      );
      return status.running == value;
    } catch (e) {
      state = AsyncData(current.copyWith(busy: false));
      rethrow;
    }
  }
}

/// Performs the HTTP CONNECT handshake for [host]:[port] over an already
/// connected [socket] to an HTTP proxy, and returns when the proxy has
/// answered 200. The socket is then ready for a TLS upgrade
/// ([SecureSocket.secure]) — the proxy sends nothing after the 200 until
/// the client speaks TLS, so no response bytes are left buffered.
Future<void> httpConnect(Socket socket, String host, int port) async {
  socket.write(
    'CONNECT $host:$port HTTP/1.1\r\n'
    'Host: $host:$port\r\n'
    'Proxy-Connection: keep-alive\r\n'
    '\r\n',
  );
  await socket.flush();
  final status = await _readConnectResponse(socket).timeout(
    const Duration(seconds: 10),
    onTimeout: () =>
        throw const WarpException('WARP proxy CONNECT timed out'),
  );
  if (status != 200) {
    throw WarpException('WARP proxy refused CONNECT ($status)');
  }
}

/// Reads one HTTP proxy CONNECT response (headers ending in `\r\n\r\n`)
/// and returns its status code.
Future<int> _readConnectResponse(Socket socket) async {
  final buffer = <int>[];
  final completer = Completer<int>();
  late StreamSubscription<List<int>> sub;
  sub = socket.listen(
    (chunk) {
      buffer.addAll(chunk);
      final code = parseProxyConnectStatus(buffer);
      if (code != null) {
        unawaited(sub.cancel());
        if (!completer.isCompleted) completer.complete(code);
      }
    },
    onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer.completeError(
          const WarpException('WARP proxy closed the connection'),
        );
      }
    },
    cancelOnError: true,
  );
  return completer.future;
}

/// Parses an HTTP proxy CONNECT response from the bytes read so far.
/// Returns the status code once the header block (ending `\r\n\r\n`) is
/// complete, -1 when the response is malformed, or null when more bytes
/// are needed. Pure, so it is unit-tested without a socket.
int? parseProxyConnectStatus(List<int> bytes) {
  var end = -1;
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      end = i;
      break;
    }
  }
  if (end == -1) return null;
  final text = ascii.decode(bytes.sublist(0, end));
  final firstLine = text.split('\r\n').first;
  final parts = firstLine.split(' ');
  if (parts.length < 2) return -1;
  return int.tryParse(parts[1]) ?? -1;
}

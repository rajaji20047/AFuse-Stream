import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'clearance/clearance.dart';
import 'doh_service.dart';
import 'http_defaults.dart';

part 'dio_client_provider.g.dart';

/// The connect budget the app advertises on every request.
const Duration kDioConnectTimeout = Duration(seconds: 15);

/// Upper bound on how long one connection may wait for a DoH answer before
/// giving up and letting the system resolver handle it.
///
/// This sits *outside* dio's [kDioConnectTimeout]: dart:io applies the client's
/// connection timeout to the socket only after the `connectionFactory` future
/// resolves, so whatever we wait here is added to the advertised budget, not
/// deducted from it. It must therefore stay a fraction of it — a blocked DoH
/// endpoint used to double every request's worst case from 15 s to 30 s.
///
/// It is a backstop, not the primary bound: [DohService.kResolveTimeout] caps
/// the lookup one second earlier, and the negative cache plus circuit breaker
/// mean a blocked endpoint is paid for at most a handful of times, not once
/// per request.
const Duration kDohResolveGuard = Duration(seconds: 6);

// keepAlive, and honestly so: twelve keepAlive providers watch this, which
// already pinned it for the process lifetime. Declared autoDispose it was a
// lie the analyzer kept flagging, and the `ref.read` callers (nuvio_repository,
// player_settings_provider) could in principle have rebuilt a fresh Dio --
// and with it a cold connection pool -- between reads.
@Riverpod(keepAlive: true)
Dio dioClient(Ref ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: kDioConnectTimeout,
      receiveTimeout: const Duration(seconds: 15),
      // M10: a stalled upload (tracking sync, GraphQL POST) must not
      // hang forever either.
      sendTimeout: const Duration(seconds: 15),
      // Default to a real browser UA so resolution presents the same
      // identity the player will use during playback. Per-request headers
      // from plugins still override this. See http_defaults.dart.
      headers: const {'User-Agent': kDefaultBrowserUserAgent},
    ),
  );

  // Instead of an interceptor (which mangles the URL/Host headers for HTTPS/SNI),
  // we intercept at the socket level. This intercepts socket creation right
  // before the TLS handshake, preserving the original URI host for SNI verification.
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.idleTimeout = const Duration(minutes: 5);
      client.maxConnectionsPerHost = 10;
      client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
        final host = uri.host;

        // Helper to upgrade the socket to TLS if the scheme is https
        Future<ConnectionTask<Socket>> connectWithTlsUpgrade(
          Future<ConnectionTask<Socket>> taskFuture,
        ) {
          if (uri.scheme == 'https') {
            return taskFuture.then((task) {
              return ConnectionTask.fromSocket(
                task.socket.then((socket) {
                  // M9: the 10 s timeout above covers the TCP connect
                  // only — a host that accepts TCP but never completes
                  // TLS used to hang the request forever, because Dio's
                  // own timeout cannot fire until this factory future
                  // resolves.
                  return SecureSocket.secure(
                    socket,
                    host: uri.host,
                  ).timeout(const Duration(seconds: 10));
                }),
                task.cancel,
              );
            });
          }
          return taskFuture;
        }

        // Optionally skip if DoH is disabled
        if (!DohService.instance.enabled) {
          return connectWithTlsUpgrade(
            Socket.startConnect(
              host,
              uri.port,
            ).timeout(const Duration(seconds: 10)),
          );
        }

        final ip = await DohService.instance
            .resolve(host)
            .timeout(kDohResolveGuard, onTimeout: () => null);
        if (ip != null) {
          if (kDebugMode) {
            debugPrint(
              '[IOHttpClientAdapter] Connecting $host via DoH resolved IP: $ip',
            );
          }
          // Connect to the resolved IP but preserve the original uri properties for SNI
          return connectWithTlsUpgrade(
            Socket.startConnect(
              ip,
              uri.port,
            ).timeout(const Duration(seconds: 10)),
          );
        }

        // Fallback to normal DNS
        return connectWithTlsUpgrade(
          Socket.startConnect(
            host,
            uri.port,
          ).timeout(const Duration(seconds: 10)),
        );
      };
      return client;
    },
  );

  // Retries idempotent GETs on transient failures (M10): on flaky
  // mobile data a single socket error / timeout / 429 / 5xx used to
  // come back as an empty screen, with no retry anywhere except TMDB
  // and Anilist. Added before the clearance interceptor so a bot-check
  // gets solved first (onError runs in reverse order) and only a
  // failure Clearance passes on is retried here.
  dio.interceptors.add(_RetryInterceptor(dio));

  // Bot checks (Cloudflare, DDoS-Guard): a cleared site's requests carry its
  // clearance, and a check is solved and the request sent again. See
  // clearance/clearance.dart.
  final clearance = Clearance.instance.interceptorFor(dio);
  if (clearance != null) dio.interceptors.add(clearance);

  return dio;
}

/// Retries idempotent GETs on transient failures (M10). Two retries,
/// 300/600 ms backoff. Non-GETs are never retried (not idempotent).
class _RetryInterceptor extends Interceptor {
  _RetryInterceptor(this._dio);

  final Dio _dio;

  static const _retriesKey = '_retryCount';
  static const _maxRetries = 2;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    if (request.method != 'GET') return super.onError(err, handler);
    final retries = (request.extra[_retriesKey] as int?) ?? 0;
    if (retries >= _maxRetries) return super.onError(err, handler);
    final status = err.response?.statusCode;
    final retryable =
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.connectionError ||
        status == 429 ||
        (status != null && status >= 500);
    if (!retryable) return super.onError(err, handler);
    request.extra[_retriesKey] = retries + 1;
    await Future<void>.delayed(
      Duration(milliseconds: retries == 0 ? 300 : 600),
    );
    try {
      final response = await _dio.fetch<dynamic>(request);
      handler.resolve(response);
    } catch (_) {
      // The retry failed too: hand the original error on, so the caller
      // sees the first failure, not the retry's.
      super.onError(err, handler);
    }
  }
}

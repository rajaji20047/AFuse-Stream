// v8 (2.9.19+64): Fuse Account works with no setup. The built-in sync
// server is used until the viewer saves one of their own, and clearing that
// goes back to the default. The dialog wears the app accent, not gold.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/theme/accent_color.dart';
import 'package:raja/core/theme/app_theme.dart';
import 'package:raja/features/account/data/raja_account_notifier.dart';
import 'package:raja/features/account/data/raja_sync_client.dart';
import 'package:raja/features/account/presentation/raja_account_section.dart';

/// Answers every request with one fixed status and JSON body.
class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
  final List<String> urls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri.toString());
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeAccount extends RajaAccountNotifier {
  _FakeAccount(this._state);

  final RajaAccountState _state;

  @override
  RajaAccountState build() => _state;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  RajaAccountState state = const RajaAccountState(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [rajaAccountProvider.overrideWith(() => _FakeAccount(state))],
      child: MaterialApp(
        theme: AppTheme.createDarkTheme(
          null,
          seedColor: RajaAccent.green.color,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('which sync server is used', () {
    test('the built-in server when nothing is saved', () {
      expect(kRajaSyncWorkerUrl, 'https://zorox-sync.deepace115.workers.dev');
      expect(effectiveSyncServerUrl(null), kRajaSyncWorkerUrl);
      expect(effectiveSyncServerUrl(''), kRajaSyncWorkerUrl);
      expect(effectiveSyncServerUrl('   '), kRajaSyncWorkerUrl);
      // It passes the same check every account call makes first.
      RajaSyncClient.checkBaseUrl(effectiveSyncServerUrl(null));
    });

    test('a saved server wins, without its trailing slash', () {
      expect(
        effectiveSyncServerUrl(' https://my.example.workers.dev/ '),
        'https://my.example.workers.dev',
      );
    });

    test('a fresh account state is already set up, on the default', () {
      const state = RajaAccountState();
      expect(state.cloudConfigured, isTrue);
      expect(state.usingDefaultServer, isTrue);
      expect(state.workerUrl, kRajaSyncWorkerUrl);
    });
  });

  testWidgets('the dialog no longer says cloud sync is not set up', (
    tester,
  ) async {
    await _pump(tester, const RajaAccountDialog());
    expect(find.text('Fuse Account'), findsOneWidget);
    expect(find.textContaining('not set up'), findsNothing);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
  });

  testWidgets('the dialog wears the app accent, not gold', (tester) async {
    await _pump(tester, const RajaAccountDialog());
    final context = tester.element(find.text('Log in'));
    final primary = Theme.of(context).colorScheme.primary;
    final hsl = HSLColor.fromColor(primary);
    // Green accent: hue in the green band, nowhere near gold (~46).
    expect(hsl.hue, inInclusiveRange(90, 170));
    final material = tester.widget<Material>(
      find
          .ancestor(of: find.text('Log in'), matching: find.byType(Material))
          .first,
    );
    expect(material.color, primary);
  });

  testWidgets('the Sync server editor is empty on the default', (tester) async {
    await _pump(tester, const RajaWorkerUrlDialog());
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.textContaining('built-in sync server'), findsOneWidget);
  });

  testWidgets('the Sync server editor shows a saved server', (tester) async {
    await _pump(
      tester,
      const RajaWorkerUrlDialog(),
      state: const RajaAccountState(
        workerUrl: 'https://my.example.workers.dev',
        usingDefaultServer: false,
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'https://my.example.workers.dev',
    );
  });

  group('an expired session', () {
    test('a 401 from the server is told apart from other errors', () async {
      final adapter = _FixedAdapter(401, {
        'ok': false,
        'error': 'Session expired. Log in again.',
      });
      final client = RajaSyncClient(dio: Dio()..httpClientAdapter = adapter);
      Object? caught;
      try {
        await client.upload(effectiveSyncServerUrl(null), 'old-token', {});
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<RajaSyncException>());
      final error = caught! as RajaSyncException;
      expect(error.sessionExpired, isTrue);
      expect(error.message, 'Session expired. Log in again.');
      expect(adapter.urls.single, '$kRajaSyncWorkerUrl/sync');
    });

    test('a server error is not an expired session', () async {
      final client = RajaSyncClient(
        dio: Dio()
          ..httpClientAdapter = _FixedAdapter(500, {
            'ok': false,
            'error': 'Server not configured.',
          }),
      );
      await expectLater(
        client.login(kRajaSyncWorkerUrl, 'a@b.co', 'password1'),
        throwsA(
          isA<RajaSyncException>().having(
            (e) => e.sessionExpired,
            'sessionExpired',
            isFalse,
          ),
        ),
      );
    });

    testWidgets('the Fuse Account card says to log in again', (tester) async {
      await _pump(
        tester,
        const SingleChildScrollView(child: RajaAccountSection()),
        state: const RajaAccountState(
          email: 'a@b.co',
          sessionExpired: true,
          error: kSessionExpiredMessage,
        ),
      );
      expect(
        find.text('Session expired — tap to log in again'),
        findsOneWidget,
      );
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Sync now'), findsNothing);
    });
  });
}

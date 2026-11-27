import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raja/core/network/warp_service.dart';

void main() {
  group('parseProxyConnectStatus', () {
    test('200 once the header block is complete', () {
      expect(
        parseProxyConnectStatus(
          ascii.encode('HTTP/1.1 200 OK\r\n\r\n'),
        ),
        200,
      );
    });

    test('non-200 status is reported, not hidden', () {
      expect(
        parseProxyConnectStatus(
          ascii.encode('HTTP/1.1 403 Forbidden\r\n\r\n'),
        ),
        403,
      );
      expect(
        parseProxyConnectStatus(
          ascii.encode('HTTP/1.0 502 Bad Gateway\r\nX-Foo: bar\r\n\r\n'),
        ),
        502,
      );
    });

    test('null while the header block is incomplete', () {
      expect(parseProxyConnectStatus(ascii.encode('HTTP/1.1 20')), isNull);
      expect(
        parseProxyConnectStatus(ascii.encode('HTTP/1.1 200 OK\r\n')),
        isNull,
      );
    });

    test('-1 for a malformed status line', () {
      expect(parseProxyConnectStatus(ascii.encode('garbage\r\n\r\n')), -1);
      expect(parseProxyConnectStatus(ascii.encode('\r\n\r\n')), -1);
    });

    test('bytes after the header block do not change the code', () {
      expect(
        parseProxyConnectStatus(
          ascii.encode('HTTP/1.1 200 OK\r\n\r\nEXTRA'),
        ),
        200,
      );
    });
  });

  group('WarpStatus.fromMap', () {
    test('running with a port', () {
      const status = WarpStatus(running: true, port: 41991);
      final parsed = WarpStatus.fromMap(<String, dynamic>{
        'running': true,
        'port': 41991,
        'transport': 'HTTP/3',
      });
      expect(parsed.running, status.running);
      expect(parsed.port, status.port);
      expect(parsed.transport, 'HTTP/3');
    });

    test('stopped has no port', () {
      final parsed = WarpStatus.fromMap(<String, dynamic>{'running': false});
      expect(parsed.running, isFalse);
      expect(parsed.port, isNull);
    });

    test('missing keys default to stopped', () {
      final parsed = WarpStatus.fromMap(<String, dynamic>{});
      expect(parsed.running, isFalse);
      expect(parsed.port, isNull);
      expect(parsed.transport, isNull);
    });
  });

  group('WarpSettings.copyWith', () {
    test('clearPort drops the port', () {
      const settings = WarpSettings(
        enabled: true,
        running: true,
        port: 41991,
      );
      final cleared = settings.copyWith(running: false, clearPort: true);
      expect(cleared.port, isNull);
      expect(cleared.enabled, isTrue);
      expect(cleared.running, isFalse);
    });

    test('port survives an unrelated change', () {
      const settings = WarpSettings(
        enabled: true,
        running: true,
        port: 41991,
      );
      final updated = settings.copyWith(busy: true);
      expect(updated.port, 41991);
    });
  });
}

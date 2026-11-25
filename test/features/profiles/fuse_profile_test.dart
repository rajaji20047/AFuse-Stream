// Profiles Build 1: the FuseProfile model, the palette, name validation,
// and the PIN record round count.
//
// NOTE: these tests are written but NOT run yet — the b107 agent is
// running flutter on this VM and two flutter processes OOM it. Run after
// b107 lands: `flutter test test/features/profiles/`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raja/features/app_lock/app_lock_passcode.dart';
import 'package:raja/features/profiles/data/fuse_profile.dart';

void main() {
  group('FuseProfile', () {
    test('JSON round trip keeps every field', () {
      final profile = FuseProfile(
        id: 'p_9f2c41a77d3e4b08',
        name: 'Suresh',
        color: 'gold',
        pinRecord: 'v1\$100000\$c2FsdA\$aGFzaA',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1795129000000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1795129000000),
      );
      final back = FuseProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );
      expect(back.id, profile.id);
      expect(back.name, profile.name);
      expect(back.color, profile.color);
      expect(back.pinRecord, profile.pinRecord);
      expect(back.createdAt, profile.createdAt);
      expect(back.updatedAt, profile.updatedAt);
      expect(back.hasPinRecord, isTrue);
    });

    test('a profile without a record cannot be opened', () {
      final profile = FuseProfile(
        id: 'p_9f2c41a77d3e4b08',
        name: 'Guest',
        color: 'teal',
        pinRecord: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(profile.hasPinRecord, isFalse);
    });

    test('unknown colour falls back to gold, never crashes the picker', () {
      expect(fuseProfileColor('pink'), kFuseProfileColors['gold']);
      expect(fuseProfileColor('gold'), kFuseProfileColors['gold']);
    });

    test('the palette is the fixed 6 colours', () {
      expect(
        kFuseProfileColors.keys.toSet(),
        {'gold', 'teal', 'red', 'blue', 'purple', 'green'},
      );
      expect(kFuseProfileMaxCount, 5);
    });

    test('name validation: empty and over 20 chars fail', () {
      expect(fuseProfileNameError(''), isNotNull);
      expect(fuseProfileNameError('   '), isNotNull);
      expect(fuseProfileNameError('x' * 21), isNotNull);
      expect(fuseProfileNameError('Suresh'), isNull);
      expect(fuseProfileNameError('  Aarav  '), isNull);
    });
  });

  group('AppLockPasscodeHash.create rounds', () {
    test('profiles pass 100,000 rounds; the app lock still defaults to 10,000', () {
      final profileRecord = AppLockPasscodeHash.create(
        '1234',
        rounds: kFuseProfilePinRounds,
      );
      expect(profileRecord.startsWith('v1\$100000\$'), isTrue);
      expect(AppLockPasscodeHash.isWellFormed(profileRecord), isTrue);
      expect(AppLockPasscodeHash.verify('1234', profileRecord), isTrue);
      expect(AppLockPasscodeHash.verify('0000', profileRecord), isFalse);

      final lockRecord = AppLockPasscodeHash.create('1234');
      expect(lockRecord.startsWith('v1\$10000\$'), isTrue);
    });

    test('verify parses any rounds', () {
      // A fast record for tests that only need "a record that verifies".
      final record = AppLockPasscodeHash.create('9876', rounds: 1000);
      expect(AppLockPasscodeHash.verify('9876', record), isTrue);
      expect(AppLockPasscodeHash.verify('9877', record), isFalse);
    });
  });
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../logger/app_logger.dart';
import 'storage_service.dart';

part 'secure_token_storage.g.dart';

/// Platform-secure storage for OAuth credentials (Trakt/Simkl/MAL/AniList
/// access + refresh tokens). Backed by Keychain (iOS/macOS), Keystore (Android),
/// Credentials API (Windows), and libsecret (Linux). Falls back to the
/// pre-existing Hive-backed [StorageService] on a per-key read if the secure
/// backend throws — so a missing libsecret install on Linux degrades gracefully
/// rather than locking the user out.
///
/// On first read of a given key, if the secure backend returns null but the
/// legacy [StorageService] still has a value (users who installed the app
/// before this change), the value is migrated into the secure backend and
/// removed from the legacy box. Existing OAuth sessions therefore survive the
/// upgrade.
class SecureTokenStorage {
  SecureTokenStorage(this._legacy);

  final StorageService _legacy;
  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  Future<String?> read(String key) async {
    try {
      final v = await _secure.read(key: key);
      if (v != null) return v;
    } catch (e) {
      talker.error('SecureTokenStorage.read failed for $key', e);
    }
    // Legacy migration (one-shot): if a value exists in plain Hive, move it.
    // Guarded (M6): a closed settings box must not turn a token read into
    // a throw — return null and let the caller treat it as "no session".
    String? legacy;
    try {
      legacy = _legacy.getString(key);
    } catch (e) {
      talker.error('SecureTokenStorage.read legacy fallback failed for $key', e);
      return null;
    }
    if (legacy != null && legacy.isNotEmpty) {
      try {
        await _secure.write(key: key, value: legacy);
        await _legacy.remove(key);
        talker.debug('SecureTokenStorage: migrated $key from legacy storage');
      } catch (e) {
        talker.error('SecureTokenStorage migration failed for $key', e);
        // Fall through and return the legacy value so the user stays logged in
        // even if the secure backend is unavailable on this platform.
        return legacy;
      }
      return legacy;
    }
    return null;
  }

  Future<void> write(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
      // Clear any stale legacy copy.
      try {
        await _legacy.remove(key);
      } catch (e) {
        talker.error(
          'SecureTokenStorage.write legacy cleanup failed for $key',
          e,
        );
      }
    } catch (e) {
      talker.error('SecureTokenStorage.write failed for $key', e);
      // Last-resort fallback: keep the user logged in even on a broken
      // secure backend. Less ideal than secure storage but better than
      // dropping the session entirely.
      try {
        await _legacy.setString(key, value);
      } catch (e) {
        talker.error(
          'SecureTokenStorage.write legacy fallback failed for $key',
          e,
        );
      }
    }
  }

  /// Removes [key] from the secure store and the legacy store. Returns
  /// false when the key could not be removed (M6): the caller must not
  /// assume the session is gone — a logout that swallows this leaves the
  /// user logged in after "logging out".
  Future<bool> delete(String key) async {
    var removed = true;
    try {
      await _secure.delete(key: key);
    } catch (e) {
      talker.error('SecureTokenStorage.delete failed for $key', e);
      removed = false;
    }
    try {
      await _legacy.remove(key);
    } catch (e) {
      talker.error('SecureTokenStorage.delete legacy fallback failed for $key', e);
      removed = false;
    }
    return removed;
  }
}

@Riverpod(keepAlive: true)
SecureTokenStorage secureTokenStorage(Ref ref) {
  return SecureTokenStorage(ref.watch(storageServiceProvider));
}

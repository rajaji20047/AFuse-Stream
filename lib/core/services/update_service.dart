import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:version/version.dart';

import '../data/models/github_release.dart';

import '../network/dio_client_provider.dart';

part 'update_service.g.dart';

// Read by the keepAlive updateProvider, so it outlives every autoDispose
// cycle anyway.
@Riverpod(keepAlive: true)
UpdateService updateService(Ref ref) {
  return UpdateService(ref.watch(dioClientProvider));
}

class UpdateService {
  final Dio _dio;
  static const String _owner = 'techforfriend';
  // The app's own repo. Update checks read its latest release.
  static const String _repo = 'Fuse_android';

  UpdateService(this._dio);

  /// Checks GitHub for a newer release. Returns the release when one is
  /// newer, null when up to date. Throws on failure (offline, rate
  /// limit, malformed tag) — the caller reports it as an error instead
  /// of "up to date" (M12); a failure used to collapse to null here.
  Future<GithubRelease?> checkForUpdate() async {
    final currentPackageInfo = await PackageInfo.fromPlatform();
    final currentVersion = parseReleaseVersion(currentPackageInfo.version);

    final response = await _dio.get<Map<String, dynamic>>(
      'https://api.github.com/repos/$_owner/$_repo/releases/latest',
    );

    if (response.statusCode == 200 && response.data != null) {
      final release = GithubRelease.fromJson(response.data!);
      // Clean tag name (remove 'v' prefix if present)
      final tagName = release.tagName.replaceAll(RegExp(r'^v'), '');
      final latestVersion = parseReleaseVersion(tagName);

      if (kDebugMode) {
        debugPrint(
          '[UpdateService] Current version: $currentPackageInfo.version -> $currentVersion, Latest version: $tagName -> $latestVersion',
        );
      }

      if (latestVersion > currentVersion) {
        if (kDebugMode) {
          debugPrint(
            '[UpdateService] Update check RESULT: New version available ($latestVersion)',
          );
        }
        return release;
      } else {
        if (kDebugMode) {
          debugPrint(
            '[UpdateService] Update check RESULT: Already up to date',
          );
        }
      }
    }
    return null;
  }

  /// Downloads the release's platform asset, resuming a partial file
  /// from a previous attempt (M16): a stalled download used to restart
  /// from zero, and a truncated file was only discovered at install
  /// time. Returns null when no asset fits this platform, the download
  /// fails, or the finished file does not match the asset's size.
  Future<File?> downloadUpdateAsset(
    GithubRelease release,
    void Function(double) onProgress,
  ) async {
    try {
      final asset = await findPlatformAsset(release);
      if (asset == null) return null;

      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/${asset.name}';
      final file = File(savePath);
      final expectedSize = asset.size;

      // Resume: a previous attempt may have left a partial file. A file
      // already at the expected size is the finished download (a previous
      // attempt completed but the install never ran).
      var downloaded = await file.exists() ? await file.length() : 0;
      if (expectedSize > 0 && downloaded == expectedSize) return file;
      // Bigger than the asset (or from another release): start over
      // rather than appending to the wrong bytes.
      if (expectedSize > 0 && downloaded > expectedSize) downloaded = 0;

      // Dio's download truncates the file, so resume is done by hand:
      // a ranged GET streamed into the file in append mode.
      final response = await _dio.get<ResponseBody>(
        asset.browserDownloadUrl,
        options: Options(
          responseType: ResponseType.stream,
          // An APK is tens of MB; give the download a longer leash than
          // the shared 15 s receive timeout.
          receiveTimeout: const Duration(minutes: 10),
          headers: downloaded > 0
              ? {'Range': 'bytes=$downloaded-'}
              : null,
        ),
      );
      // The server ignored Range (200, not 206): the bytes coming are
      // the whole file, so the partial file must be restarted, not
      // appended to.
      final resumed = downloaded > 0 && response.statusCode == 206;
      if (!resumed) downloaded = 0;
      final sink = file.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      var received = 0;
      try {
        await for (final chunk in response.data!.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (expectedSize > 0) {
            final progress = (downloaded + received) / expectedSize;
            onProgress(progress.clamp(0.0, 1.0).toDouble());
          }
        }
      } finally {
        await sink.close();
      }

      // Integrity: a truncated file must never reach the installer.
      if (expectedSize > 0) {
        final actualSize = await file.length();
        if (actualSize != expectedSize) {
          if (kDebugMode) {
            debugPrint(
              '[UpdateService] Download size mismatch: got $actualSize, expected $expectedSize',
            );
          }
          await file.delete();
          return null;
        }
      }
      return file;
    } catch (e) {
      if (kDebugMode) debugPrint('Download failed: $e');
      return null;
    }
  }

  Future<GithubAsset?> findPlatformAsset(GithubRelease release) async {
    final assets = release.assets
        .where((a) => !a.name.toLowerCase().contains('debug'))
        .toList();

    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      final abis = info.supportedAbis;

      // 1. Match specific ABI (arm64-v8a, armeabi-v7a, x86_64)
      for (final abi in abis) {
        final match = assets.firstWhereOrNull(
          (a) =>
              a.name.toLowerCase().contains('android') &&
              a.name.toLowerCase().contains(abi.toLowerCase()),
        );
        if (match != null) return match;
      }

      // 2. Fallback to universal
      final universal = assets.firstWhereOrNull(
        (a) =>
            a.name.toLowerCase().contains('android') &&
            a.name.toLowerCase().contains('universal'),
      );
      if (universal != null) return universal;

      // 3. Last resort: any APK
      return assets.firstWhereOrNull(
        (a) =>
            a.name.toLowerCase().contains('android') &&
            a.name.toLowerCase().endsWith('.apk'),
      );
    } else if (Platform.isWindows) {
      final arch =
          Platform.environment['PROCESSOR_ARCHITECTURE']?.toLowerCase() ??
          'x64';
      final isArm = arch.contains('arm') || arch.contains('aarch64');
      final archTag = isArm ? 'arm64' : 'x64';

      final windowsAssets = assets
          .where((a) => a.name.toLowerCase().contains('windows'))
          .toList();
      var archAssets = windowsAssets
          .where((a) => a.name.toLowerCase().contains(archTag))
          .toList();

      // Fallback for x86_64 / amd64 naming
      if (archAssets.isEmpty && !isArm) {
        archAssets = windowsAssets
            .where(
              (a) =>
                  a.name.toLowerCase().contains('x86_64') ||
                  a.name.toLowerCase().contains('amd64'),
            )
            .toList();
      }

      if (archAssets.isNotEmpty) {
        // Prefer .exe, then .msix, then .zip
        return archAssets.firstWhereOrNull(
              (a) => a.name.toLowerCase().endsWith('.exe'),
            ) ??
            archAssets.firstWhereOrNull(
              (a) => a.name.toLowerCase().endsWith('.msix'),
            ) ??
            archAssets.firstWhereOrNull(
              (a) => a.name.toLowerCase().endsWith('.zip'),
            ) ??
            archAssets.first;
      }

      // 2. Fallback to any windows installer
      return windowsAssets.firstWhereOrNull(
            (a) => a.name.toLowerCase().endsWith('.exe'),
          ) ??
          windowsAssets.firstWhereOrNull(
            (a) => a.name.toLowerCase().endsWith('.zip'),
          );
    } else if (Platform.isMacOS) {
      final info = await DeviceInfoPlugin().macOsInfo;
      final arch = info.arch.toLowerCase(); // e.g. "arm64" or "x86_64"

      final macosAssets = assets
          .where(
            (a) =>
                a.name.toLowerCase().contains('macos') ||
                a.name.toLowerCase().contains('mac'),
          )
          .toList();
      var archAssets = macosAssets
          .where((a) => a.name.toLowerCase().contains(arch))
          .toList();

      // Fallback for x64 alias
      if (archAssets.isEmpty && arch == 'x86_64') {
        archAssets = macosAssets
            .where((a) => a.name.toLowerCase().contains('x64'))
            .toList();
      }

      if (archAssets.isNotEmpty) {
        // Prefer .dmg over .zip
        return archAssets.firstWhereOrNull(
              (a) => a.name.toLowerCase().endsWith('.dmg'),
            ) ??
            archAssets.firstWhereOrNull(
              (a) => a.name.toLowerCase().endsWith('.zip'),
            ) ??
            archAssets.first;
      }

      return macosAssets.firstWhereOrNull(
            (a) => a.name.toLowerCase().endsWith('.dmg'),
          ) ??
          macosAssets.firstWhereOrNull(
            (a) => a.name.toLowerCase().endsWith('.zip'),
          );
    } else if (Platform.isLinux) {
      final version = Platform.version.toLowerCase();
      return linuxAsset(
        assets,
        isArm: version.contains('arm') || version.contains('aarch64'),
        install: linuxInstallOf(
          environment: Platform.environment,
          executable: Platform.resolvedExecutable,
        ),
      );
    }
    return null;
  }

  /// How Raja runs on Linux, from its [environment] and the path of its
  /// [executable].
  ///
  /// The AppImage runtime sets `APPIMAGE` and `APPDIR` and runs the binary
  /// from inside `APPDIR`. Both variables pass to whatever Raja starts, so
  /// the binary's own path decides: another AppImage that started Raja
  /// leaves them behind for a binary outside its `APPDIR`.
  @visibleForTesting
  static LinuxInstall linuxInstallOf({
    required Map<String, String> environment,
    required String executable,
  }) {
    final appDir = environment['APPDIR'] ?? '';
    if ((environment['APPIMAGE'] ?? '').isNotEmpty &&
        appDir.isNotEmpty &&
        p.isWithin(appDir, executable)) {
      return LinuxInstall.appImage;
    }
    if (p.isWithin(_debInstallDir, executable)) return LinuxInstall.deb;
    return LinuxInstall.tarball;
  }

  /// Where the .deb installs Raja (fastforge's `/opt/<package_name>`).
  static const _debInstallDir = '/opt/raja';

  /// The Linux asset an update of [install] downloads: its own format, built
  /// for its architecture, so an update never installs a second copy beside
  /// the one running. Null when the release has none, and the caller opens
  /// the release's page instead.
  ///
  /// A name without an architecture serves either, as older releases named
  /// them; a name for the other architecture is never chosen.
  @visibleForTesting
  static GithubAsset? linuxAsset(
    List<GithubAsset> assets, {
    required bool isArm,
    required LinuxInstall install,
  }) {
    const arm = ['arm64', 'aarch64'];
    const x64 = ['x64', 'x86_64', 'amd64'];
    bool names(GithubAsset asset, List<String> archs) =>
        archs.any(asset.name.toLowerCase().contains);

    final linux = assets
        .where((a) => a.name.toLowerCase().contains('linux'))
        .where((a) => a.name.toLowerCase().endsWith(install.extension))
        .toList();
    return linux.firstWhereOrNull((a) => names(a, isArm ? arm : x64)) ??
        linux.firstWhereOrNull((a) => !names(a, arm) && !names(a, x64));
  }
}

/// How Raja was installed on Linux. An update comes in the same form.
enum LinuxInstall {
  /// An AppImage.
  appImage('.appimage'),

  /// The .deb.
  deb('.deb'),

  /// Anything else: the tarball, unpacked wherever its owner chose.
  tarball('.tar.gz');

  const LinuxInstall(this.extension);

  /// The release asset's file extension, lower-cased.
  final String extension;
}

/// A release tag or app version as a [Version], forgiving short tags:
/// `v1` and `1` are 1.0.0, `v1.1` is 1.1.0, `v2.0.3` is 2.0.3 (a leading
/// `v` is optional). So the first public release, tagged `v1`, compares
/// equal to the app's own 1.0.0 — no update prompt — and a later `v1.1`
/// or `v2` is seen as newer. Throws [FormatException] for anything that
/// is not a version at all, which the caller treats as "no update".
Version parseReleaseVersion(String raw) {
  var text = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
  final short = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(text);
  if (short != null) {
    text = '${short.group(1)}.${short.group(2) ?? '0'}.0';
  }
  return Version.parse(text);
}

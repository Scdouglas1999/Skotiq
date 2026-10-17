// Android applies an update by handing a verified APK to the OS, which is a
// different shape from every other platform: nothing is extracted, no helper
// binary runs, and this process stays alive afterwards. The callers used to
// read "applyUpdate returned" as "the handoff failed", because on desktop it
// exits inside the call — which turned a successful Android install into an
// on-screen error.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/android_installer.dart';
import 'package:skotiq_updater/src/services/update_downloader.dart';
import 'package:skotiq_updater/src/services/update_service.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory dataDir;
  late Ed25519 algorithm;
  late SimpleKeyPair keyPair;
  late String publicKeyBase64;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('sk-android-apply-');
    algorithm = Ed25519();
    keyPair = await algorithm.newKeyPair();
    publicKeyBase64 = base64Encode((await keyPair.extractPublicKey()).bytes);
    debugInstallApkOverride = null;
  });

  tearDown(() async {
    debugInstallApkOverride = null;
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  });

  Future<UpdateManifest> signedManifest(List<int> apkBytes) async {
    final digest = sha256.convert(apkBytes).toString();
    final manifest = UpdateManifest(
      version: '7.2.0',
      buildNumber: 42,
      releaseDate: DateTime.utc(2026, 9, 20),
      platform: 'android',
      arch: 'arm64',
      files: {
        'app.apk': UpdateFileInfo(
          path: 'app.apk',
          size: apkBytes.length,
          sha256: digest,
        ),
      },
      totalSize: apkBytes.length,
      compressedSize: apkBytes.length,
      packageSha256: digest,
      downloadUrl: 'https://example.invalid/app.apk',
    );
    final signature = await algorithm.sign(
      utf8.encode(UpdateVerifier.canonicalManifestPayload(manifest)),
      keyPair: keyPair,
    );
    return manifest.copyWith(signature: base64Encode(signature.bytes));
  }

  UpdateService serviceFor() => UpdateService(
    currentVersion: '7.1.0',
    currentBuildNumber: 40,
    currentPlatform: 'android',
    currentArch: 'arm64',
    verifier: UpdateVerifier(trustedPublicKeyBase64: publicKeyBase64),
    applicationSupportDirectoryProvider: () async => dataDir,
  );

  /// Lay down exactly what _downloadAndStageApk persists.
  Future<String> stageApk(UpdateManifest manifest, List<int> apkBytes) async {
    final staging = Directory(path.join(dataDir.path, 'updates', 'staging'));
    await staging.create(recursive: true);
    final apkPath = path.join(staging.path, 'update.apk');
    await File(apkPath).writeAsBytes(apkBytes);
    await persistStagedManifest(staging, manifest);
    await File(path.join(staging.path, 'ready.json')).writeAsString(
      jsonEncode({
        'version': manifest.version,
        'buildNumber': manifest.buildNumber,
        'stagedAt': DateTime.now().toIso8601String(),
        'extractPath': apkPath,
      }),
    );
    return apkPath;
  }

  test('a verified APK is handed to the platform installer', () async {
    final apkBytes = utf8.encode('a plausible apk');
    final manifest = await signedManifest(apkBytes);
    final apkPath = await stageApk(manifest, apkBytes);

    String? installed;
    debugInstallApkOverride = (p) async => installed = p;

    final outcome = await serviceFor().applyUpdate();

    expect(installed, apkPath);
    // The caller must be able to tell this apart from a failed desktop
    // handoff; inferring it from "we are still running" is what produced a
    // spurious error on every successful Android install.
    expect(outcome, UpdateApplyOutcome.handedToPlatformInstaller);
  });

  test('an APK swapped after staging is refused', () async {
    final apkBytes = utf8.encode('a plausible apk');
    final manifest = await signedManifest(apkBytes);
    final apkPath = await stageApk(manifest, apkBytes);

    // The manifest and its signature are untouched — only the bytes on disk
    // changed, which is what a local tamper looks like.
    await File(apkPath).writeAsBytes(utf8.encode('something else entirely'));

    var installed = false;
    debugInstallApkOverride = (_) async => installed = true;

    await expectLater(
      serviceFor().applyUpdate(),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('no longer matches the hash'),
        ),
      ),
    );
    expect(installed, isFalse);
    expect(
      await File(apkPath).exists(),
      isFalse,
      reason: 'a tampered APK must not be left on disk to be retried',
    );
  });

  test('an unsigned manifest cannot reach the installer', () async {
    final apkBytes = utf8.encode('a plausible apk');
    final signed = await signedManifest(apkBytes);
    // Strip the signature: Android's own package check is a second layer, not
    // a replacement for authenticating the release to the vendor key.
    final unsigned = signed.copyWith(signature: null);
    await stageApk(unsigned, apkBytes);

    var installed = false;
    debugInstallApkOverride = (_) async => installed = true;

    await expectLater(serviceFor().applyUpdate(), throwsA(isA<Exception>()));
    expect(installed, isFalse);
  });

  test('a missing staged APK is reported, not silently installed', () async {
    final apkBytes = utf8.encode('a plausible apk');
    final manifest = await signedManifest(apkBytes);
    final apkPath = await stageApk(manifest, apkBytes);
    await File(apkPath).delete();

    var installed = false;
    debugInstallApkOverride = (_) async => installed = true;

    await expectLater(
      serviceFor().applyUpdate(),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('Staged APK is missing'),
        ),
      ),
    );
    expect(installed, isFalse);
  });

  test(
    'the APK of the build now running is discarded, not offered again',
    () async {
      // Android replaces the app and relaunches it without ever returning to
      // the code that staged the APK, and there is no helper binary to clear
      // staging the way the desktop updater does. The relaunched app used to
      // find its own version still staged, announce it as ready to install,
      // and keep the whole APK on the phone indefinitely.
      final apkBytes = utf8.encode('a plausible apk');
      final manifest = await signedManifest(apkBytes);
      final apkPath = await stageApk(manifest, apkBytes);

      final relaunched = UpdateService(
        currentVersion: '7.2.0',
        currentBuildNumber: 42,
        currentPlatform: 'android',
        currentArch: 'arm64',
        verifier: UpdateVerifier(trustedPublicKeyBase64: publicKeyBase64),
        applicationSupportDirectoryProvider: () async => dataDir,
      );

      expect(await relaunched.getStagedUpdate(), isNull);
      expect(await File(apkPath).exists(), isFalse);
      expect(
        relaunched.takePendingNotice(),
        isNull,
        reason: 'an install that worked is not a fault to warn about',
      );
    },
  );

  test('an update staged for a newer build is kept', () async {
    final apkBytes = utf8.encode('a plausible apk');
    final manifest = await signedManifest(apkBytes);
    await stageApk(manifest, apkBytes);

    final staged = await serviceFor().getStagedUpdate();
    expect(staged?.version, '7.2.0');
    expect(staged?.buildNumber, 42);
  });

  test(
    'the APK is written inside staging whatever an unverified manifest says',
    () async {
      // The download lands before the manifest's signature is checked, so no
      // field of the manifest may choose where the bytes go. A name built
      // from `version` and `arch` let an arch of `/../../..` write outside the
      // staging directory before anything had been authenticated.
      final apkBytes = utf8.encode('a plausible apk');
      final manifest = (await signedManifest(
        apkBytes,
      )).copyWith(arch: '/../../../escaped');

      final written = <String>[];
      final service = UpdateService(
        currentVersion: '7.1.0',
        currentBuildNumber: 40,
        currentPlatform: 'android',
        currentArch: 'arm64',
        verifier: UpdateVerifier(trustedPublicKeyBase64: publicKeyBase64),
        downloader: _RecordingDownloader(apkBytes, written),
        applicationSupportDirectoryProvider: () async => dataDir,
      );

      // The altered arch breaks the signature, so staging must fail; what
      // matters here is where any bytes were put before it did. (The manifest
      // signature is now checked before the download starts, so none are;
      // the path check stays in case that order ever changes.)
      await expectLater(
        service.downloadAndStage(manifest),
        throwsA(isA<UpdateException>()),
      );
      final staging = path.join(dataDir.path, 'updates', 'staging');
      for (final target in written) {
        expect(
          path.isWithin(staging, path.normalize(target)),
          isTrue,
          reason: 'APK written to ${path.normalize(target)}',
        );
      }
    },
  );
}

class _RecordingDownloader extends UpdateDownloader {
  _RecordingDownloader(this.bytes, this.written);

  final List<int> bytes;
  final List<String> written;

  @override
  Future<File> download(
    String url,
    String destinationPath, {
    DownloadProgressCallback? onProgress,
    int? expectedSize,
    CancelToken? cancelToken,
  }) async {
    written.add(destinationPath);
    final file = File(destinationPath);
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes);
  }
}

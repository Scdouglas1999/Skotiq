import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:nightshade_updater/src/models/update_manifest.dart';
import 'package:nightshade_updater/src/services/archive_extraction.dart';
import 'package:nightshade_updater/src/services/update_service.dart';
import 'package:nightshade_updater/src/services/update_verifier.dart';

void main() {
  group('UpdateService pending install verification', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'nightshade_updater_test_',
      );
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<Directory> appSupportDir() async => tempRoot;

    Future<File> pendingFile() async {
      final updatesDir = Directory(
        '${tempRoot.path}${Platform.pathSeparator}updates',
      );
      await updatesDir.create(recursive: true);
      return File(
        '${updatesDir.path}${Platform.pathSeparator}pending_install.json',
      );
    }

    test('returns none when no pending marker exists', () async {
      final service = UpdateService(
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        applicationSupportDirectoryProvider: appSupportDir,
      );

      final result = await service.verifyPendingInstall();
      expect(result.state, PendingInstallState.none);
    });

    test('verifies matching target build and cleans backup', () async {
      final backupDir = Directory(
        '${tempRoot.path}${Platform.pathSeparator}updates${Platform.pathSeparator}backup',
      );
      await backupDir.create(recursive: true);
      await File(
        '${backupDir.path}${Platform.pathSeparator}nightshade_desktop.exe',
      ).writeAsString('old');

      final marker = await pendingFile();
      await marker.writeAsString(
        jsonEncode({
          'targetVersion': '2.1.0',
          'targetBuildNumber': 42,
          'previousVersion': '2.0.0',
          'previousBuildNumber': 1,
          'backupDir': backupDir.path,
        }),
      );

      final service = UpdateService(
        currentVersion: '2.1.0',
        currentBuildNumber: 42,
        applicationSupportDirectoryProvider: appSupportDir,
      );

      final result = await service.verifyPendingInstall();
      expect(result.state, PendingInstallState.verified);
      expect(await marker.exists(), isFalse);
      expect(await backupDir.exists(), isFalse);
    });

    test('detects rolled back previous build and clears marker', () async {
      final marker = await pendingFile();
      await marker.writeAsString(
        jsonEncode({
          'targetVersion': '2.1.0',
          'targetBuildNumber': 42,
          'previousVersion': '2.0.0',
          'previousBuildNumber': 1,
        }),
      );

      final service = UpdateService(
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        applicationSupportDirectoryProvider: appSupportDir,
      );

      final result = await service.verifyPendingInstall();
      expect(result.state, PendingInstallState.rolledBack);
      expect(await marker.exists(), isFalse);
    });

    test('a rolled-back update is not left staged to be applied again', () async {
      // The rehearsal: after the updater restored the previous build (the new
      // one failed to start, or failed the updater's own hash check), that
      // build came up reporting the rolled-back version as staged and ready,
      // with its extracted tree already deleted or known bad. Applying it
      // again could only fail the same way.
      final staging = Directory(
        '${tempRoot.path}${Platform.pathSeparator}updates${Platform.pathSeparator}staging',
      );
      await staging.create(recursive: true);
      await File(
        '${staging.path}${Platform.pathSeparator}ready.json',
      ).writeAsString(
        jsonEncode({
          'version': '2.1.0',
          'buildNumber': 42,
          'stagedAt': DateTime.utc(2026, 9, 27).toIso8601String(),
          'extractPath': '${staging.path}${Platform.pathSeparator}extracted',
        }),
      );
      final marker = await pendingFile();
      await marker.writeAsString(
        jsonEncode({
          'targetVersion': '2.1.0',
          'targetBuildNumber': 42,
          'previousVersion': '2.0.0',
          'previousBuildNumber': 1,
        }),
      );

      final service = UpdateService(
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        applicationSupportDirectoryProvider: appSupportDir,
      );

      final result = await service.verifyPendingInstall();
      expect(result.state, PendingInstallState.rolledBack);
      expect(await service.getStagedUpdate(), isNull);
    });
  });

  group('UpdateService manual rollback restore point', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'nightshade_rollback_test_',
      );
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<Directory> appSupportDir() async => tempRoot;

    File rollbackLogFile() => File(
      '${tempRoot.path}${Platform.pathSeparator}updates'
      '${Platform.pathSeparator}backup'
      '${Platform.pathSeparator}rollback_log.json',
    );

    test('hasRestorePoint is false when no rollback log is on disk', () async {
      final service = UpdateService(
        currentVersion: '2.1.0',
        currentBuildNumber: 42,
        applicationSupportDirectoryProvider: appSupportDir,
      );

      expect(await service.hasRestorePoint(), isFalse);
    });

    test(
      'hasRestorePoint probe does not create the backup directory',
      () async {
        final service = UpdateService(
          currentVersion: '2.1.0',
          currentBuildNumber: 42,
          applicationSupportDirectoryProvider: appSupportDir,
        );

        await service.hasRestorePoint();

        final backupDir = Directory(
          '${tempRoot.path}${Platform.pathSeparator}updates'
          '${Platform.pathSeparator}backup',
        );
        expect(
          await backupDir.exists(),
          isFalse,
          reason: 'read-only probe must not create directories',
        );
      },
    );

    test(
      'hasRestorePoint is true once the updater leaves a rollback log',
      () async {
        // Simulate a successful apply: the Rust updater retains
        // backup/rollback_log.json alongside the restore point.
        final log = rollbackLogFile();
        await log.parent.create(recursive: true);
        await log.writeAsString(
          jsonEncode({
            'moved': [
              {'rel': 'nightshade_bridge.dll', 'bak': '/tmp/x.nightshade-bak'},
            ],
            'created': <String>[],
            'created_dirs': <String>[],
          }),
        );

        final service = UpdateService(
          currentVersion: '2.1.0',
          currentBuildNumber: 42,
          applicationSupportDirectoryProvider: appSupportDir,
        );

        expect(await service.hasRestorePoint(), isTrue);
      },
    );

    test('rollbackToPrevious throws when no restore point exists', () async {
      final service = UpdateService(
        currentVersion: '2.1.0',
        currentBuildNumber: 42,
        applicationSupportDirectoryProvider: appSupportDir,
      );

      expect(
        () => service.rollbackToPrevious(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('No restore point'),
          ),
        ),
      );
    });
  });

  group('UpdateVerifier signature verification', () {
    test(
      'verifies canonical manifest signature with trusted public key',
      () async {
        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPair();
        final publicKey = await keyPair.extractPublicKey();

        final manifest = UpdateManifest(
          version: '2.1.0',
          buildNumber: 42,
          releaseDate: DateTime.utc(2026, 3, 13, 12),
          platform: 'windows',
          arch: 'x64',
          files: {
            'nightshade_desktop.exe': const UpdateFileInfo(
              path: 'nightshade_desktop.exe',
              size: 123,
              sha256: 'abc123',
            ),
          },
          totalSize: 123,
          compressedSize: 99,
          packageSha256: 'deadbeef',
          downloadUrl: 'https://example.com/nightshade.zip',
        );

        final payload = jsonEncode({
          'version': manifest.version,
          'buildNumber': manifest.buildNumber,
          'releaseDate': manifest.releaseDate.toUtc().toIso8601String(),
          'platform': manifest.platform,
          'arch': manifest.arch,
          'minVersion': manifest.minVersion,
          'files': {
            'nightshade_desktop.exe': {
              'path': 'nightshade_desktop.exe',
              'size': 123,
              'sha256': 'abc123',
            },
          },
          'totalSize': manifest.totalSize,
          'compressedSize': manifest.compressedSize,
          'packageSha256': manifest.packageSha256,
          'downloadUrl': manifest.downloadUrl,
          'releaseNotes': manifest.releaseNotes,
        });

        final signed = await algorithm.sign(
          utf8.encode(payload),
          keyPair: keyPair,
        );

        final signedManifest = manifest.copyWith(
          signature: base64Encode(signed.bytes),
        );

        final verifier = UpdateVerifier(
          trustedPublicKeyBase64: base64Encode(publicKey.bytes),
          signatureAlgorithm: algorithm,
        );

        expect(await verifier.verifyManifestSignature(signedManifest), isTrue);
      },
    );

    test(
      'rejects manifest file paths outside the extraction directory',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'nightshade_verify_test_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });

        final extractionDir = Directory(
          '${tempRoot.path}${Platform.pathSeparator}extracted',
        );
        await extractionDir.create(recursive: true);
        final outsideFile = File(
          '${tempRoot.path}${Platform.pathSeparator}outside.txt',
        );
        await outsideFile.writeAsString('outside');

        final verifier = UpdateVerifier();
        final manifest = UpdateManifest(
          version: '2.1.0',
          buildNumber: 42,
          releaseDate: DateTime.utc(2026, 3, 13, 12),
          platform: 'windows',
          arch: 'x64',
          files: {
            '../outside.txt': UpdateFileInfo(
              path: '../outside.txt',
              size: await outsideFile.length(),
              sha256: await verifier.hashFile(outsideFile),
            ),
          },
          totalSize: await outsideFile.length(),
          compressedSize: 99,
          packageSha256: 'deadbeef',
          downloadUrl: 'https://example.com/nightshade.zip',
        );

        final result = await verifier.verifyDirectory(extractionDir, manifest);

        expect(result.success, isFalse);
        expect(result.corruptedFiles, contains('../outside.txt'));
      },
    );
  });

  group('Safe update archive extraction', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'nightshade_archive_test_',
      );
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<File> writeZip(Archive archive) async {
      final packageFile = File(
        '${tempRoot.path}${Platform.pathSeparator}package.zip',
      );
      await packageFile.writeAsBytes(ZipEncoder().encode(archive)!);
      return packageFile;
    }

    test('extracts nested files inside the destination', () async {
      final content = utf8.encode('ok');
      final archive = Archive()
        ..addFile(ArchiveFile('bin/nightshade.txt', content.length, content));
      final zipFile = await writeZip(archive);
      final destination = Directory(
        '${tempRoot.path}${Platform.pathSeparator}extracted',
      );

      await extractZipSafely(zipFile, destination);

      final extracted = File(
        '${destination.path}${Platform.pathSeparator}bin${Platform.pathSeparator}nightshade.txt',
      );
      expect(await extracted.readAsString(), 'ok');
    });

    test(
      'rejects traversal entries before writing outside the destination',
      () async {
        final outsideFile = File(
          '${tempRoot.path}${Platform.pathSeparator}outside.txt',
        );
        final content = utf8.encode('bad');
        final archive = Archive()
          ..addFile(ArchiveFile('../outside.txt', content.length, content));
        final zipFile = await writeZip(archive);
        final destination = Directory(
          '${tempRoot.path}${Platform.pathSeparator}extracted',
        );

        expect(
          extractZipSafely(zipFile, destination),
          throwsA(isA<UnsafeArchiveEntryException>()),
        );
        expect(await outsideFile.exists(), isFalse);
      },
    );
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/lan_push_receiver.dart';
import 'package:skotiq_updater/src/services/update_service.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as path;

/// PERSIST-001: a LAN push that fully verifies (signature + size + per-file
/// hashes) must persist `manifest.json` and a matching
/// `staged_verified.marker` next to `ready.json`, otherwise
/// [UpdateService.applyUpdate] always throws 'Staged manifest is missing' /
/// 'missing the verified marker' and the staged build can never be applied.
///
/// These tests drive [LanPushReceiver.extractVerifyAndStage] — the verify +
/// stage tail of the receive protocol — directly. The socket front of
/// `_receiveUpdate` owns a single-subscription [Socket] that cannot be
/// re-driven in isolation on this host (re-listening a cancelled
/// `dart:io` Socket subscription throws), but the staging contract this
/// finding is about lives entirely in this tail.

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// A trusted public key is required only so the receiver can be constructed;
/// `extractVerifyAndStage` does not re-check the manifest signature (that
/// happens upstream in `_receiveUpdate`), it verifies the extracted tree.
Future<UpdateVerifier> _verifier() async => UpdateVerifier(
  trustedPublicKeyBase64: base64Encode(Uint8List.fromList(List.filled(32, 7))),
);

Uint8List _zipOf(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

UpdateManifest _manifest({
  required Uint8List packageBytes,
  required String fileName,
  required List<int> fileBytes,
  required String declaredSha256,
  String platform = 'linux',
  String arch = 'x64',
}) {
  return UpdateManifest(
    version: '1.1.0',
    buildNumber: 2,
    releaseDate: DateTime.utc(2026, 1, 1),
    platform: platform,
    arch: arch,
    files: {
      fileName: UpdateFileInfo(
        path: fileName,
        size: fileBytes.length,
        sha256: declaredSha256,
      ),
    },
    totalSize: fileBytes.length,
    compressedSize: packageBytes.length,
    packageSha256: _sha256Hex(packageBytes),
    downloadUrl: 'lan://push',
    // A signature is part of the manifest JSON the marker hashes over, so we
    // include a placeholder to prove the persisted handoff round-trips it.
    signature: base64Encode(Uint8List.fromList(List.filled(64, 9))),
  );
}

void main() {
  late Directory staging;
  late LanPushReceiver receiver;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('lan_push_staging_');
    receiver = LanPushReceiver(
      currentVersion: '1.0.0',
      currentBuildNumber: 1,
      pushSecret: 'secret',
      verifier: await _verifier(),
      currentPlatform: 'linux',
      currentArch: 'x64',
    );
  });

  tearDown(() async {
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  });

  File markerFile() => File(path.join(staging.path, 'staged_verified.marker'));
  File manifestFile() => File(path.join(staging.path, 'manifest.json'));
  File readyFile() => File(path.join(staging.path, 'ready.json'));

  test(
    'verified package persists manifest.json + a matching staged_verified.marker',
    () async {
      const fileName = 'payload.txt';
      final fileBytes = utf8.encode('skotiq payload v1.1.0');
      final packageBytes = _zipOf({fileName: fileBytes});
      final packageFile = File(path.join(staging.path, 'update.zip'));
      await packageFile.writeAsBytes(packageBytes);

      final manifest = _manifest(
        packageBytes: packageBytes,
        fileName: fileName,
        fileBytes: fileBytes,
        declaredSha256: _sha256Hex(fileBytes),
      );

      final extractPath = await receiver.extractVerifyAndStage(
        staging,
        packageFile,
        manifest,
        packageBytes.length,
      );

      expect(Directory(extractPath).existsSync(), isTrue);

      // ready.json must still be written (discovery marker; preserved).
      expect(await readyFile().exists(), isTrue);

      // manifest.json must be persisted so applyUpdate() can read it back.
      expect(
        await manifestFile().exists(),
        isTrue,
        reason: 'applyUpdate() reads manifest.json before touching the install',
      );
      final persisted = UpdateManifest.fromJson(
        jsonDecode(await manifestFile().readAsString()) as Map<String, dynamic>,
      );
      expect(persisted, equals(manifest));

      // The verified marker must match the staged manifest hash so
      // UpdateService._assertVerifiedMarkerMatches accepts the tree.
      expect(
        await markerFile().exists(),
        isTrue,
        reason: 'applyUpdate() refuses a tree without the verified marker',
      );
      final markerContent = (await markerFile().readAsString()).trim();
      expect(markerContent, equals(computeStagedManifestHash(manifest)));
    },
  );

  test(
    'a per-file verification failure leaves no staged_verified.marker',
    () async {
      const fileName = 'payload.txt';
      final fileBytes = utf8.encode('skotiq payload v1.1.0');
      final packageBytes = _zipOf({fileName: fileBytes});
      final packageFile = File(path.join(staging.path, 'update.zip'));
      await packageFile.writeAsBytes(packageBytes);

      // Declare a sha256 the extracted file will NOT match, forcing
      // verifyDirectory to fail — the path that must never write the marker.
      final manifest = _manifest(
        packageBytes: packageBytes,
        fileName: fileName,
        fileBytes: fileBytes,
        declaredSha256: 'f' * 64,
      );

      await expectLater(
        receiver.extractVerifyAndStage(
          staging,
          packageFile,
          manifest,
          packageBytes.length,
        ),
        throwsA(isA<Exception>()),
      );

      expect(
        await markerFile().exists(),
        isFalse,
        reason: 'the marker must only exist after full verification succeeds',
      );
      // manifest.json and ready.json are written in the same post-verify
      // block, so a verification failure must leave neither behind.
      expect(await manifestFile().exists(), isFalse);
      expect(await readyFile().exists(), isFalse);
    },
  );

  test(
    'a package for another host target is never extracted or staged',
    () async {
      const fileName = 'payload.txt';
      final fileBytes = utf8.encode('wrong platform payload');
      final packageBytes = _zipOf({fileName: fileBytes});
      final packageFile = File(path.join(staging.path, 'update.zip'));
      await packageFile.writeAsBytes(packageBytes);
      final manifest = _manifest(
        packageBytes: packageBytes,
        fileName: fileName,
        fileBytes: fileBytes,
        declaredSha256: _sha256Hex(fileBytes),
        platform: 'windows',
      );

      await expectLater(
        receiver.extractVerifyAndStage(
          staging,
          packageFile,
          manifest,
          packageBytes.length,
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('windows/x64'), contains('linux/x64')),
          ),
        ),
      );

      expect(
        await Directory(path.join(staging.path, 'extracted')).exists(),
        isFalse,
      );
      expect(await markerFile().exists(), isFalse);
      expect(await readyFile().exists(), isFalse);
    },
  );
}

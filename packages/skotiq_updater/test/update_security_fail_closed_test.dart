import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/update_downloader.dart';
import 'package:skotiq_updater/src/services/update_service.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';

/// OTA fails closed unless the staged update is cryptographically
/// authenticated to the vendor key. A correct SHA-256 against an
/// attacker-supplied (self-referential) manifest is NOT sufficient.
void main() {
  // Canonical signing payload — must match UpdateVerifier._canonicalManifestPayload.
  String canonicalPayload(UpdateManifest manifest) {
    final sortedFiles = manifest.files.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return jsonEncode(<String, dynamic>{
      'version': manifest.version,
      'buildNumber': manifest.buildNumber,
      'releaseDate': manifest.releaseDate.toUtc().toIso8601String(),
      'platform': manifest.platform,
      'arch': manifest.arch,
      'minVersion': manifest.minVersion,
      'files': {
        for (final entry in sortedFiles)
          entry.key: {
            'path': entry.value.path,
            'size': entry.value.size,
            'sha256': entry.value.sha256,
          },
      },
      'totalSize': manifest.totalSize,
      'compressedSize': manifest.compressedSize,
      'packageSha256': manifest.packageSha256,
      'downloadUrl': manifest.downloadUrl,
      'releaseNotes': manifest.releaseNotes,
    });
  }

  /// Build a one-file zip plus an [UpdateManifest] whose hashes/size match it.
  /// Returns the raw zip bytes and the (unsigned) manifest.
  ({Uint8List zipBytes, UpdateManifest manifest}) buildPackage(
    String downloadUrl,
  ) {
    final fileContent = utf8.encode('skotiq-payload');
    final fileSha = sha256.convert(fileContent).toString();

    final archive = Archive()
      ..addFile(ArchiveFile('app.txt', fileContent.length, fileContent));
    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final packageSha = sha256.convert(zipBytes).toString();

    final manifest = UpdateManifest(
      version: '2.1.0',
      buildNumber: 42,
      releaseDate: DateTime.utc(2026, 6, 27, 12),
      platform: 'windows',
      arch: 'x64',
      files: {
        'app.txt': UpdateFileInfo(
          path: 'app.txt',
          size: fileContent.length,
          sha256: fileSha,
        ),
      },
      totalSize: fileContent.length,
      compressedSize: zipBytes.length,
      packageSha256: packageSha,
      downloadUrl: downloadUrl,
    );
    return (zipBytes: zipBytes, manifest: manifest);
  }

  Future<UpdateManifest> sign(
    UpdateManifest manifest,
    Ed25519 algorithm,
    SimpleKeyPair keyPair,
  ) async {
    final signature = await algorithm.sign(
      utf8.encode(canonicalPayload(manifest)),
      keyPair: keyPair,
    );
    return manifest.copyWith(signature: base64Encode(signature.bytes));
  }

  group('verifyPackage signature is mandatory', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('skotiq_sec001_');
    });
    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<File> writePackage(Uint8List bytes) async {
      final file = File('${tempRoot.path}${Platform.pathSeparator}update.zip');
      await file.writeAsBytes(bytes);
      return file;
    }

    test('returns FALSE for a hash-correct but UNSIGNED package when a trusted '
        'key is configured', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();

      final pkg = buildPackage('https://example.invalid/app.zip');
      final file = await writePackage(pkg.zipBytes);

      final verifier = UpdateVerifier(
        trustedPublicKeyBase64: base64Encode(publicKey.bytes),
        signatureAlgorithm: algorithm,
      );

      // Hash + size are correct, but the manifest carries no signature.
      expect(await verifier.verifyPackage(file, pkg.manifest), isFalse);
    });

    test('returns FALSE for a hash-correct package when NO trusted key is '
        'configured (no silent hash-only acceptance)', () async {
      final pkg = buildPackage('https://example.invalid/app.zip');
      final file = await writePackage(pkg.zipBytes);

      // Empty trusted key == build cannot authenticate any update.
      final verifier = UpdateVerifier(trustedPublicKeyBase64: '');

      expect(await verifier.verifyPackage(file, pkg.manifest), isFalse);
    });

    test('returns TRUE for a correctly signed package (happy path)', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();

      final pkg = buildPackage('https://example.invalid/app.zip');
      final file = await writePackage(pkg.zipBytes);
      final signed = await sign(pkg.manifest, algorithm, keyPair);

      final verifier = UpdateVerifier(
        trustedPublicKeyBase64: base64Encode(publicKey.bytes),
        signatureAlgorithm: algorithm,
      );

      expect(await verifier.verifyPackage(file, signed), isTrue);
    });
  });

  group('downloadAndStage fails closed', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('skotiq_sec001_dl_');
    });
    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<Directory> appSupportDir() async => tempRoot;

    UpdateService serviceWith({
      required UpdateVerifier verifier,
      UpdateDownloader? downloader,
      bool allowInsecureUpdateSource = false,
    }) {
      return UpdateService(
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        verifier: verifier,
        downloader: downloader,
        applicationSupportDirectoryProvider: appSupportDir,
        allowInsecureUpdateSource: allowInsecureUpdateSource,
      );
    }

    test(
      'throws when SKOTIQ_UPDATE_PUBLIC_KEY is empty (OTA disabled)',
      () async {
        final pkg = buildPackage('https://example.invalid/app.zip');
        final service = serviceWith(
          verifier: UpdateVerifier(trustedPublicKeyBase64: ''),
        );

        await expectLater(
          () => service.downloadAndStage(pkg.manifest),
          throwsA(
            isA<UpdateException>().having(
              (e) => e.message,
              'message',
              contains('no trusted update'),
            ),
          ),
        );
        service.dispose();
      },
    );

    test('rejects a plaintext http:// download URL by default', () async {
      final pkg = buildPackage('http://example.invalid/app.zip');
      // Trusted key present so the failure is unambiguously the scheme.
      final service = serviceWith(
        verifier: UpdateVerifier(trustedPublicKeyBase64: 'dGVzdA=='),
      );

      await expectLater(
        () => service.downloadAndStage(pkg.manifest),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('insecure scheme'),
          ),
        ),
      );
      service.dispose();
    });

    test(
      'signed package over https stages successfully (happy path)',
      () async {
        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPair();
        final publicKey = await keyPair.extractPublicKey();

        const downloadUrl = 'https://example.invalid/app.zip';
        final pkg = buildPackage(downloadUrl);
        final signed = await sign(pkg.manifest, algorithm, keyPair);

        final client = MockClient((request) async {
          if (request.url.toString() == downloadUrl) {
            return http.Response.bytes(pkg.zipBytes, 200);
          }
          return http.Response('not found', 404);
        });

        final service = serviceWith(
          verifier: UpdateVerifier(
            trustedPublicKeyBase64: base64Encode(publicKey.bytes),
            signatureAlgorithm: algorithm,
          ),
          downloader: UpdateDownloader(client: client),
        );

        await service.downloadAndStage(signed);

        final staged = await service.getStagedUpdate();
        expect(staged, isNotNull);
        expect(staged!.version, '2.1.0');

        final marker = File(
          '${tempRoot.path}${Platform.pathSeparator}updates'
          '${Platform.pathSeparator}staging'
          '${Platform.pathSeparator}staged_verified.marker',
        );
        expect(await marker.exists(), isTrue);
        service.dispose();
      },
    );

    test(
      'http:// download is permitted only when allowInsecureUpdateSource is set',
      () async {
        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPair();
        final publicKey = await keyPair.extractPublicKey();

        const downloadUrl = 'http://localhost/app.zip';
        final pkg = buildPackage(downloadUrl);
        final signed = await sign(pkg.manifest, algorithm, keyPair);

        final client = MockClient((request) async {
          if (request.url.toString() == downloadUrl) {
            return http.Response.bytes(pkg.zipBytes, 200);
          }
          return http.Response('not found', 404);
        });

        final service = serviceWith(
          verifier: UpdateVerifier(
            trustedPublicKeyBase64: base64Encode(publicKey.bytes),
            signatureAlgorithm: algorithm,
          ),
          downloader: UpdateDownloader(client: client),
          allowInsecureUpdateSource: true,
        );

        await service.downloadAndStage(signed);

        final staged = await service.getStagedUpdate();
        expect(staged, isNotNull);
        expect(staged!.version, '2.1.0');
        service.dispose();
      },
    );
  });
}

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
import 'package:skotiq_updater/src/services/anti_freeze_store.dart';
import 'package:skotiq_updater/src/services/update_downloader.dart';
import 'package:skotiq_updater/src/services/update_service.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as p;

/// Anti-freeze / anti-rollback: a vendor-signed `releaseDate` must move
/// forward. A manifest older than the newest accepted release on a channel,
/// or implausibly far in the future, is refused — and the high-water mark is
/// advanced ONLY after a fully verified stage.
void main() {
  ({Uint8List zipBytes, UpdateManifest manifest}) buildPackage(
    String downloadUrl, {
    required DateTime releaseDate,
  }) {
    final fileContent = utf8.encode('skotiq-payload');
    final fileSha = sha256.convert(fileContent).toString();

    final archive = Archive()
      ..addFile(ArchiveFile('app.txt', fileContent.length, fileContent));
    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final packageSha = sha256.convert(zipBytes).toString();

    final manifest = UpdateManifest(
      version: '2.1.0',
      buildNumber: 42,
      releaseDate: releaseDate,
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
      utf8.encode(UpdateVerifier.canonicalManifestPayload(manifest)),
      keyPair: keyPair,
    );
    return manifest.copyWith(signature: base64Encode(signature.bytes));
  }

  group('AntiFreezeStore', () {
    late Directory tempRoot;
    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('sk_antifreeze_unit_');
    });
    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('watermark is null before any advance and is per-channel', () async {
      final store = AntiFreezeStore(() async => tempRoot);
      expect(await store.watermark('stable'), isNull);

      await store.advance('stable', DateTime.utc(2026, 6, 1));
      expect(await store.watermark('stable'), DateTime.utc(2026, 6, 1));
      expect(await store.watermark('beta'), isNull);
    });

    test('advance only moves forward', () async {
      final store = AntiFreezeStore(() async => tempRoot);
      await store.advance('stable', DateTime.utc(2026, 6, 10));
      await store.advance(
        'stable',
        DateTime.utc(2026, 6, 1),
      ); // older — ignored
      expect(await store.watermark('stable'), DateTime.utc(2026, 6, 10));

      await store.advance('stable', DateTime.utc(2026, 6, 20));
      expect(await store.watermark('stable'), DateTime.utc(2026, 6, 20));
    });
  });

  group('downloadAndStage anti-freeze enforcement', () {
    late Directory tempRoot;
    late Ed25519 algorithm;
    late SimpleKeyPair keyPair;
    late String publicKeyBase64;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('sk_antifreeze_dl_');
      algorithm = Ed25519();
      keyPair = await algorithm.newKeyPair();
      publicKeyBase64 = base64Encode((await keyPair.extractPublicKey()).bytes);
    });
    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<Directory> appSupportDir() async => tempRoot;

    UpdateService serviceWith(UpdateDownloader downloader) => UpdateService(
      currentVersion: '2.0.0',
      currentBuildNumber: 1,
      verifier: UpdateVerifier(
        trustedPublicKeyBase64: publicKeyBase64,
        signatureAlgorithm: algorithm,
      ),
      downloader: downloader,
      applicationSupportDirectoryProvider: appSupportDir,
    );

    UpdateDownloader downloaderFor(String url, Uint8List bytes) =>
        UpdateDownloader(
          client: MockClient((request) async {
            if (request.url.toString() == url) {
              return http.Response.bytes(bytes, 200);
            }
            return http.Response('not found', 404);
          }),
        );

    Future<DateTime?> persistedWatermark(String channel) =>
        AntiFreezeStore(appSupportDir).watermark(channel);

    test('advances the watermark only after a verified stage', () async {
      const url = 'https://example.invalid/app.zip';
      final pkg = buildPackage(url, releaseDate: DateTime.utc(2026, 6, 27, 12));
      final signed = await sign(pkg.manifest, algorithm, keyPair);
      final service = serviceWith(downloaderFor(url, pkg.zipBytes));

      expect(await persistedWatermark('stable'), isNull);
      await service.downloadAndStage(signed);
      expect(await persistedWatermark('stable'), DateTime.utc(2026, 6, 27, 12));
      service.dispose();
    });

    test('rejects a manifest older than the watermark (rollback)', () async {
      // Seed a high-water mark newer than the manifest we will offer.
      await AntiFreezeStore(
        appSupportDir,
      ).advance('stable', DateTime.utc(2026, 6, 28));

      const url = 'https://example.invalid/old.zip';
      final pkg = buildPackage(url, releaseDate: DateTime.utc(2026, 6, 20));
      final signed = await sign(pkg.manifest, algorithm, keyPair);
      final service = serviceWith(downloaderFor(url, pkg.zipBytes));

      await expectLater(
        () => service.downloadAndStage(signed),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            allOf(contains('anti-freeze'), contains('older than')),
          ),
        ),
      );
      // Watermark must NOT have been poisoned by the rejected manifest.
      expect(await persistedWatermark('stable'), DateTime.utc(2026, 6, 28));
      service.dispose();
    });

    test('rejects an implausibly future-dated manifest', () async {
      const url = 'https://example.invalid/future.zip';
      final future = DateTime.now().toUtc().add(const Duration(days: 30));
      final pkg = buildPackage(url, releaseDate: future);
      final signed = await sign(pkg.manifest, algorithm, keyPair);
      final service = serviceWith(downloaderFor(url, pkg.zipBytes));

      await expectLater(
        () => service.downloadAndStage(signed),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            allOf(contains('anti-freeze'), contains('ahead of this host')),
          ),
        ),
      );
      // A rejected future manifest must never become the watermark.
      expect(await persistedWatermark('stable'), isNull);
      service.dispose();
    });
  });

  test('anti_freeze.json lands under updates/', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'sk_antifreeze_loc_',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });
    final store = AntiFreezeStore(() async => tempRoot);
    await store.advance('stable', DateTime.utc(2026, 6, 1));
    final file = File(p.join(tempRoot.path, 'updates', 'anti_freeze.json'));
    expect(await file.exists(), isTrue);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((json['stable'] as Map)['maxReleaseDate'], isA<String>());
  });
}

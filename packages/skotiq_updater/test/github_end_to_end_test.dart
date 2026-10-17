// The whole chain a shipped build runs, in one go: ask GitHub what the newest
// release is, read the manifest it carries, download the package that manifest
// names, verify it against the vendor key, and stage it ready to apply.
//
// The other suites cover the halves separately — discovery against a mocked
// API, download/stage against a hand-built manifest. Neither would catch the
// two ways the halves can fail to meet: a manifest that discovery accepts but
// staging refuses, and a package URL that resolves in a test fixture but not
// from what the release actually published.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/github_release_source.dart';
import 'package:skotiq_updater/src/services/update_controller.dart';
import 'package:skotiq_updater/src/services/update_downloader.dart';
import 'package:skotiq_updater/src/services/update_service.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dataDir;
  late Ed25519 algorithm;
  late SimpleKeyPair vendorKey;
  late String vendorPublicKey;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('sk-ota-e2e-');
    algorithm = Ed25519();
    vendorKey = await algorithm.newKeyPair();
    vendorPublicKey = base64Encode((await vendorKey.extractPublicKey()).bytes);
  });

  tearDown(() async {
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  });

  /// Build a real zip holding a plausible Linux bundle.
  (List<int> zipBytes, Map<String, UpdateFileInfo> files, int totalSize)
  buildPackage() {
    final contents = <String, List<int>>{
      'skotiq_desktop': utf8.encode('desktop binary'),
      'updater': utf8.encode('updater binary'),
      'lib/libskotiq_bridge.so': utf8.encode('native bridge'),
    };

    final archive = Archive();
    final files = <String, UpdateFileInfo>{};
    var totalSize = 0;
    for (final entry in contents.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
      files[entry.key] = UpdateFileInfo(
        path: entry.key,
        size: entry.value.length,
        sha256: sha256.convert(entry.value).toString(),
      );
      totalSize += entry.value.length;
    }
    final zipBytes = ZipEncoder().encode(archive)!;
    return (zipBytes, files, totalSize);
  }

  Future<UpdateManifest> signManifest(UpdateManifest manifest) async {
    final signature = await algorithm.sign(
      utf8.encode(UpdateVerifier.canonicalManifestPayload(manifest)),
      keyPair: vendorKey,
    );
    return manifest.copyWith(signature: base64Encode(signature.bytes));
  }

  /// One mock standing in for both api.github.com and the release asset host,
  /// routed by URL exactly as the real ones are.
  MockClient routerFor({
    required Map<String, dynamic> releaseJson,
    required UpdateManifest manifest,
    required List<int> packageBytes,
  }) => MockClient((request) async {
    final url = request.url.toString();
    if (request.url.host == 'api.github.com') {
      return http.Response(jsonEncode(releaseJson), 200);
    }
    if (url.endsWith('manifest-linux-x64.json')) {
      return http.Response(jsonEncode(manifest.toJson()), 200);
    }
    if (url.endsWith('.zip')) {
      return http.Response.bytes(packageBytes, 200);
    }
    return http.Response('not found', 404);
  });

  test('a GitHub release is discovered, verified and staged', () async {
    final (packageBytes, files, totalSize) = buildPackage();
    const assetUrl =
        'https://github.com/o/r/releases/download/v7.2.0/skotiq-7.2.0-linux-x64.zip';

    final manifest = await signManifest(
      UpdateManifest(
        version: '7.2.0',
        buildNumber: 42,
        releaseDate: DateTime.utc(2026, 9, 20),
        platform: 'linux',
        arch: 'x64',
        files: files,
        totalSize: totalSize,
        compressedSize: packageBytes.length,
        packageSha256: sha256.convert(packageBytes).toString(),
        downloadUrl: assetUrl,
        releaseNotes: 'Terse manifest note',
      ),
    );

    final client = routerFor(
      releaseJson: {
        'tag_name': 'v7.2.0',
        'name': 'Skotiq v7.2.0',
        'body':
            'Guiding fix https://github.com/o/r/pull/412\n\n'
            '**Full Changelog**: https://github.com/o/r/compare/v7.1.0...v7.2.0',
        'published_at': '2026-09-20T12:00:00Z',
        'prerelease': false,
        'draft': false,
        'html_url': 'https://github.com/o/r/releases/tag/v7.2.0',
        'assets': [
          {
            'name': 'manifest-linux-x64.json',
            'browser_download_url':
                'https://github.com/o/r/releases/download/v7.2.0/manifest-linux-x64.json',
            'size': 900,
          },
          {
            'name': 'skotiq-7.2.0-linux-x64.zip',
            'browser_download_url': assetUrl,
            'size': packageBytes.length,
          },
        ],
      },
      manifest: manifest,
      packageBytes: packageBytes,
    );

    final service =
        UpdateService(
          currentVersion: '7.1.0',
          currentBuildNumber: 28,
          currentPlatform: 'linux',
          currentArch: 'x64',
          httpClient: client,
          downloader: UpdateDownloader(client: client),
          verifier: UpdateVerifier(trustedPublicKeyBase64: vendorPublicKey),
          applicationSupportDirectoryProvider: () async => dataDir,
        )..configureGithubSource(
          owner: 'o',
          repo: 'r',
          source: GithubReleaseSource(
            owner: 'o',
            repo: 'r',
            httpClient: client,
          ),
        );

    // 1. Discovery.
    final check = await service.checkForUpdates();
    expect(check.hasUpdate, isTrue);
    expect(check.availableVersion, '7.2.0');
    // The release body is what a human wrote, tidied; the manifest's own
    // note is left alone because it is inside the signed payload.
    expect(check.releaseNotes, 'Guiding fix #412');
    expect(check.manifest!.releaseNotes, 'Terse manifest note');

    // A paired phone asks through the controller (the headless API), and
    // must be shown the same notes. The rehearsal found it being handed the
    // manifest's one-line placeholder instead.
    final controller = UpdateController(
      service: service,
      currentVersion: '7.1.0',
      currentBuildNumber: 28,
      stateDirectory: dataDir,
    );
    final events = <UpdateEvent>[];
    final sub = controller.events.listen(events.add);
    final outcome = await controller.checkForUpdates();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(outcome.releaseNotes, 'Guiding fix #412');
    expect(
      events.whereType<UpdateAvailableEvent>().single.releaseNotes,
      'Guiding fix #412',
    );

    // 2. Download + verify + stage, through the real pipeline.
    final progress = <double>[];
    await service.downloadAndStage(
      check.manifest!,
      onProgress: (_, _, fraction) => progress.add(fraction),
    );

    // 3. What apply will find.
    final staged = await service.getStagedUpdate();
    expect(staged, isNotNull);
    expect(staged!.version, '7.2.0');
    expect(staged.buildNumber, 42);

    final extracted = Directory(staged.extractPath);
    expect(await extracted.exists(), isTrue);
    for (final path in files.keys) {
      expect(
        await File(p.join(extracted.path, path)).exists(),
        isTrue,
        reason: '$path should have been extracted',
      );
    }

    // The staged manifest must be the one that was verified, so apply-time
    // re-verification checks the same bytes.
    final stagedManifest = await service.readStagedManifest();
    expect(stagedManifest?.signature, manifest.signature);
    expect(progress, isNotEmpty);
  });

  test('a release whose package was swapped is refused before staging', () async {
    final (packageBytes, files, totalSize) = buildPackage();
    const assetUrl =
        'https://github.com/o/r/releases/download/v7.2.0/skotiq-7.2.0-linux-x64.zip';

    // The manifest is genuinely vendor-signed; only the served bytes differ,
    // which is what a compromised asset host looks like.
    final manifest = await signManifest(
      UpdateManifest(
        version: '7.2.0',
        buildNumber: 42,
        releaseDate: DateTime.utc(2026, 9, 20),
        platform: 'linux',
        arch: 'x64',
        files: files,
        totalSize: totalSize,
        compressedSize: packageBytes.length,
        packageSha256: sha256.convert(packageBytes).toString(),
        downloadUrl: assetUrl,
      ),
    );

    final tampered = [...packageBytes]..[packageBytes.length ~/ 2] ^= 0xFF;

    final client = routerFor(
      releaseJson: {
        'tag_name': 'v7.2.0',
        'assets': [
          {
            'name': 'manifest-linux-x64.json',
            'browser_download_url':
                'https://github.com/o/r/releases/download/v7.2.0/manifest-linux-x64.json',
            'size': 900,
          },
        ],
      },
      manifest: manifest,
      packageBytes: tampered,
    );

    final service =
        UpdateService(
          currentVersion: '7.1.0',
          currentBuildNumber: 28,
          currentPlatform: 'linux',
          currentArch: 'x64',
          httpClient: client,
          downloader: UpdateDownloader(client: client),
          verifier: UpdateVerifier(trustedPublicKeyBase64: vendorPublicKey),
          applicationSupportDirectoryProvider: () async => dataDir,
        )..configureGithubSource(
          owner: 'o',
          repo: 'r',
          source: GithubReleaseSource(
            owner: 'o',
            repo: 'r',
            httpClient: client,
          ),
        );

    final check = await service.checkForUpdates();
    expect(check.hasUpdate, isTrue);

    await expectLater(
      service.downloadAndStage(check.manifest!),
      throwsA(isA<UpdateException>()),
    );
    expect(
      await service.getStagedUpdate(),
      isNull,
      reason: 'nothing may be left staged for apply to pick up',
    );
  });

  test('a release signed by the wrong key never reaches disk', () async {
    final (packageBytes, files, totalSize) = buildPackage();
    const assetUrl =
        'https://github.com/o/r/releases/download/v7.2.0/skotiq-7.2.0-linux-x64.zip';

    // Signed by an attacker's key, with a package whose hash matches it — the
    // self-referential manifest the signature check exists to stop.
    final attackerKey = await algorithm.newKeyPair();
    final base = UpdateManifest(
      version: '7.2.0',
      buildNumber: 42,
      releaseDate: DateTime.utc(2026, 9, 20),
      platform: 'linux',
      arch: 'x64',
      files: files,
      totalSize: totalSize,
      compressedSize: packageBytes.length,
      packageSha256: sha256.convert(packageBytes).toString(),
      downloadUrl: assetUrl,
    );
    final forged = base.copyWith(
      signature: base64Encode(
        (await algorithm.sign(
          utf8.encode(UpdateVerifier.canonicalManifestPayload(base)),
          keyPair: attackerKey,
        )).bytes,
      ),
    );

    final client = routerFor(
      releaseJson: {
        'tag_name': 'v7.2.0',
        'assets': [
          {
            'name': 'manifest-linux-x64.json',
            'browser_download_url':
                'https://github.com/o/r/releases/download/v7.2.0/manifest-linux-x64.json',
            'size': 900,
          },
        ],
      },
      manifest: forged,
      packageBytes: packageBytes,
    );

    final service =
        UpdateService(
          currentVersion: '7.1.0',
          currentBuildNumber: 28,
          currentPlatform: 'linux',
          currentArch: 'x64',
          httpClient: client,
          downloader: UpdateDownloader(client: client),
          verifier: UpdateVerifier(trustedPublicKeyBase64: vendorPublicKey),
          applicationSupportDirectoryProvider: () async => dataDir,
        )..configureGithubSource(
          owner: 'o',
          repo: 'r',
          source: GithubReleaseSource(
            owner: 'o',
            repo: 'r',
            httpClient: client,
          ),
        );

    // Discovery does not authenticate — it is the download that must refuse.
    final check = await service.checkForUpdates();
    expect(check.hasUpdate, isTrue);

    await expectLater(
      service.downloadAndStage(check.manifest!),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('not signed by the Skotiq update key'),
        ),
      ),
    );
    expect(await service.getStagedUpdate(), isNull);
  });

  test('an unsigned release is refused by name, before its package is '
      'downloaded', () async {
    // What CI publishes while SKOTIQ_UPDATE_PRIVATE_KEY is unset, and what
    // the live v7.1.0 release carries. The rehearsal showed it refused with
    // "the download may be corrupted or tampered with" after pulling the
    // whole package: wrong on both counts.
    final (packageBytes, files, totalSize) = buildPackage();
    final unsigned = UpdateManifest(
      version: '7.2.0',
      buildNumber: 42,
      releaseDate: DateTime.utc(2026, 9, 20),
      platform: 'linux',
      arch: 'x64',
      files: files,
      totalSize: totalSize,
      compressedSize: packageBytes.length,
      packageSha256: sha256.convert(packageBytes).toString(),
      downloadUrl:
          'https://github.com/o/r/releases/download/v7.2.0/skotiq-7.2.0-linux-x64.zip',
    );
    final router = routerFor(
      releaseJson: {
        'tag_name': 'v7.2.0',
        'assets': [
          {
            'name': 'manifest-linux-x64.json',
            'browser_download_url':
                'https://github.com/o/r/releases/download/v7.2.0/manifest-linux-x64.json',
            'size': 900,
          },
        ],
      },
      manifest: unsigned,
      packageBytes: packageBytes,
    );
    final client = _CountingClient(router);

    final service =
        UpdateService(
          currentVersion: '7.1.0',
          currentBuildNumber: 28,
          currentPlatform: 'linux',
          currentArch: 'x64',
          httpClient: client,
          downloader: UpdateDownloader(client: client),
          verifier: UpdateVerifier(trustedPublicKeyBase64: vendorPublicKey),
          applicationSupportDirectoryProvider: () async => dataDir,
        )..configureGithubSource(
          owner: 'o',
          repo: 'r',
          source: GithubReleaseSource(
            owner: 'o',
            repo: 'r',
            httpClient: client,
          ),
        );

    final check = await service.checkForUpdates();
    await expectLater(
      service.downloadAndStage(check.manifest!),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('published without a signature'),
        ),
      ),
    );
    expect(client.packageRequests, 0);
    expect(await service.getStagedUpdate(), isNull);
  });

  test('a network failure leaves the app on its current build', () async {
    // The rig is often on a phone hotspot or entirely offline. A failed check
    // must surface as an error, never as a staged update or a claim of
    // currency that was never established.
    final client = MockClient(
      (_) async => throw const SocketException('no route to host'),
    );

    final service =
        UpdateService(
          currentVersion: '7.1.0',
          currentBuildNumber: 28,
          currentPlatform: 'linux',
          currentArch: 'x64',
          httpClient: client,
          downloader: UpdateDownloader(client: client),
          verifier: UpdateVerifier(trustedPublicKeyBase64: vendorPublicKey),
          applicationSupportDirectoryProvider: () async => dataDir,
        )..configureGithubSource(
          owner: 'o',
          repo: 'r',
          source: GithubReleaseSource(
            owner: 'o',
            repo: 'r',
            httpClient: client,
          ),
        );

    await expectLater(
      service.checkForUpdates(),
      throwsA(isA<UpdateException>()),
    );
    expect(await service.getStagedUpdate(), isNull);
  });
}

/// Passes requests through, counting the ones for a package.
class _CountingClient extends http.BaseClient {
  _CountingClient(this._inner);

  final http.Client _inner;
  int packageRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith('.zip')) packageRequests++;
    return _inner.send(request);
  }
}

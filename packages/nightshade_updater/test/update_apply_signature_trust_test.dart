import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_updater/src/models/update_manifest.dart';
import 'package:nightshade_updater/src/services/update_service.dart';
import 'package:nightshade_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as path;

/// Apply-time trust is bound to the vendor Ed25519 signature, not to a
/// self-recomputable manifest hash.
///
/// `sha256(manifest) == staged_verified.marker` is not enough on its own: an
/// attacker who can write the staging dir recomputes that hash after swapping
/// the manifest + extracted tree + marker. These tests stage trees on disk
/// directly (the exact bytes the HTTPS download and LAN-push paths persist via
/// [persistStagedManifest]) and drive [UpdateService.applyUpdate] to prove the
/// signature is the authoritative apply-time gate.
void main() {
  // Canonical signing payload — must match
  // UpdateVerifier._canonicalManifestPayload exactly.
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

  /// Build a manifest describing a single staged file plus that file's
  /// bytes, so the extracted tree can be made to match the manifest.
  ({UpdateManifest manifest, List<int> fileBytes}) buildManifest({
    required String fileName,
    required String fileContent,
  }) {
    final fileBytes = utf8.encode(fileContent);
    final manifest = UpdateManifest(
      version: '2.1.0',
      buildNumber: 42,
      releaseDate: DateTime.utc(2026, 6, 27, 12),
      platform: 'windows',
      arch: 'x64',
      files: {
        fileName: UpdateFileInfo(
          path: fileName,
          size: fileBytes.length,
          sha256: sha256.convert(fileBytes).toString(),
        ),
      },
      totalSize: fileBytes.length,
      compressedSize: fileBytes.length,
      packageSha256: 'a' * 64,
      downloadUrl: 'https://example.invalid/app.zip',
    );
    return (manifest: manifest, fileBytes: fileBytes);
  }

  late Directory appSupport;

  setUp(() async {
    appSupport = await Directory.systemTemp.createTemp('ns_persist001_');
  });
  tearDown(() async {
    if (await appSupport.exists()) {
      await appSupport.delete(recursive: true);
    }
  });

  Future<Directory> appSupportDir() async => appSupport;

  UpdateService serviceWith(UpdateVerifier verifier) => UpdateService(
    currentVersion: '2.0.0',
    currentBuildNumber: 1,
    verifier: verifier,
    applicationSupportDirectoryProvider: appSupportDir,
  );

  /// Materialise a staging tree on disk exactly as the download / LAN-push
  /// paths do: extracted/<files>, manifest.json, staged_verified.marker
  /// (= sha256(manifest)), and ready.json. The marker is always written to
  /// match [markerManifest], modelling an attacker who recomputes it.
  Future<Directory> stageTree({
    required UpdateManifest markerManifest,
    required String fileName,
    required List<int> fileBytes,
  }) async {
    final staging = Directory(path.join(appSupport.path, 'updates', 'staging'));
    final extracted = Directory(path.join(staging.path, 'extracted'));
    await extracted.create(recursive: true);
    await File(path.join(extracted.path, fileName)).writeAsBytes(fileBytes);

    // manifest.json + staged_verified.marker (marker = sha256(manifest)).
    await persistStagedManifest(staging, markerManifest);

    await File(path.join(staging.path, 'ready.json')).writeAsString(
      jsonEncode({
        'version': markerManifest.version,
        'buildNumber': markerManifest.buildNumber,
        'stagedAt': DateTime.now().toIso8601String(),
        'extractPath': extracted.path,
      }),
    );
    return staging;
  }

  File expectedHashesFile(Directory staging) =>
      File(path.join(staging.path, 'expected_hashes.json'));

  test(
    'rejects a staged tree whose manifest + marker were recomputed WITHOUT a '
    'valid signature (hash-only forgery)',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();

      // Attacker swaps in their own file + an UNSIGNED manifest whose
      // files{} hashes match, then recomputes the marker over it. The
      // marker check (sha256(manifest)) passes — only the signature gate
      // can catch this.
      final pkg = buildManifest(
        fileName: 'app.txt',
        fileContent: 'attacker-controlled-payload',
      );
      final tampered = pkg.manifest; // no signature
      final staging = await stageTree(
        markerManifest: tampered,
        fileName: 'app.txt',
        fileBytes: pkg.fileBytes,
      );

      // Sanity: the marker genuinely matches the tampered manifest, so the
      // legacy hash-only check would have accepted this tree.
      final marker = (await File(
        path.join(staging.path, 'staged_verified.marker'),
      ).readAsString()).trim();
      expect(marker, equals(computeStagedManifestHash(tampered)));

      final service = serviceWith(
        UpdateVerifier(
          trustedPublicKeyBase64: base64Encode(publicKey.bytes),
          signatureAlgorithm: algorithm,
        ),
      );

      await expectLater(
        service.applyUpdate(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('signature re-verification'),
          ),
        ),
      );

      // Fail-closed proof: it must not have written expected_hashes.json
      // (the data the updater consumes) before rejecting.
      expect(await expectedHashesFile(staging).exists(), isFalse);
      service.dispose();
    },
  );

  test(
    'rejects a validly signed staged tree when this build has NO trusted key '
    '(fail closed)',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();

      final pkg = buildManifest(
        fileName: 'app.txt',
        fileContent: 'nightshade-payload',
      );
      final signed = await sign(pkg.manifest, algorithm, keyPair);
      final staging = await stageTree(
        markerManifest: signed,
        fileName: 'app.txt',
        fileBytes: pkg.fileBytes,
      );

      // Build with no compiled-in trusted key cannot authenticate anything.
      final service = serviceWith(UpdateVerifier(trustedPublicKeyBase64: ''));

      await expectLater(
        service.applyUpdate(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('no trusted update'),
          ),
        ),
      );
      expect(await expectedHashesFile(staging).exists(), isFalse);
      service.dispose();
    },
  );

  test(
    'a validly signed, untampered staged tree passes the apply-time signature '
    'gate (happy path proceeds past verification)',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();

      final pkg = buildManifest(
        fileName: 'app.txt',
        fileContent: 'nightshade-payload',
      );
      final signed = await sign(pkg.manifest, algorithm, keyPair);
      final staging = await stageTree(
        markerManifest: signed,
        fileName: 'app.txt',
        fileBytes: pkg.fileBytes,
      );

      final service = serviceWith(
        UpdateVerifier(
          trustedPublicKeyBase64: base64Encode(publicKey.bytes),
          signatureAlgorithm: algorithm,
        ),
      );

      // applyUpdate exit(0)s only once it actually launches the updater.
      // With no updater.exe in the install dir or staging tree it throws
      // 'Updater executable not found' — which proves it got PAST the
      // signature gate (the message is NOT a signature/trust rejection) and
      // wrote expected_hashes.json from the verified manifest.
      await expectLater(
        service.applyUpdate(),
        throwsA(
          isA<UpdateException>()
              .having(
                (e) => e.message,
                'message',
                contains('Updater executable not found'),
              )
              .having(
                (e) => e.message,
                'message',
                isNot(contains('signature')),
              ),
        ),
      );

      expect(
        await expectedHashesFile(staging).exists(),
        isTrue,
        reason: 'a verified tree must reach expected_hashes.json generation',
      );
      service.dispose();
    },
  );

  test('an install this user cannot write to is refused while the app is still '
      'running', () async {
    // The rehearsal: with the install read-only (the appliance unit's
    // ProtectSystem=strict, or a tarball unpacked into /opt by root), the
    // app exited for the swap, the updater could not write, and nothing
    // came back. The refusal has to happen before the app exits.
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final pkg = buildManifest(fileName: 'app.txt', fileContent: 'payload');
    final signed = await sign(
      pkg.manifest.copyWith(platform: Platform.operatingSystem),
      algorithm,
      keyPair,
    );
    await stageTree(
      markerManifest: signed,
      fileName: 'app.txt',
      fileBytes: pkg.fileBytes,
    );

    final install = Directory(path.join(appSupport.path, 'install'));
    await install.create();
    await File(
      path.join(install.path, updaterExecutableName),
    ).writeAsString('updater');
    await Process.run('chmod', ['0555', install.path]);
    addTearDown(() => Process.run('chmod', ['0755', install.path]));

    final service = UpdateService(
      currentVersion: '2.0.0',
      currentBuildNumber: 1,
      currentPlatform: Platform.operatingSystem,
      verifier: UpdateVerifier(
        trustedPublicKeyBase64: base64Encode(publicKey.bytes),
        signatureAlgorithm: algorithm,
      ),
      applicationSupportDirectoryProvider: appSupportDir,
      installDirectoryProvider: () async => install,
    );

    await expectLater(
      service.applyUpdate(),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          allOf(contains('cannot write to'), contains('left running')),
        ),
      ),
    );
    expect(
      await File(
        path.join(appSupport.path, 'updates', 'pending_install.json'),
      ).exists(),
      isFalse,
      reason: 'nothing may claim an update is in flight',
    );
    expect(await service.getStagedUpdate(), isNotNull);
    service.dispose();
  }, skip: Platform.isWindows ? 'Windows installs elevate instead' : false);

  test('the updater is told to start the app the way it was started', () {
    // A headless rig started with --headless --port=... came back as the GUI
    // after an update, because the updater relaunched it with no arguments.
    setUpdateRelaunchArguments(['--headless', '--port=18931', 'plain']);
    addTearDown(() => setUpdateRelaunchArguments(const []));
    expect(updaterRelaunchFlags(), [
      '--relaunch-arg=--headless',
      '--relaunch-arg=--port=18931',
      '--relaunch-arg=plain',
    ]);
  });
}

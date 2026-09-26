// The packaging tool and the runtime verifier have to agree byte-for-byte or
// OTA fails closed on every platform at once: the manifest is signed over
// UpdateVerifier.canonicalManifestPayload, so any drift in how the tool builds
// a manifest breaks verification silently at release time rather than at build
// time. These tests run the real tool and hand its output to the real
// verifier.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_updater/src/models/update_manifest.dart';
import 'package:nightshade_updater/src/services/archive_extraction.dart';
import 'package:nightshade_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as p;

/// Ed25519 seed + public key committed for dev signing. Not a release key.
late final String _privateSeed;
late final String _publicKey;

String _packageRoot() {
  // Tests run with the package root as CWD.
  return Directory.current.path;
}

Future<ProcessResult> _runTool(List<String> args, {String? privateKey}) async {
  return Process.run(
    'dart',
    ['run', p.join('tool', 'build_update_manifest.dart'), ...args],
    environment: {
      if (privateKey != null) 'NIGHTSHADE_UPDATE_PRIVATE_KEY': privateKey,
    },
    workingDirectory: _packageRoot(),
  );
}

void main() {
  setUpAll(() {
    final keysDir = p.join(_packageRoot(), 'test', 'fixtures', 'dev_keys');
    _privateSeed = File(
      p.join(keysDir, 'dev_update_private_key.b64'),
    ).readAsStringSync().trim();
    _publicKey = File(
      p.join(keysDir, 'dev_update_public_key.b64'),
    ).readAsStringSync().trim();
  });

  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('ns-manifest-tool-');
  });

  tearDown(() async {
    if (await work.exists()) await work.delete(recursive: true);
  });

  Future<Directory> seedPayload() async {
    final payload = Directory(p.join(work.path, 'payload'));
    await Directory(p.join(payload.path, 'lib')).create(recursive: true);
    await File(
      p.join(payload.path, 'nightshade_desktop'),
    ).writeAsString('desktop binary bytes');
    await File(
      p.join(payload.path, 'lib', 'libbridge.so'),
    ).writeAsString('native bridge bytes');
    return payload;
  }

  UpdateManifest readManifest(String path) => UpdateManifest.fromJson(
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
  );

  test(
    'a signed directory package verifies end to end',
    () async {
      final payload = await seedPayload();
      final dist = p.join(work.path, 'dist');

      final result = await _runTool([
        '--payload',
        payload.path,
        '--out-dir',
        dist,
        '--version',
        '7.2.0',
        '--build-number',
        '42',
        '--platform',
        'linux',
        '--arch',
        'x64',
        '--download-url',
        'https://github.com/Scdouglas1999/Nightshade/releases/download/v7.2.0/nightshade-7.2.0-linux-x64.zip',
      ], privateKey: _privateSeed);

      expect(
        result.exitCode,
        0,
        reason: 'tool failed: ${result.stdout}\n${result.stderr}',
      );

      final manifest = readManifest(p.join(dist, 'manifest-linux-x64.json'));
      expect(manifest.version, '7.2.0');
      expect(manifest.buildNumber, 42);
      expect(manifest.platform, 'linux');
      expect(manifest.arch, 'x64');
      expect(manifest.signature, isNotNull);

      final verifier = UpdateVerifier(trustedPublicKeyBase64: _publicKey);

      // The signature the tool produced must verify under the exact canonical
      // payload the shipped verifier builds.
      expect(await verifier.verifyManifestSignature(manifest), isTrue);

      // ...and the archive it produced must match the sizes and hashes the
      // manifest claims, which is what downloadAndStage checks.
      final zip = File(p.join(dist, 'nightshade-7.2.0-linux-x64.zip'));
      expect(await verifier.verifyPackage(zip, manifest), isTrue);

      // ...and unpacking it must reproduce every file the manifest names.
      final extracted = Directory(p.join(work.path, 'extracted'));
      await extracted.create(recursive: true);
      await extractZipSafely(zip, extracted);
      final verification = await verifier.verifyDirectory(extracted, manifest);
      expect(
        verification.success,
        isTrue,
        reason:
            'missing=${verification.missingFiles} '
            'corrupt=${verification.corruptedFiles}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'manifest file paths use POSIX separators for nested files',
    () async {
      final payload = await seedPayload();
      final dist = p.join(work.path, 'dist');

      await _runTool([
        '--payload',
        payload.path,
        '--out-dir',
        dist,
        '--version',
        '7.2.0',
        '--build-number',
        '42',
        '--platform',
        'linux',
        '--arch',
        'x64',
        '--download-url',
        'https://example.invalid/pkg.zip',
      ], privateKey: _privateSeed);

      final manifest = readManifest(p.join(dist, 'manifest-linux-x64.json'));
      // A Windows-built manifest keyed with backslashes would miss every nested
      // file when verified on the target.
      expect(manifest.files.keys, contains('lib/libbridge.so'));
      expect(manifest.files.keys.any((k) => k.contains(r'\')), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'an APK payload becomes its own package',
    () async {
      final apk = File(p.join(work.path, 'nightshade-7.2.0-arm64-v8a.apk'));
      await apk.writeAsString('apk bytes');
      final dist = p.join(work.path, 'dist');

      final result = await _runTool([
        '--payload',
        apk.path,
        '--out-dir',
        dist,
        '--version',
        '7.2.0',
        '--build-number',
        '42',
        '--platform',
        'android',
        '--arch',
        'arm64',
        '--download-url',
        'https://github.com/Scdouglas1999/Nightshade/releases/download/v7.2.0/nightshade-7.2.0-android-arm64-v8a.apk',
      ], privateKey: _privateSeed);

      expect(
        result.exitCode,
        0,
        reason: 'tool failed: ${result.stdout}\n${result.stderr}',
      );

      final manifest = readManifest(
        p.join(dist, 'manifest-android-arm64.json'),
      );
      expect(manifest.platform, 'android');
      expect(manifest.arch, 'arm64');
      // The APK is the package: nothing is zipped, so the compressed size is
      // the APK's own size and the package hash is the APK's own hash.
      expect(manifest.compressedSize, await apk.length());
      expect(manifest.totalSize, await apk.length());

      final verifier = UpdateVerifier(trustedPublicKeyBase64: _publicKey);
      expect(await verifier.verifyManifestSignature(manifest), isTrue);
      expect(await verifier.verifyPackage(apk, manifest), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'without a signing key the manifest is written unsigned',
    () async {
      final payload = await seedPayload();
      final dist = p.join(work.path, 'dist');

      // A release built with no key must still build. OTA then refuses the
      // download, which is the fail-closed posture the rest of the package
      // already takes.
      final result = await _runTool([
        '--payload',
        payload.path,
        '--out-dir',
        dist,
        '--version',
        '7.2.0',
        '--build-number',
        '42',
        '--platform',
        'linux',
        '--arch',
        'x64',
        '--download-url',
        'https://example.invalid/pkg.zip',
      ]);

      expect(result.exitCode, 0);
      final manifest = readManifest(p.join(dist, 'manifest-linux-x64.json'));
      expect(manifest.signature, isNull);

      final verifier = UpdateVerifier(trustedPublicKeyBase64: _publicKey);
      expect(await verifier.verifyManifestSignature(manifest), isFalse);
      expect(
        await verifier.verifyPackage(
          File(p.join(dist, 'nightshade-7.2.0-linux-x64.zip')),
          manifest,
        ),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a tampered package no longer matches its signed manifest',
    () async {
      final payload = await seedPayload();
      final dist = p.join(work.path, 'dist');

      await _runTool([
        '--payload',
        payload.path,
        '--out-dir',
        dist,
        '--version',
        '7.2.0',
        '--build-number',
        '42',
        '--platform',
        'linux',
        '--arch',
        'x64',
        '--download-url',
        'https://example.invalid/pkg.zip',
      ], privateKey: _privateSeed);

      final manifest = readManifest(p.join(dist, 'manifest-linux-x64.json'));
      final zip = File(p.join(dist, 'nightshade-7.2.0-linux-x64.zip'));
      await zip.writeAsBytes([...await zip.readAsBytes(), 0x00]);

      final verifier = UpdateVerifier(trustedPublicKeyBase64: _publicKey);
      // The manifest still verifies — it was not touched — but the bytes it
      // describes no longer match, which is the case a corrupted or swapped
      // download presents.
      expect(await verifier.verifyManifestSignature(manifest), isTrue);
      expect(await verifier.verifyPackage(zip, manifest), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'executable bits survive packaging and extraction on POSIX hosts',
    () async {
      // The Linux updater copies each staged file into the install directory
      // with the mode it has in staging. A zip unpacked without its modes
      // lands every file as 0644, so the updated nightshade_desktop, the
      // `nightshade` launcher and the `updater` itself could no longer be
      // executed: a verified, hash-perfect update that leaves the install
      // unable to start.
      final payload = await seedPayload();
      final launcher = File(p.join(payload.path, 'nightshade'));
      await launcher.writeAsString('#!/bin/sh\nexit 0\n');
      final chmod = await Process.run('chmod', [
        '0755',
        launcher.path,
        p.join(payload.path, 'nightshade_desktop'),
      ]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');

      final dist = p.join(work.path, 'dist');
      final result = await _runTool([
        '--payload',
        payload.path,
        '--out-dir',
        dist,
        '--version',
        '7.2.0',
        '--build-number',
        '42',
        '--platform',
        'linux',
        '--arch',
        'x64',
        '--download-url',
        'https://example.invalid/pkg.zip',
      ], privateKey: _privateSeed);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      final extracted = Directory(p.join(work.path, 'extracted'));
      await extractZipSafely(
        File(p.join(dist, 'nightshade-7.2.0-linux-x64.zip')),
        extracted,
      );

      int modeOf(String relative) =>
          File(p.join(extracted.path, relative)).statSync().mode & 0x1FF;

      expect(
        modeOf('nightshade_desktop') & 0x49,
        isNot(0),
        reason:
            'nightshade_desktop unpacked as '
            '0${modeOf('nightshade_desktop').toRadixString(8)}',
      );
      expect(modeOf('nightshade') & 0x49, isNot(0));
      // A plain data file must not gain an executable bit it never had.
      expect(modeOf('lib/libbridge.so') & 0x49, 0);
    },
    skip: Platform.isWindows ? 'POSIX file modes only' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

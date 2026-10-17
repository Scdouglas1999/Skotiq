// DEV-ONLY signer that emits a sample signed UpdateManifest for local
// OTA-update testing. Reads the dev private seed produced by
// tool/generate_dev_keypair.dart, signs a tiny one-file manifest with the
// SAME canonical payload production verification uses
// (UpdateVerifier.canonicalManifestPayload), and writes
// test/fixtures/dev_keys/sample_manifest.signed.json. Run from the package
// root AFTER generate_dev_keypair.dart:
//
//   dart run tool/sign_dev_manifest.dart
//
// Reusing the public canonical builder guarantees the fixture verifies under
// the exact code path a release build runs. DEV-ONLY — not a real release.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final packageRoot = File.fromUri(Platform.script).parent.parent.path;
  final keysDir = Directory(
    p.join(packageRoot, 'test', 'fixtures', 'dev_keys'),
  );
  final privateFile = File(p.join(keysDir.path, 'dev_update_private_key.b64'));

  if (!await privateFile.exists()) {
    stderr.writeln(
      'Missing ${privateFile.path}. Run generate_dev_keypair.dart first.',
    );
    exit(1);
  }

  final seed = base64Decode((await privateFile.readAsString()).trim());
  if (seed.length != 32) {
    stderr.writeln('Expected a 32-byte Ed25519 seed, got ${seed.length}.');
    exit(1);
  }

  // Mirror buildPackage() in update_security_fail_closed_test.dart: a single
  // file whose sha256/size match the bytes, so the manifest is self-consistent.
  final fileContent = utf8.encode('skotiq-dev-payload');
  final fileSha = sha256.convert(fileContent).toString();

  final manifest = UpdateManifest(
    version: '6.0.0',
    buildNumber: 600,
    releaseDate: DateTime.utc(2026, 6, 29, 12),
    platform: 'windows',
    arch: 'x64',
    minVersion: '2.0.0',
    files: {
      'app.txt': UpdateFileInfo(
        path: 'app.txt',
        size: fileContent.length,
        sha256: fileSha,
      ),
    },
    totalSize: fileContent.length,
    compressedSize: fileContent.length,
    packageSha256: sha256.convert(fileContent).toString(),
    downloadUrl: 'https://updates.skotiq.app/dev/sample/app.zip',
    releaseNotes: 'DEV-ONLY sample signed manifest for local update testing.',
  );

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final signature = await algorithm.sign(
    utf8.encode(UpdateVerifier.canonicalManifestPayload(manifest)),
    keyPair: keyPair,
  );
  final signed = manifest.copyWith(signature: base64Encode(signature.bytes));

  final outFile = File(p.join(keysDir.path, 'sample_manifest.signed.json'));
  await outFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(signed.toJson()),
  );
  stdout.writeln('Wrote signed sample manifest: ${outFile.path}');
}

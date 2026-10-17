// DEV-ONLY Ed25519 keypair generator for local OTA-update testing.
//
// Writes a base64 public key and a base64 32-byte private seed into
// test/fixtures/dev_keys/. These keys are NEVER baked into a release build —
// production sources SKOTIQ_UPDATE_PUBLIC_KEY from the owner GitHub
// Secret only (see scripts/package_windows.ps1). Run from the package root:
//
//   dart run tool/generate_dev_keypair.dart
//
// The seed format (32-byte raw seed, base64) matches what
// scripts/build_update_package.ps1 consumes via newKeyPairFromSeed.

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final seed = await keyPair.extractPrivateKeyBytes();

  if (seed.length != 32) {
    stderr.writeln('Expected a 32-byte Ed25519 seed, got ${seed.length}.');
    exit(1);
  }

  final packageRoot = File.fromUri(Platform.script).parent.parent.path;
  final outDir = Directory(p.join(packageRoot, 'test', 'fixtures', 'dev_keys'));
  await outDir.create(recursive: true);

  final publicFile = File(p.join(outDir.path, 'dev_update_public_key.b64'));
  final privateFile = File(p.join(outDir.path, 'dev_update_private_key.b64'));
  await publicFile.writeAsString(base64Encode(publicKey.bytes));
  await privateFile.writeAsString(base64Encode(seed));

  stdout.writeln('Wrote dev keypair:');
  stdout.writeln('  public:  ${publicFile.path}');
  stdout.writeln('  private: ${privateFile.path}');
  stdout.writeln('DEV-ONLY — never use these keys for a release build.');
}

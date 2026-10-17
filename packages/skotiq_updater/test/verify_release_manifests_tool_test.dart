// The last check before a release is published: would a shipped build accept
// what is attached? Each case here is a release CI could build and publish
// without complaint that every installed build would then refuse, or that
// would install something other than what was attached.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';
import 'package:path/path.dart' as p;

import '../tool/verify_release_manifests.dart';

void main() {
  const tag = 'v7.2.0';
  const repo = 'o/r';
  late Directory assets;
  late SimpleKeyPair key;
  late String publicKey;
  final algorithm = Ed25519();

  setUp(() async {
    assets = await Directory.systemTemp.createTemp('sk-verify-release-');
    key = await algorithm.newKeyPair();
    publicKey = base64Encode((await key.extractPublicKey()).bytes);
  });

  tearDown(() async {
    if (await assets.exists()) await assets.delete(recursive: true);
  });

  Future<UpdateManifest> publish({
    String platform = 'linux',
    String arch = 'x64',
    String? manifestName,
    SimpleKeyPair? signWith,
    bool sign = true,
    String? downloadUrl,
  }) async {
    final asset = 'skotiq-7.2.0-$platform-$arch.zip';
    final bytes = utf8.encode('package for $platform/$arch');
    await File(p.join(assets.path, asset)).writeAsBytes(bytes);
    var manifest = UpdateManifest(
      version: '7.2.0',
      buildNumber: 42,
      releaseDate: DateTime.utc(2026, 9, 27),
      platform: platform,
      arch: arch,
      files: const {},
      totalSize: bytes.length,
      compressedSize: bytes.length,
      packageSha256: sha256.convert(bytes).toString(),
      downloadUrl:
          downloadUrl ??
          'https://github.com/$repo/releases/download/$tag/$asset',
    );
    if (sign) {
      final signature = await algorithm.sign(
        utf8.encode(UpdateVerifier.canonicalManifestPayload(manifest)),
        keyPair: signWith ?? key,
      );
      manifest = manifest.copyWith(signature: base64Encode(signature.bytes));
    }
    await File(
      p.join(assets.path, manifestName ?? 'manifest-$platform-$arch.json'),
    ).writeAsString(jsonEncode(manifest.toJson()));
    return manifest;
  }

  Future<List<String>> verify({String? withKey, bool requireSigned = true}) =>
      verifyReleaseManifests(
        assetsDir: assets,
        tag: tag,
        repo: repo,
        publicKeyBase64: withKey ?? publicKey,
        requireSigned: requireSigned,
      );

  test('a release every target can install passes', () async {
    await publish();
    await publish(platform: 'windows');
    await publish(platform: 'android', arch: 'arm64');
    expect(await verify(), isEmpty);
  });

  test(
    'a signing key that does not pair with the compiled-in key fails',
    () async {
      // The provisioning mistake that cannot be undone by an update: every
      // build from this release on would refuse every later release.
      await publish(signWith: await algorithm.newKeyPair());
      final problems = await verify();
      expect(problems.single, contains('does not verify'));
    },
  );

  test('a signed release with no public key compiled in fails', () async {
    await publish();
    final problems = await verify(withKey: '');
    expect(problems.single, contains('SKOTIQ_UPDATE_PUBLIC_KEY is empty'));
  });

  test(
    'unsigned manifests pass only while no signing key is configured',
    () async {
      await publish(sign: false);
      expect(await verify(requireSigned: false), isEmpty);
      expect((await verify()).single, contains('unsigned'));
    },
  );

  test('a package swapped after signing fails', () async {
    await publish();
    await File(
      p.join(assets.path, 'skotiq-7.2.0-linux-x64.zip'),
    ).writeAsString('package for linux/x6X');
    expect((await verify()).single, contains('does not match the attached'));
  });

  test('a manifest published under another target name fails', () async {
    await publish(platform: 'windows', manifestName: 'manifest-linux-x64.json');
    expect((await verify()).single, contains('describes windows/x64'));
  });

  test('a download URL that is not this release fails', () async {
    await publish(
      downloadUrl:
          'https://github.com/$repo/releases/download/v7.1.0/skotiq-7.2.0-linux-x64.zip',
    );
    expect((await verify()).single, contains("not this release's asset"));
  });
}

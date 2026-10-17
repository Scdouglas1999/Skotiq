import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';

/// Key rotation + revocation: the verifier trusts an ordered set of keys
/// (a `primary` and an optional `next` for rotation overlap), accepts a
/// signature from any non-revoked key, and treats a key id present in the
/// revocation set as untrusted — keyed on the key that actually verifies,
/// never on an id the manifest claims.
void main() {
  UpdateManifest baseManifest() {
    final fileContent = utf8.encode('skotiq-payload');
    return UpdateManifest(
      version: '6.0.0',
      buildNumber: 600,
      releaseDate: DateTime.utc(2026, 6, 29, 12),
      platform: 'windows',
      arch: 'x64',
      files: {
        'app.txt': UpdateFileInfo(
          path: 'app.txt',
          size: fileContent.length,
          sha256: sha256.convert(fileContent).toString(),
        ),
      },
      totalSize: fileContent.length,
      compressedSize: fileContent.length,
      packageSha256: sha256.convert(fileContent).toString(),
      downloadUrl: 'https://example.invalid/app.zip',
    );
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

  late Ed25519 algorithm;
  late SimpleKeyPair primaryPair;
  late SimpleKeyPair nextPair;
  late String primaryB64;
  late String nextB64;

  setUp(() async {
    algorithm = Ed25519();
    primaryPair = await algorithm.newKeyPair();
    nextPair = await algorithm.newKeyPair();
    primaryB64 = base64Encode((await primaryPair.extractPublicKey()).bytes);
    nextB64 = base64Encode((await nextPair.extractPublicKey()).bytes);
  });

  test('accepts a signature from the primary OR the next key', () async {
    final verifier = UpdateVerifier(
      trustedPublicKeyBase64: primaryB64,
      primaryKeyId: 'k1',
      nextTrustedPublicKeyBase64: nextB64,
      nextKeyId: 'k2',
      signatureAlgorithm: algorithm,
    );

    final byPrimary = await sign(baseManifest(), algorithm, primaryPair);
    final byNext = await sign(baseManifest(), algorithm, nextPair);

    expect(await verifier.verifyManifestSignature(byPrimary), isTrue);
    expect(await verifier.verifyManifestSignature(byNext), isTrue);
    expect(await verifier.verifyingKeyId(byPrimary), 'k1');
    expect(await verifier.verifyingKeyId(byNext), 'k2');
  });

  test('rejects when the verifying key id is revoked', () async {
    final byNext = await sign(baseManifest(), algorithm, nextPair);

    // Revoke the next key; only the primary remains trusted, and it did not
    // sign this manifest.
    final verifier = UpdateVerifier(
      trustedPublicKeyBase64: primaryB64,
      primaryKeyId: 'k1',
      nextTrustedPublicKeyBase64: nextB64,
      nextKeyId: 'k2',
      revokedKeyIds: const {'k2'},
      signatureAlgorithm: algorithm,
    );

    expect(await verifier.verifyManifestSignature(byNext), isFalse);
    expect(await verifier.verifyingKeyId(byNext), isNull);

    // The primary key still verifies its own signature.
    final byPrimary = await sign(baseManifest(), algorithm, primaryPair);
    expect(await verifier.verifyingKeyId(byPrimary), 'k1');
  });

  test('hasTrustedPublicKey is false when every key id is revoked', () async {
    final verifier = UpdateVerifier(
      trustedPublicKeyBase64: primaryB64,
      primaryKeyId: 'k1',
      nextTrustedPublicKeyBase64: nextB64,
      nextKeyId: 'k2',
      revokedKeyIds: const {'k1', 'k2'},
      signatureAlgorithm: algorithm,
    );

    expect(verifier.hasTrustedPublicKey, isFalse);

    final byPrimary = await sign(baseManifest(), algorithm, primaryPair);
    expect(await verifier.verifyManifestSignature(byPrimary), isFalse);
  });

  test(
    'hasTrustedPublicKey stays true while one key survives revocation',
    () async {
      final verifier = UpdateVerifier(
        trustedPublicKeyBase64: primaryB64,
        primaryKeyId: 'k1',
        nextTrustedPublicKeyBase64: nextB64,
        nextKeyId: 'k2',
        revokedKeyIds: const {'k1'},
        signatureAlgorithm: algorithm,
      );

      expect(verifier.hasTrustedPublicKey, isTrue);

      final byPrimary = await sign(baseManifest(), algorithm, primaryPair);
      final byNext = await sign(baseManifest(), algorithm, nextPair);
      // Revoked primary is refused; surviving next still verifies.
      expect(await verifier.verifyManifestSignature(byPrimary), isFalse);
      expect(await verifier.verifyingKeyId(byNext), 'k2');
    },
  );
}

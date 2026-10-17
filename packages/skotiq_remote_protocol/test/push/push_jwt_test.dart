// Verifies the JWT signing shapes used by cellular push (Phase D):
//   - FCM OAuth2 assertion (RS256 / RSASSA-PKCS1-v1_5 + SHA-256)
//   - APNs provider token (ES256 / ECDSA P-256 + SHA-256, JOSE r||s form)
//
// The signatures are checked against the matching PEM public keys with
// PointyCastle so the test proves a real, verifiable signature — not just a
// well-shaped byte string. No network is touched.

import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:pointycastle/export.dart';

import 'fixtures/test_keys.dart';

Map<String, Object?> _decodeSegment(String seg) {
  // base64url, re-pad before decoding.
  final padded = seg.padRight((seg.length + 3) & ~3, '=');
  return jsonDecode(utf8.decode(base64Url.decode(padded)))
      as Map<String, Object?>;
}

void main() {
  group('RS256 (FCM assertion)', () {
    test('produces a 3-segment JWT with RS256 header and the claims', () {
      final jwt = signRs256Jwt(
        privateKeyPem: fcmTestPrivateKeyPem,
        claims: <String, Object?>{
          'iss': 'svc@proj.iam.gserviceaccount.com',
          'aud': 'https://oauth2.googleapis.com/token',
          'iat': 1717800000,
          'exp': 1717803600,
        },
      );

      final parts = jwt.split('.');
      expect(parts, hasLength(3));
      expect(parts[2], isNot(contains('=')), reason: 'base64url unpadded');

      final header = _decodeSegment(parts[0]);
      expect(header['alg'], 'RS256');
      expect(header['typ'], 'JWT');

      final claims = _decodeSegment(parts[1]);
      expect(claims['iss'], 'svc@proj.iam.gserviceaccount.com');
      expect(claims['aud'], 'https://oauth2.googleapis.com/token');
      expect(claims['exp'], 1717803600);
    });

    test('signature verifies against the RSA public key', () {
      final jwt = signRs256Jwt(
        privateKeyPem: fcmTestPrivateKeyPem,
        claims: const <String, Object?>{'iss': 'a', 'iat': 1},
      );
      final parts = jwt.split('.');
      final signingInput = Uint8List.fromList(
        utf8.encode('${parts[0]}.${parts[1]}'),
      );
      final sigBytes = base64Url.decode(
        parts[2].padRight((parts[2].length + 3) & ~3, '='),
      );

      final pubKey = CryptoUtils.rsaPublicKeyFromPem(fcmTestPublicKeyPem);
      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(false, PublicKeyParameter<RSAPublicKey>(pubKey));
      final ok = verifier.verifySignature(
        signingInput,
        RSASignature(Uint8List.fromList(sigBytes)),
      );
      expect(ok, isTrue);
    });

    test('buildFcmAssertionJwt sets the firebase.messaging scope + sub', () {
      const account = FcmServiceAccount(
        projectId: 'demo-proj',
        clientEmail: 'svc@demo-proj.iam.gserviceaccount.com',
        privateKeyPem: fcmTestPrivateKeyPem,
        tokenUri: 'https://oauth2.googleapis.com/token',
      );
      final jwt = buildFcmAssertionJwt(
        account,
        now: DateTime.utc(2026, 6, 8, 12),
      );
      final claims = _decodeSegment(jwt.split('.')[1]);
      expect(claims['iss'], account.clientEmail);
      expect(claims['sub'], account.clientEmail);
      expect(claims['aud'], account.tokenUri);
      expect(
        claims['scope'],
        'https://www.googleapis.com/auth/firebase.messaging',
      );
      // 1-hour expiry window.
      expect((claims['exp']! as int) - (claims['iat']! as int), 3600);
    });
  });

  group('ES256 (APNs provider token)', () {
    test('header carries alg ES256 + the key id; signature is 64 bytes', () {
      final jwt = signEs256Jwt(
        privateKeyPem: apnsTestPrivateKeyPem,
        keyId: 'ABC123D4E5',
        claims: const <String, Object?>{'iss': 'TEAM123456', 'iat': 1717800000},
      );
      final parts = jwt.split('.');
      expect(parts, hasLength(3));

      final header = _decodeSegment(parts[0]);
      expect(header['alg'], 'ES256');
      expect(header['kid'], 'ABC123D4E5');

      final claims = _decodeSegment(parts[1]);
      expect(claims['iss'], 'TEAM123456');

      // JOSE ES256 signature is the fixed-width concat r||s = 64 bytes.
      final sigBytes = base64Url.decode(
        parts[2].padRight((parts[2].length + 3) & ~3, '='),
      );
      expect(sigBytes, hasLength(64));
    });

    test('signature verifies against the EC public key', () {
      final jwt = signEs256Jwt(
        privateKeyPem: apnsTestPrivateKeyPem,
        keyId: 'KID0000001',
        claims: const <String, Object?>{'iss': 'TEAM000001', 'iat': 42},
      );
      final parts = jwt.split('.');
      final signingInput = Uint8List.fromList(
        utf8.encode('${parts[0]}.${parts[1]}'),
      );
      final sig = base64Url.decode(
        parts[2].padRight((parts[2].length + 3) & ~3, '='),
      );
      // Reassemble r||s into an ECSignature for verification.
      final r = _bigIntFromBytes(sig.sublist(0, 32));
      final s = _bigIntFromBytes(sig.sublist(32, 64));

      final pubKey = CryptoUtils.ecPublicKeyFromPem(apnsTestPublicKeyPem);
      final verifier = ECDSASigner(SHA256Digest())
        ..init(false, PublicKeyParameter<ECPublicKey>(pubKey));
      final ok = verifier.verifySignature(signingInput, ECSignature(r, s));
      expect(ok, isTrue);
    });
  });
}

BigInt _bigIntFromBytes(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

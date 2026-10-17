// JWT signing for cloud-push authentication (Phase D).
//
// Two algorithms are needed by the cellular-push deliveries:
//   - RS256 (RSA-SHA256, PKCS#1 v1.5) — to mint the OAuth2 assertion that
//     exchanges a Firebase service account for an FCM access token.
//   - ES256 (ECDSA-SHA256 over P-256) — the APNs provider token, signed
//     directly with the `.p8` auth key.
//
// We sign with PointyCastle (already a dependency of this package) and
// parse the PEM keys with basic_utils' CryptoUtils, so there is no new
// JWT library to pull in. The output is a compact JWS:
//   base64url(header) '.' base64url(payload) '.' base64url(signature)
// with no `=` padding, per RFC 7515.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/export.dart';

/// base64url WITHOUT padding, per RFC 7515 §2 (JWS).
String _b64Url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _b64UrlJson(Map<String, Object?> map) =>
    _b64Url(utf8.encode(jsonEncode(map)));

/// The unsigned signing input `header.payload` for a JWS, base64url-encoded.
String buildJwtSigningInput(
  Map<String, Object?> header,
  Map<String, Object?> claims,
) {
  return '${_b64UrlJson(header)}.${_b64UrlJson(claims)}';
}

/// Sign an RS256 JWT (RSASSA-PKCS1-v1_5 with SHA-256).
///
/// [privateKeyPem] is the PKCS#8 PEM string (`-----BEGIN PRIVATE KEY-----`)
/// from a Firebase service account's `private_key` field.
String signRs256Jwt({
  required Map<String, Object?> claims,
  required String privateKeyPem,
  Map<String, Object?>? extraHeader,
}) {
  final header = <String, Object?>{
    'alg': 'RS256',
    'typ': 'JWT',
    if (extraHeader != null) ...extraHeader,
  };
  final signingInput = buildJwtSigningInput(header, claims);

  final privateKey = CryptoUtils.rsaPrivateKeyFromPem(privateKeyPem);
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
  final sig = signer.generateSignature(
    Uint8List.fromList(utf8.encode(signingInput)),
  );

  return '$signingInput.${_b64Url(sig.bytes)}';
}

/// Sign an ES256 JWT (ECDSA over P-256 / secp256r1 with SHA-256).
///
/// [privateKeyPem] is the EC PEM string from an APNs `.p8` auth key. The
/// JOSE signature for ES256 is the fixed-width concatenation `r || s`
/// (32 bytes each), NOT the ASN.1 DER form PointyCastle would otherwise
/// suggest — see RFC 7518 §3.4.
String signEs256Jwt({
  required Map<String, Object?> claims,
  required String privateKeyPem,
  required String keyId,
}) {
  final header = <String, Object?>{'alg': 'ES256', 'kid': keyId};
  final signingInput = buildJwtSigningInput(header, claims);

  final privateKey = CryptoUtils.ecPrivateKeyFromPem(privateKeyPem);
  final signer = ECDSASigner(SHA256Digest(), null)
    ..init(
      true,
      ParametersWithRandom(
        PrivateKeyParameter<ECPrivateKey>(privateKey),
        _secureRandom(),
      ),
    );
  final ecSig =
      signer.generateSignature(Uint8List.fromList(utf8.encode(signingInput)))
          as ECSignature;

  final joseSig = Uint8List(64)
    ..setRange(0, 32, _bigIntToFixed(ecSig.r, 32))
    ..setRange(32, 64, _bigIntToFixed(ecSig.s, 32));

  return '$signingInput.${_b64Url(joseSig)}';
}

/// Big-endian, left-zero-padded fixed-width encoding of an unsigned [value].
///
/// PointyCastle's `BigInt`-to-bytes loses leading zero bytes; ES256 needs
/// each of r and s to be exactly 32 bytes.
Uint8List _bigIntToFixed(BigInt value, int width) {
  final out = Uint8List(width);
  var v = value;
  for (var i = width - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

SecureRandom _secureRandom() {
  // The ECDSA nonce k must be unpredictable: a low-entropy seed lets an
  // observer who can bound the signing time reconstruct k and, from a single
  // signature, recover the P-256 private key (the APNs .p8 auth key). Seed
  // Fortuna from the platform CSPRNG (`Random.secure()`) rather than from a
  // timestamp.
  final secure = Random.secure();
  final seed = Uint8List(32);
  for (var i = 0; i < seed.length; i++) {
    seed[i] = secure.nextInt(256);
  }
  final rng = FortunaRandom()..seed(KeyParameter(seed));
  return rng;
}

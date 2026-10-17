import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// PBKDF2-HMAC-SHA256 password hashing. Pure Dart (pointycastle), so the hub has
/// no native build step. Argon2id would be marginally preferable, but is not
/// available as a pure-Dart pub package; PBKDF2 with a high iteration count and
/// a per-password random salt is a standard, well-reviewed KDF and is what the
/// rest of the monorepo's crypto (SHA-256 family) already relies on.
///
/// Encoded format (single self-describing column, like crypt(3)):
///   `pbkdf2-sha256$<iterations>$<base64 salt>$<base64 derived key>`
class PasswordHasher {
  PasswordHasher({this.iterations = 120000, this.keyLength = 32})
    : _random = Random.secure();

  /// PBKDF2 iteration count. 120k is a reasonable interactive-login floor for
  /// SHA-256 on commodity self-host hardware.
  final int iterations;

  /// Derived key length in bytes.
  final int keyLength;

  final Random _random;

  static const int _saltLength = 16;

  /// Hash [password] with a fresh random salt, returning the encoded string to
  /// store in `accounts.password_hash`.
  String hash(String password) {
    final salt = _randomBytes(_saltLength);
    final dk = _derive(password, salt, iterations, keyLength);
    return 'pbkdf2-sha256\$$iterations\$${base64.encode(salt)}\$'
        '${base64.encode(dk)}';
  }

  /// Verify [password] against a previously [hash]ed string. Constant-time over
  /// the derived-key comparison. Returns false for any malformed stored value
  /// rather than throwing, so a corrupt row can never authenticate.
  bool verify(String password, String stored) {
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
    final iters = int.tryParse(parts[1]);
    if (iters == null || iters <= 0) return false;
    final Uint8List salt;
    final Uint8List expected;
    try {
      salt = base64.decode(parts[2]);
      expected = base64.decode(parts[3]);
    } on FormatException {
      return false;
    }
    final actual = _derive(password, salt, iters, expected.length);
    return _constantTimeEquals(actual, expected);
  }

  Uint8List _derive(String password, Uint8List salt, int iters, int length) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iters, length));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

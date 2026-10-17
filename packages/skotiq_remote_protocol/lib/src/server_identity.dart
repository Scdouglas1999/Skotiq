import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Stable SHA-256 fingerprint for a Skotiq remote-control host.
///
/// Derived from server-held secret material (typically the persistent admin
/// token or a dedicated identity key). Operators compare the short form shown
/// in QR confirmation UI against the value on the desktop remote-access screen.
String computeServerFingerprint(String serverSecret) {
  final normalized = serverSecret.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(
      serverSecret,
      'serverSecret',
      'must not be empty',
    );
  }
  final digest = sha256.convert(
    utf8.encode('skotiq-remote-v1:$normalized'),
  );
  return digest.toString();
}

/// First [length] hex characters of [fingerprint] for compact UI display.
String shortServerFingerprint(String fingerprint, {int length = 16}) {
  if (fingerprint.length <= length) {
    return fingerprint;
  }
  return fingerprint.substring(0, length);
}

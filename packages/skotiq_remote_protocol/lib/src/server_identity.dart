import 'dart:io';
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
  final digest = sha256.convert(utf8.encode('skotiq-remote-v1:$normalized'));
  return digest.toString();
}

/// First [length] hex characters of [fingerprint] for compact UI display.
String shortServerFingerprint(String fingerprint, {int length = 16}) {
  if (fingerprint.length <= length) {
    return fingerprint;
  }
  return fingerprint.substring(0, length);
}

/// Which kind of Skotiq process serves the remote API.
///
/// `gui` is the desktop app with its window (the usual imaging computer);
/// `headless` is the daemon (`--headless`, a Pi appliance, a service). The two
/// used to be indistinguishable to a client: both called themselves
/// "Skotiq Headless".
enum SkotiqHostMode {
  gui('gui'),
  headless('headless');

  const SkotiqHostMode(this.wire);
  final String wire;
}

/// The computer name a host advertises in discovery and `/api/info`, as a
/// person would recognize it: `DESKTOP-MMAJGAK`, `observatory-pi`. A trailing
/// `.local` (macOS) or domain suffix is dropped. Falls back to `Skotiq` when
/// the OS reports nothing.
String hostComputerName([String? raw]) {
  var name = (raw ?? _localHostname()).trim();
  final dot = name.indexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return name.isEmpty ? 'Skotiq' : name;
}

String _localHostname() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return '';
  }
}

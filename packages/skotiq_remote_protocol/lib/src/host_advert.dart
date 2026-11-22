/// What a host says about itself before a client links.
library;

import 'server_identity.dart';

/// The facts a host advertises in the mDNS TXT record, the UDP beacon and the
/// identity keys of `/api/info`. Hosts and clients of other releases read
/// these shapes (`LinkVersion.openToOtherReleases`, printed QR codes, older
/// phones), so they may gain keys but never lose or rename one.
class HostAdvert {
  const HostAdvert({
    required this.hostName,
    required this.hostMode,
    required this.version,
    required this.scheme,
    required this.fingerprint,
    required this.authRequired,
    this.pairingSupported = true,
  });

  /// The computer's name ([hostComputerName]); also the advertised `name`.
  final String hostName;

  final SkotiqHostMode hostMode;

  /// The Skotiq release the host runs.
  final String version;

  /// `http` or `https`.
  final String scheme;

  final String fingerprint;

  final bool authRequired;

  final bool pairingSupported;

  String get authenticationMode => authRequired ? 'token' : 'none';

  /// The `_skotiq._tcp` TXT record.
  Map<String, String> toTxt() => {
    'version': version,
    'scheme': scheme,
    'fingerprint': fingerprint,
    'pairingSupported': '$pairingSupported',
    'name': hostName,
    'hostName': hostName,
    'hostMode': hostMode.wire,
  };

  /// The identity keys of `/api/info`. The host adds what only that document
  /// carries (capabilities, auth scopes, event cursors).
  Map<String, Object?> toInfoJson() => {
    'name': hostName,
    'hostName': hostName,
    'product': 'Skotiq',
    'hostMode': hostMode.wire,
    'version': version,
    'mode': hostMode.wire,
    'authRequired': authRequired,
    'authenticationMode': authenticationMode,
    'pairingSupported': pairingSupported,
    'fingerprint': fingerprint,
  };
}

/// A `_skotiq._tcp` TXT record as read, before a reader applies its defaults.
/// Each value is null when the record does not carry it in a usable form.
class HostTxt {
  const HostTxt._({
    this.version,
    this.name,
    this.scheme,
    this.fingerprint,
    required this.pairingSupported,
    this.hostName,
    this.hostMode,
    this.signalingPort,
  });

  /// Reads the decoded TXT strings.
  factory HostTxt.parse(Map<String, String> txt) {
    String? nonEmpty(String key) {
      final value = txt[key];
      return value == null || value.isEmpty ? null : value;
    }

    final scheme = txt['scheme']?.toLowerCase();
    final pairing = txt['pairingSupported'];
    final signaling = txt['signaling_port'];
    return HostTxt._(
      version: txt['version'],
      name: txt['name'],
      scheme: scheme == 'http' || scheme == 'https' ? scheme : null,
      fingerprint: nonEmpty('fingerprint'),
      pairingSupported:
          pairing != null &&
          (pairing.toLowerCase() == 'true' || pairing == '1'),
      hostName: txt['hostName'],
      hostMode: txt['hostMode'],
      signalingPort: signaling == null ? null : int.tryParse(signaling),
    );
  }

  final String? version;
  final String? name;

  /// `http` or `https`; null for anything else.
  final String? scheme;
  final String? fingerprint;

  /// False when the record does not say `true`.
  final bool pairingSupported;
  final String? hostName;
  final String? hostMode;
  final int? signalingPort;
}

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

/// A host's identity keys as one of its JSON documents carried them (its
/// `/api/info` or its UDP beacon), before a reader applies its defaults. A key
/// that is missing, or not of its type, reads as null: a foreign service on
/// the LAN can send anything, and what it sent must not stop discovery.
class HostAdvertRead {
  const HostAdvertRead._({
    this.name,
    this.hostName,
    this.hostMode,
    this.version,
    this.mode,
    this.scheme,
    this.fingerprint,
    this.authRequired,
    this.authenticationMode,
    this.pairingSupported,
    this.lanPairing,
    this.tailscaleHost,
    this.relayApplianceId,
    this.platform,
  });

  factory HostAdvertRead.fromJson(Map<String, Object?> json) {
    String? text(String key) => switch (json[key]) {
      final String value => value,
      _ => null,
    };
    String? filled(String key) {
      final value = text(key)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    bool? flag(String key) => switch (json[key]) {
      final bool value => value,
      _ => null,
    };
    final scheme = text('scheme')?.toLowerCase();
    return HostAdvertRead._(
      name: text('name'),
      hostName: filled('hostName'),
      hostMode: filled('hostMode'),
      version: text('version'),
      mode: text('mode'),
      scheme: scheme == 'http' || scheme == 'https' ? scheme : null,
      fingerprint: text('fingerprint'),
      authRequired: flag('authRequired'),
      authenticationMode: text('authenticationMode'),
      pairingSupported: flag('pairingSupported'),
      lanPairing: flag('lanPairing'),
      tailscaleHost: text('tailscaleHost'),
      relayApplianceId: text('relayApplianceId'),
      platform: filled('platform'),
    );
  }

  final String? name;

  /// The computer's name, trimmed; null when blank.
  final String? hostName;

  /// `gui` or `headless` on hosts that say (trimmed; null when blank). Kept
  /// as sent, so a mode a later release adds still reads.
  final String? hostMode;
  final String? version;

  /// The older `mode` key.
  final String? mode;

  /// `http` or `https`; null for anything else.
  final String? scheme;
  final String? fingerprint;
  final bool? authRequired;
  final String? authenticationMode;
  final bool? pairingSupported;

  /// The host accepts a one-tap pairing from its own LAN.
  final bool? lanPairing;

  /// The host's tailnet address, when its Tailscale uplink is up.
  final String? tailscaleHost;

  /// The host's relay appliance id, when its relay uplink is up.
  final String? relayApplianceId;

  /// The host's operating system, trimmed; null when blank.
  final String? platform;
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

    String? filled(String key) {
      final value = txt[key]?.trim();
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
      hostName: filled('hostName'),
      hostMode: filled('hostMode'),
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

  /// The computer's name and `gui`/`headless`, trimmed; null when blank.
  final String? hostName;
  final String? hostMode;
  final int? signalingPort;
}

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists a stable device identity and performs REST pairing against the
/// desktop headless API.
///
/// [scheme] selects the transport (`http` default, `https` for a TLS-fronted
/// tailnet rig). A TLS rig answers pairing only on `https`, so a wrong scheme
/// here breaks pairing-over-Tailscale outright — callers must pass the scheme
/// they learned from the QR payload / saved-server record.
///
/// [pinnedFingerprint], when set, makes [RemotePairingClient] run a pre-flight
/// `/api/info` identity check and refuse to transmit the pairing code unless
/// the live server's fingerprint matches. This closes the MITM window on the
/// Tailscale / Internet-reachable path where the phone is no longer protected
/// by sharing a trusted LAN segment with the rig.
class MobilePairingService {
  static const _deviceIdKey = 'skotiq_mobile_device_id';

  final RemotePairingClient _client;

  MobilePairingService({
    required String host,
    required int port,
    String scheme = 'http',
    String? pinnedFingerprint,
  }) : _client = RemotePairingClient(
         host: host,
         port: port,
         scheme: scheme,
         pinnedFingerprint: pinnedFingerprint,
       );

  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final generated = _generateDeviceId();
    await prefs.setString(_deviceIdKey, generated);
    return generated;
  }

  static String deviceName() {
    if (Platform.isIOS) {
      return 'iOS companion';
    }
    if (Platform.isAndroid) {
      return 'Android companion';
    }
    return 'Mobile companion';
  }

  /// Pair using a code from the desktop UI or QR payload.
  Future<RemotePairingVerifyResult> pairWithCode({
    required String code,
    bool requestAdminScope = false,
  }) async {
    final id = await deviceId();
    return _client.verify(
      code: code,
      deviceId: id,
      deviceName: deviceName(),
      deviceType: defaultTargetPlatform.name,
      requestedScope: requestAdminScope ? 'admin' : 'control',
    );
  }

  /// Attempts one-tap LAN pairing against `POST /api/pairing/lan-claim`.
  ///
  /// Returns a success [RemotePairingVerifyResult] (with a token) when the
  /// appliance grants it — no code, because the request came from a trusted
  /// private-LAN source and the appliance is in `lan-open` mode. Returns
  /// `null` when one-tap pairing is unavailable for this connection (server in
  /// `code-required` mode, or reached over tailnet/relay so the source is not a
  /// trusted LAN address, or an older server without the endpoint) — the caller
  /// should fall back to [pairWithCode]. Honours [pinnedFingerprint] the same
  /// way [pairWithCode] does: when a pin is set the server identity is verified
  /// before the minted token is trusted.
  Future<RemotePairingVerifyResult?> lanClaim() async {
    final id = await deviceId();
    return _client.lanClaim(
      deviceId: id,
      deviceName: deviceName(),
      deviceType: 'mobile',
    );
  }

  /// Opens a pairing session on the host (code is shown on desktop / QR).
  Future<RemotePairingStartResult> startRemoteSession() => _client.start();

  static String _generateDeviceId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'mobile:$hex';
  }
}

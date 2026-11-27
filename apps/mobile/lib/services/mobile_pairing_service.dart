import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// This phone's pairing identity (a stable device id and its name) and the
/// core [RigPairingService] that pairs with it.
class MobilePairingService {
  MobilePairingService._();

  static const _deviceIdKey = 'skotiq_mobile_device_id';

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

  /// The pairing type this phone names when it pairs with a code.
  static PairingDeviceType platformDeviceType() =>
      PairingDeviceType.parse(defaultTargetPlatform.name) ??
      PairingDeviceType.mobile;

  /// Pairs this phone with a host. A TLS-fronted tailnet rig answers pairing
  /// only on `https`, so the host record must carry the scheme learned from
  /// the QR payload or saved server; its fingerprint, when known, is checked
  /// before any code leaves the phone.
  static RigPairingService pairing({
    RemotePairingClient Function(DiscoveredServer host)? clientFactory,
  }) => RigPairingService(
    deviceId: deviceId,
    deviceType: platformDeviceType(),
    timeout: const Duration(seconds: 15),
    clientFactory: clientFactory,
  );

  static String _generateDeviceId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'mobile:$hex';
  }
}

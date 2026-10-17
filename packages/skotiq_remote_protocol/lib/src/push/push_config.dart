// Cloud-push configuration loader (Phase D).
//
// The FCM service-account JSON and the APNs `.p8` auth key are operator
// secrets that never live in the repo. They are referenced *by path* from
// a `push_config.json` file that the operator drops into the app-support
// dir (or points to via the SKOTIQ_PUSH_CONFIG env var).
//
// Resolution order:
//   1. SKOTIQ_PUSH_CONFIG  -> absolute path to a push_config.json
//   2. <appSupport>/Skotiq/push_config.json
//   3. absent           -> PushConfig.disabled (mock / no-op; never crash)
//
// A half-configured deployment must still run: a channel whose referenced
// secret file is missing is silently left disabled so LAN + WS push keep
// working.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// FCM (Android) channel configuration.
class FcmPushConfig {
  final bool enabled;

  /// Absolute path to the Firebase service-account JSON.
  final String serviceAccountPath;

  const FcmPushConfig({
    required this.enabled,
    required this.serviceAccountPath,
  });

  static const FcmPushConfig disabled = FcmPushConfig(
    enabled: false,
    serviceAccountPath: '',
  );

  factory FcmPushConfig.fromJson(Map<String, Object?> json) {
    return FcmPushConfig(
      enabled: json['enabled'] == true,
      serviceAccountPath: (json['serviceAccountPath'] as String?) ?? '',
    );
  }
}

/// APNs (iOS) channel configuration.
class ApnsPushConfig {
  final bool enabled;

  /// Absolute path to the APNs auth key (`.p8`).
  final String p8KeyPath;

  /// 10-char APNs Key ID.
  final String keyId;

  /// 10-char Apple Team ID (JWT `iss`).
  final String teamId;

  /// iOS app Bundle ID (the `apns-topic`).
  final String bundleId;

  /// Use the Apple sandbox host instead of production.
  final bool useSandbox;

  const ApnsPushConfig({
    required this.enabled,
    required this.p8KeyPath,
    required this.keyId,
    required this.teamId,
    required this.bundleId,
    required this.useSandbox,
  });

  static const ApnsPushConfig disabled = ApnsPushConfig(
    enabled: false,
    p8KeyPath: '',
    keyId: '',
    teamId: '',
    bundleId: '',
    useSandbox: false,
  );

  factory ApnsPushConfig.fromJson(Map<String, Object?> json) {
    return ApnsPushConfig(
      enabled: json['enabled'] == true,
      p8KeyPath: (json['p8KeyPath'] as String?) ?? '',
      keyId: (json['keyId'] as String?) ?? '',
      teamId: (json['teamId'] as String?) ?? '',
      bundleId: (json['bundleId'] as String?) ?? '',
      useSandbox: json['useSandbox'] == true,
    );
  }
}

/// Parsed `push_config.json`. The top-level `mock` flag forces the local
/// recording delivery even with no cloud secrets — useful for dev.
class PushConfig {
  final FcmPushConfig fcm;
  final ApnsPushConfig apns;

  /// Operator opted into the in-memory mock delivery (cloudless dev).
  final bool mock;

  const PushConfig({required this.fcm, required this.apns, required this.mock});

  /// Everything off — the natural state when no config file exists.
  static const PushConfig disabled = PushConfig(
    fcm: FcmPushConfig.disabled,
    apns: ApnsPushConfig.disabled,
    mock: false,
  );

  /// True when no cloud channel is enabled (so the caller should fall back
  /// to the mock / no-op delivery rather than wiring real senders).
  bool get hasCloudChannel => fcm.enabled || apns.enabled;

  factory PushConfig.fromJson(Map<String, Object?> json) {
    final fcmJson = json['fcm'];
    final apnsJson = json['apns'];
    return PushConfig(
      fcm: fcmJson is Map<String, Object?>
          ? FcmPushConfig.fromJson(fcmJson)
          : FcmPushConfig.disabled,
      apns: apnsJson is Map<String, Object?>
          ? ApnsPushConfig.fromJson(apnsJson)
          : ApnsPushConfig.disabled,
      mock: json['mock'] == true,
    );
  }

  /// Load config from the env override or the app-support dir. Never throws:
  /// a missing or malformed file yields [PushConfig.disabled].
  ///
  /// [appSupportDir] is the platform application-support directory
  /// (the caller resolves it via path_provider so this stays pure-Dart and
  /// testable). [environment] defaults to the real process env.
  static Future<PushConfig> load({
    required String appSupportDir,
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final override = env['SKOTIQ_PUSH_CONFIG'];
    final path = (override != null && override.trim().isNotEmpty)
        ? override.trim()
        : p.join(appSupportDir, 'Skotiq', 'push_config.json');

    final file = File(path);
    if (!await file.exists()) {
      return PushConfig.disabled;
    }
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return PushConfig.disabled;
      }
      final cfg = PushConfig.fromJson(decoded);
      return cfg.validated();
    } catch (_) {
      // Malformed config must never crash the server — degrade to no-op.
      return PushConfig.disabled;
    }
  }

  /// Disable any channel whose referenced secret file is missing, so a
  /// half-configured deployment still runs LAN + WS push.
  PushConfig validated() {
    final fcmOk =
        fcm.enabled &&
        fcm.serviceAccountPath.isNotEmpty &&
        File(fcm.serviceAccountPath).existsSync();
    final apnsOk =
        apns.enabled &&
        apns.p8KeyPath.isNotEmpty &&
        apns.keyId.isNotEmpty &&
        apns.teamId.isNotEmpty &&
        apns.bundleId.isNotEmpty &&
        File(apns.p8KeyPath).existsSync();
    return PushConfig(
      fcm: fcmOk ? fcm : FcmPushConfig.disabled,
      apns: apnsOk ? apns : ApnsPushConfig.disabled,
      mock: mock,
    );
  }
}

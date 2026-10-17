/// [PushTokenStore] backed by the pairing Drift DB (Phase D).
///
/// Adapts the `device_push_tokens` / `device_push_prefs` tables (owned by
/// [PairingDatabase]) to the dependency-free [PushTokenStore] surface the
/// remote-push deliveries read from. Lives in the desktop app — the protocol
/// package keeps the abstract store and the mock delivery, but the concrete
/// DB binding belongs next to the server that owns the database file.
library;

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// Reads registered push tokens + per-device preferences out of a
/// [PairingDatabase] for the FCM/APNs/mock deliveries to fan out over.
///
/// Also implements [StalePushTokenSink] so the deliveries' automatic
/// 404/410 cleanup ([RemotePushDelivery] prunes a token the cloud reports
/// dead — FCM `UNREGISTERED`, APNs `Gone`) actually removes the row in
/// production instead of silently no-op'ing.
class DatabasePushTokenStore implements PushTokenStore, StalePushTokenSink {
  final PairingDatabase database;

  DatabasePushTokenStore(this.database);

  @override
  Future<void> removeStaleToken(String token) =>
      database.deletePushToken(token);

  @override
  Future<List<RegisteredPushToken>> tokensForPlatform(String platform) async {
    final rows = await database.getPushTokensByPlatform(platform);
    return rows
        .map(
          (r) => RegisteredPushToken(
            deviceId: r.deviceId,
            platform: r.platform,
            token: r.token,
          ),
        )
        .toList();
  }

  @override
  Future<DevicePushPreferences> preferencesFor(String deviceId) async {
    final row = await database.getPushPrefs(deviceId);
    if (row == null) {
      // No row yet → fail-open: every category enabled. Mirrors the
      // GET /api/push/preferences default so the rendered toggles and the
      // actual delivery gate agree.
      return DevicePushPreferences.allEnabled;
    }
    return DevicePushPreferences(
      enabled: row.enabled,
      muteSequenceFailed: row.muteSequenceFailed,
      muteWeatherUnsafe: row.muteWeatherUnsafe,
      muteGuidingLost: row.muteGuidingLost,
      muteAutofocusFailed: row.muteAutofocusFailed,
      muteEquipmentDisconnected: row.muteEquipmentDisconnected,
    );
  }
}

import 'package:drift/drift.dart';

/// Per-device cellular-push token store (Phase D).
///
/// A paired phone registers its FCM (Android) or APNs (iOS) token here via
/// `POST /api/push/register-token`. The remote-push delivery reads this table
/// to know *who* to fan a critical [PushNotificationFrame] out to — the frame
/// itself carries no recipient (it is the LAN-broadcast content), so the
/// delivery owns the recipient list.
///
/// A device may hold one row per platform (a phone that runs both an Android
/// build and re-pairs as iOS is theoretically two tokens), hence the composite
/// `(deviceId, platform)` primary key. The `deviceId` mirrors
/// `paired_devices.deviceId`; revoking/unpairing a device deletes its rows so a
/// deauthorized phone stops receiving cellular alerts.
class DevicePushTokens extends Table {
  /// Paired-device identifier — matches `paired_devices.deviceId`.
  TextColumn get deviceId => text()();

  /// Cloud-push platform: `fcm` (Android) or `apns` (iOS).
  TextColumn get platform => text()();

  /// FCM registration token, or APNs hex device token. Opaque to the server.
  TextColumn get token => text()();

  /// Last time this token was registered/refreshed. Stale-token cleanup (a
  /// 404/410 from the cloud provider) deletes the row; a token refresh upserts
  /// a fresh `updatedAt`.
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {deviceId, platform};
}

/// Per-device push-notification preferences (Phase D).
///
/// The server-scoped `PushNotificationConfig` is the *master* content gate
/// (which events ever turn into a push). This table is the *per-recipient*
/// gate layered on top: "the wall tablet wants weather alerts but my pocket
/// phone is in DnD". When the delivery fans a frame out to N tokens it reads
/// each device's row first and skips muted categories / disabled devices.
///
/// A missing row means "all enabled" (the conservative default — a freshly
/// paired phone receives every critical until the operator mutes something).
class DevicePushPrefs extends Table {
  /// Paired-device identifier — matches `paired_devices.deviceId`.
  TextColumn get deviceId => text()();

  /// Master per-device gate. When false, the device receives no cellular push
  /// regardless of the per-category flags below.
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// Per-category mute flags. Mirror the categories `PushNotificationConfig`
  /// escalates to cellular; `true` means "do not deliver this category to this
  /// device". Defaults are `false` (deliver) so a new device is fully wired.
  BoolColumn get muteSequenceFailed =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get muteWeatherUnsafe =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get muteGuidingLost =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get muteAutofocusFailed =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get muteEquipmentDisconnected =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {deviceId};
}

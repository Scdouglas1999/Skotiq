// Legacy notification toggles surfaced in Settings → Notifications. Owns
// the master enable + transport credentials + per-event-type opt-outs.
//
// Owns:
//   * notificationsEnabled (master)
//   * discordWebhook, pushoverKey, pushoverUser
//   * notifyOnSequenceComplete, notifyOnError, notifyOnMeridianFlip
//   * soundEnabled
//
// Does NOT own:
// * The NotificationRouter per-event-type routing matrix — those
//     are richer transport configs persisted via NotificationRouter
//     itself; this file only holds the legacy single-webhook fallback.
//   * Critical-event audible / push toggles → see `environment.dart`.
//   * Push notifications to paired mobile clients → see `environment.dart`
//     and the `push_notification_provider`.
part of '../settings_provider.dart';

/// Setters for legacy notification toggles.
extension NotificationSettingsSection on AppSettingsNotifier {
  Future<void> setNotificationsEnabled(bool value) =>
      _set(AppSettingDefs.notificationsEnabled, value);

  Future<void> setDiscordWebhook(String value) =>
      _set(AppSettingDefs.discordWebhook, value);

  Future<void> setPushoverKey(String value) =>
      _set(AppSettingDefs.pushoverKey, value);

  Future<void> setPushoverUser(String value) =>
      _set(AppSettingDefs.pushoverUser, value);

  Future<void> setNotifyOnSequenceComplete(bool value) =>
      _set(AppSettingDefs.notifyOnSequenceComplete, value);

  Future<void> setNotifyOnError(bool value) =>
      _set(AppSettingDefs.notifyOnError, value);

  Future<void> setNotifyOnMeridianFlip(bool value) =>
      _set(AppSettingDefs.notifyOnMeridianFlip, value);

  Future<void> setSoundEnabled(bool value) =>
      _set(AppSettingDefs.soundEnabled, value);
}

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
  Future<void> setNotificationsEnabled(bool value) async {
    await _saveSetting('notifications_enabled', value.toString());
    _patchState((s) => s.copyWith(notificationsEnabled: value));
  }

  Future<void> setDiscordWebhook(String value) async {
    await _saveSetting('discord_webhook', value);
    _patchState((s) => s.copyWith(discordWebhook: value));
  }

  Future<void> setPushoverKey(String value) async {
    await _saveSetting('pushover_key', value);
    _patchState((s) => s.copyWith(pushoverKey: value));
  }

  Future<void> setPushoverUser(String value) async {
    await _saveSetting('pushover_user', value);
    _patchState((s) => s.copyWith(pushoverUser: value));
  }

  Future<void> setNotifyOnSequenceComplete(bool value) async {
    await _saveSetting('notify_on_sequence_complete', value.toString());
    _patchState((s) => s.copyWith(notifyOnSequenceComplete: value));
  }

  Future<void> setNotifyOnError(bool value) async {
    await _saveSetting('notify_on_error', value.toString());
    _patchState((s) => s.copyWith(notifyOnError: value));
  }

  Future<void> setNotifyOnMeridianFlip(bool value) async {
    await _saveSetting('notify_on_meridian_flip', value.toString());
    _patchState((s) => s.copyWith(notifyOnMeridianFlip: value));
  }

  Future<void> setSoundEnabled(bool value) async {
    await _saveSetting('sound_enabled', value.toString());
    _patchState((s) => s.copyWith(soundEnabled: value));
  }
}

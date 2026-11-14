// General-purpose application behaviour toggles surfaced in
// Settings → General. This section owns the "should the app do X on
// launch / on close / in the background" knobs.
//
// Owns:
//   * startMinimized, autoConnectEquipment, confirmBeforeClosing,
//     autoDiscoverOnLaunch
//
// Does NOT own:
//   * Theme / language / fonts → see `appearance.dart`.
//   * Imaging-output defaults → see `imaging.dart`.
//   * Notification toggles → see `notifications.dart`.
part of '../settings_provider.dart';

extension GeneralSettingsSection on AppSettingsNotifier {
  Future<void> setStartMinimized(bool value) =>
      _set(AppSettingDefs.startMinimized, value);

  Future<void> setAutoConnectEquipment(bool value) =>
      _set(AppSettingDefs.autoConnectEquipment, value);

  Future<void> setConfirmBeforeClosing(bool value) =>
      _set(AppSettingDefs.confirmBeforeClosing, value);

  Future<void> setAutoDiscoverOnLaunch(bool value) =>
      _set(AppSettingDefs.autoDiscoverOnLaunch, value);
}

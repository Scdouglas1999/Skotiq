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

/// Setters for general application behaviour toggles.
extension GeneralSettingsSection on AppSettingsNotifier {
  Future<void> setStartMinimized(bool value) async {
    await _saveSetting('start_minimized', value.toString());
    _patchState((s) => s.copyWith(startMinimized: value));
  }

  Future<void> setAutoConnectEquipment(bool value) async {
    await _saveSetting('auto_connect_equipment', value.toString());
    _patchState((s) => s.copyWith(autoConnectEquipment: value));
  }

  Future<void> setConfirmBeforeClosing(bool value) async {
    await _saveSetting('confirm_before_closing', value.toString());
    _patchState((s) => s.copyWith(confirmBeforeClosing: value));
  }

  Future<void> setAutoDiscoverOnLaunch(bool value) async {
    await _saveSetting('auto_discover_on_launch', value.toString());
    _patchState((s) => s.copyWith(autoDiscoverOnLaunch: value));
  }
}

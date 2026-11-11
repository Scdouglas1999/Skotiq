// PHD2 guider connection knobs surfaced in Settings → PHD2 Guiding. Owns
// the binary path and TCP host/port the native PHD2 client connects to.
//
// Owns:
//   * phd2Path, phd2Host, phd2Port
//
// Does NOT own:
//   * Dither / settle parameters (those describe the guiding strategy, not
//     the connection) → see `equipment.dart`.
//   * Auto-disable-guiding-during-AF — that's an autofocus knob, see
//     `autofocus.dart`.
part of '../settings_provider.dart';

/// Setters for PHD2 guider connection configuration.
extension Phd2SettingsSection on AppSettingsNotifier {
  Future<void> setPhd2Path(String value) => _set(AppSettingDefs.phd2Path, value);

  Future<void> setPhd2Host(String value) => _set(AppSettingDefs.phd2Host, value);

  Future<void> setPhd2Port(int value) => _set(AppSettingDefs.phd2Port, value);

  /// Persist the endpoint as one logical settings mutation. Saving the host
  /// and port separately can leave a mixed endpoint when the second write
  /// fails, and sends two full settings snapshots to a remote rig.
  Future<void> setPhd2Endpoint(String host, int port) async {
    await _setAll([AppSettingDefs.phd2Host.to(host), AppSettingDefs.phd2Port.to(port)]);
  }
}

// Remote-access / web-server defaults surfaced in Settings → Remote Access.
// Owns the on/off and port for the optional local web-control server.
//
// Owns:
//   * webServerEnabled, webServerPort
//
// Does NOT own:
//   * INDI / Alpaca server settings (these are device-protocol servers,
//     not the in-app remote-control web server) → see `protocol.dart`.
//   * Pairing / discovery / channel encryption → see
//     `skotiq_remote_protocol` package.
part of '../settings_provider.dart';

/// Setters for the optional local web-control server.
extension RemoteAccessSettingsSection on AppSettingsNotifier {
  Future<void> setWebServerEnabled(bool value) =>
      _set(AppSettingDefs.webServerEnabled, value);

  Future<void> setWebServerPort(int value) =>
      _set(AppSettingDefs.webServerPort, value);
}

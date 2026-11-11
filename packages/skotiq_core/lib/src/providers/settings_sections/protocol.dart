// Device-protocol server settings (INDI / Alpaca) surfaced in
// Settings → Connection. Owns the host / port / auto-connect knobs the
// native INDI and Alpaca clients consult when bootstrapping connections.
//
// Owns:
//   * indiServerHost, indiServerPort, indiAutoConnect
//   * alpacaServerHost, alpacaServerPort, alpacaAutoDiscover
//   * qhyDiscoveryEnabled (the QHY SDK enumeration switch)
//
// Does NOT own:
//   * Per-device connection state (that's runtime, not settings) → see
//     `equipment_provider.dart`.
//   * The optional local web-control server → see `remote_access.dart`
//     (it serves a different purpose entirely — the in-app web client,
//     not a device-protocol server).
//   * The standalone [AutoConnectSettingsNotifier] sibling provider at
//     the bottom of the main settings_provider.dart (legacy compat).
part of '../settings_provider.dart';

extension ProtocolSettingsSection on AppSettingsNotifier {
  Future<void> setIndiServerHost(String value) =>
      _set(AppSettingDefs.indiServerHost, value);

  Future<void> setIndiServerPort(int value) =>
      _set(AppSettingDefs.indiServerPort, value);

  Future<void> setIndiAutoConnect(bool value) =>
      _set(AppSettingDefs.indiAutoConnect, value);

  Future<void> setAlpacaServerHost(String value) =>
      _set(AppSettingDefs.alpacaServerHost, value);

  Future<void> setAlpacaServerPort(int value) =>
      _set(AppSettingDefs.alpacaServerPort, value);

  Future<void> setAlpacaAutoDiscover(bool value) =>
      _set(AppSettingDefs.alpacaAutoDiscover, value);

  Future<void> setQhyDiscoveryEnabled(bool value) =>
      _set(AppSettingDefs.qhyDiscoveryEnabled, value);
}

// Device-protocol server settings (INDI / Alpaca) surfaced in
// Settings → Connection. Owns the host / port / auto-connect knobs the
// native INDI and Alpaca clients consult when bootstrapping connections.
//
// Owns:
//   * indiServerHost, indiServerPort, indiAutoConnect
//   * alpacaServerHost, alpacaServerPort, alpacaAutoDiscover
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

/// Setters for INDI and Alpaca server connection settings.
extension ProtocolSettingsSection on AppSettingsNotifier {
  Future<void> setIndiServerHost(String value) async {
    await _saveSetting('indi_server_host', value);
    _patchState((s) => s.copyWith(indiServerHost: value));
  }

  Future<void> setIndiServerPort(int value) async {
    await _saveSetting('indi_server_port', value.toString());
    _patchState((s) => s.copyWith(indiServerPort: value));
  }

  Future<void> setIndiAutoConnect(bool value) async {
    await _saveSetting('indi_auto_connect', value.toString());
    _patchState((s) => s.copyWith(indiAutoConnect: value));
  }

  Future<void> setAlpacaServerHost(String value) async {
    await _saveSetting('alpaca_server_host', value);
    _patchState((s) => s.copyWith(alpacaServerHost: value));
  }

  Future<void> setAlpacaServerPort(int value) async {
    await _saveSetting('alpaca_server_port', value.toString());
    _patchState((s) => s.copyWith(alpacaServerPort: value));
  }

  Future<void> setAlpacaAutoDiscover(bool value) async {
    await _saveSetting('alpaca_auto_discover', value.toString());
    _patchState((s) => s.copyWith(alpacaAutoDiscover: value));
  }
}

part of '../../device_service.dart';

extension _DeviceServiceSwitchConnections on DeviceService {
  /// Connect to a switch device.
  ///
  /// Switch is a first-class device type with its own state
  /// provider and equipment-profile column. The Rust bridge exposes
  /// per-channel get/set under `api_switch_*`; per-channel UI is future
  /// work (see [SwitchState] docs) but the connect/disconnect path is
  /// real and must succeed before the user can flip any channels.
  Future<void> _connectSwitch(String deviceId) {
    return _trackInFlight(() async {
      final notifier = _ref.read(switchStateProvider.notifier);

      // Format check only; backend is the source of truth for
      // reachability. See [connectCamera] for the full rationale.
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('switch', deviceId);
      }

      // Hand the type slot over cleanly rather than orphaning the
      // incumbent's driver connection (see [_releaseDisplacedDevice]).
      await _releaseDisplacedDevice(DeviceType.switch_, deviceId);

      notifier.setConnecting(
        deviceId,
        await _resolveDeviceDisplayName(DeviceType.switch_, deviceId),
      );

      try {
        await _backend.connectDevice(DeviceType.switch_, deviceId);
        notifier.setConnected();
      } catch (e) {
        notifier.setDisconnected();
        rethrow;
      }

      // Best-effort snapshot after the connection itself is authoritative.
      // Refresh errors are surfaced by SwitchChannelService but must not turn
      // a genuinely connected power box back into a disconnected device.
      try {
        await _refreshSwitchChannels();
      } on Object {
        // The card retains a manual retry control.
      }
    });
  }

  /// Disconnect switch device.
  Future<void> _disconnectSwitch() {
    return _trackInFlight(() async {
      final notifier = _ref.read(switchStateProvider.notifier);
      final state = _ref.read(switchStateProvider);

      // Audit see [disconnectCamera] for the rationale.
      final deviceId = state.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        throw const DeviceNotConnectedException('switch');
      }

      _markUserInitiatedDisconnect(deviceId);

      try {
        await _backend.disconnectDevice(DeviceType.switch_, deviceId);
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        rethrow;
      }
      notifier.setDisconnected();
    });
  }

  /// Refresh the cached channel snapshot for the currently-connected
  /// switch device. Delegates to [SwitchChannelService.refreshChannels];
  /// see that class for the full contract (per-channel fallbacks,
  /// backend gating, ErrorService surfacing).
  Future<void> _refreshSwitchChannels() => _switchChannels.refreshChannels();

  /// Toggle a single switch channel on or off. Delegates to
  /// [SwitchChannelService.setChannel] inside [_trackInFlight] so the
  /// per-switch write participates in the facade's quiesce accounting.
  /// See [SwitchChannelService.setChannel] for thrown exceptions and
  /// error-routing semantics.
  Future<void> _setSwitchChannel(int channelIndex, bool on) {
    return _trackInFlight(() => _switchChannels.setChannel(channelIndex, on));
  }

  /// Set a numeric/PWM switch channel after validating its advertised range.
  Future<void> _setSwitchChannelValue(int channelIndex, double value) {
    return _trackInFlight(
      () => _switchChannels.setChannelValue(channelIndex, value),
    );
  }
}

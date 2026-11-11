part of '../../device_service.dart';

extension _DeviceServiceSwitchConnections on DeviceService {
  /// A failed channel read is not a failed connect; the card shows the
  /// switch with no channels and offers a refresh.
  Future<void> _bringUpSwitch() async {
    _ref.read(switchStateProvider.notifier).setConnected();
    try {
      await _refreshSwitchChannels();
    } on Object {
      // Reported by the channel service.
    }
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

final safetyMonitorStateProvider =
    StateNotifierProvider<SafetyMonitorStateNotifier, SafetyMonitorState>((
      ref,
    ) {
      return SafetyMonitorStateNotifier(ref);
    });

class SafetyMonitorStateNotifier
    extends DeviceSlotNotifier<SafetyMonitorState> {
  SafetyMonitorStateNotifier(Ref ref)
    : super(ref, DeviceType.safetyMonitor, const SafetyMonitorState());

  void updateSafetyStatus(bool isSafe) {
    state = state.copyWith(isSafe: isSafe, lastChecked: DateTime.now());
  }

  /// A monitor that cannot be read is not known to be safe.
  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      isSafe: false,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }

  /// A failed connect leaves an unsafe verdict on the card, with the device
  /// still named. An empty slot would read as "safe".
  @override
  void connectFailed(Object error) => setError(error);
}

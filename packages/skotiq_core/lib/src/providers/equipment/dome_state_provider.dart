import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

final domeStateProvider = StateNotifierProvider<DomeStateNotifier, DomeState>((
  ref,
) {
  return DomeStateNotifier(ref);
});

class DomeStateNotifier extends DeviceSlotNotifier<DomeState> {
  DomeStateNotifier(Ref ref) : super(ref, DeviceType.dome, const DomeState());

  void updateAzimuth(double azimuth) {
    state = state.copyWith(azimuth: azimuth);
  }

  void updateShutterStatus(ShutterStatus status) {
    state = state.copyWith(shutterStatus: status);
  }

  /// Apply one live telemetry read from the driver.
  ///
  /// Single state write so the card cannot render a half-updated dome (e.g. a
  /// new azimuth against the previous shutter state).
  ///
  /// Nothing here is *defaulted*: callers pass [ShutterStatus.unknown]
  /// explicitly when the driver exposes no shutter, so an unreadable shutter
  /// renders as `Unknown` rather than the fabricated `Closed` an operator would
  /// act on. A null argument means "this read carried no value for that field",
  /// which leaves the previous reading in place. Position telemetry alone never
  /// flips the connection state.
  void applyStatus({
    double? azimuth,
    ShutterStatus? shutterStatus,
    bool? isSlewing,
    bool? isAtHome,
    bool? isParked,
    bool? isSlaved,
  }) {
    state = state.copyWith(
      azimuth: azimuth,
      shutterStatus: shutterStatus,
      isSlewing: isSlewing,
      isAtHome: isAtHome,
      isParked: isParked,
      isSlaved: isSlaved,
    );
  }

  void setSlewing(bool slewing) {
    state = state.copyWith(isSlewing: slewing);
  }

  void setParked(bool parked) {
    state = state.copyWith(isParked: parked);
  }

  void setSlaved(bool slaved) {
    state = state.copyWith(isSlaved: slaved);
  }
}

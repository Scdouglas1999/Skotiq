import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';
import '../profiles_provider.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Camera state provider
final cameraStateProvider =
    StateNotifierProvider<CameraStateNotifier, CameraStateSnapshot>((ref) {
      return CameraStateNotifier(ref);
    });

/// The setpoint the user last asked the cooler to hold this session, or null
/// before any. A warm-up's ramp steps are not a goal and never land here.
final cameraCoolingGoalProvider = StateProvider<double?>((ref) => null);

/// The temperature a "Cool to" action cools to: the user's goal this
/// session, else the profile's cooling setpoint, else the cooler's current
/// setpoint. It does not follow a warm-up's ramp.
final cameraCoolToTargetProvider = Provider<double>((ref) {
  final goal = ref.watch(cameraCoolingGoalProvider);
  if (goal != null) return goal;
  final profileTarget = ref.watch(
    activeEquipmentProfileProvider.select((p) => p?.defaultCoolingTemp),
  );
  if (profileTarget != null) return profileTarget;
  return ref.watch(cameraStateProvider.select((s) => s.targetTemp));
});

class CameraStateNotifier extends DeviceSlotNotifier<CameraStateSnapshot> {
  CameraStateNotifier(Ref ref)
    : super(ref, DeviceType.camera, const CameraStateSnapshot());

  void updateTemperature(double temp, [double? power]) {
    state = state.copyWith(
      temperature: temp,
      coolerPower: power,
      clearCoolerPower: power == null,
      lastSuccessfulCommunication: DateTime.now(),
    );
  }

  /// Record the gain, offset and binning the camera reports it is using.
  void updateReadout({
    required int gain,
    required int offset,
    required int binX,
    required int binY,
  }) {
    state = state.copyWith(
      gain: gain,
      offset: offset,
      binning: '${binX}x$binY',
    );
  }

  /// Record one setting the host just applied (a `PropertyChanged` event);
  /// the others keep their last reading.
  void applySetting({int? gain, int? offset, String? binning}) {
    state = state.copyWith(gain: gain, offset: offset, binning: binning);
  }

  /// Update target temperature setting (persists across navigation)
  void setTargetTemp(double temp) {
    state = state.copyWith(targetTemp: temp);
  }

  /// Update cooling state (on/off)
  void setCooling(bool isCooling) {
    state = state.copyWith(isCooling: isCooling);
  }

  /// Update warming state (gradual warm-up in progress)
  void setWarming(bool isWarming) {
    state = state.copyWith(isWarming: isWarming);
  }

  /// Apply an acknowledged cooler-off command without leaving stale telemetry
  /// that makes shutdown/risk UI believe the TEC is still energized. A future
  /// device status event may repopulate cooler power if the driver reports it.
  void markCoolingDisabled() {
    state = state.copyWith(
      isCooling: false,
      isWarming: false,
      clearCoolerPower: true,
      lastSuccessfulCommunication: DateTime.now(),
    );
  }

  void setExposing(bool isExposing, {double? progress}) {
    state = state.copyWith(
      isExposing: isExposing,
      exposureProgress: progress,
      lastSuccessfulCommunication: DateTime.now(),
    );
  }

  /// Update last successful communication timestamp
  void updateCommunication() {
    state = state.copyWith(lastSuccessfulCommunication: DateTime.now());
  }
}

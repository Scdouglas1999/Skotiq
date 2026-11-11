import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

final coverCalibratorStateProvider =
    StateNotifierProvider<CoverCalibratorStateNotifier, CoverCalibratorState>((
      ref,
    ) {
      return CoverCalibratorStateNotifier(ref);
    });

class CoverCalibratorStateNotifier
    extends DeviceSlotNotifier<CoverCalibratorState> {
  CoverCalibratorStateNotifier(Ref ref)
    : super(ref, DeviceType.coverCalibrator, const CoverCalibratorState());

  void updateCoverStatus(CoverStatus status) {
    state = state.copyWith(coverStatus: status);
  }

  void updateCalibratorStatus(CalibratorStatus status) {
    state = state.copyWith(calibratorStatus: status);
  }

  void updateBrightness(int brightness) {
    state = state.copyWith(brightness: brightness);
  }

  void updateMaxBrightness(int maxBrightness) {
    state = state.copyWith(maxBrightness: maxBrightness);
  }
}

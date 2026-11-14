import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

final rotatorStateProvider =
    StateNotifierProvider<RotatorStateNotifier, RotatorState>((ref) {
      return RotatorStateNotifier(ref);
    });

class RotatorStateNotifier extends DeviceSlotNotifier<RotatorState> {
  RotatorStateNotifier(Ref ref)
    : super(ref, DeviceType.rotator, const RotatorState());

  void updatePosition(double position, {double? mechanicalPosition}) {
    state = state.copyWith(
      position: position,
      mechanicalPosition: mechanicalPosition,
    );
  }

  void setMoving(bool moving) {
    state = state.copyWith(isMoving: moving);
  }

  void setReversed(bool reversed) {
    state = state.copyWith(isReversed: reversed);
  }
}

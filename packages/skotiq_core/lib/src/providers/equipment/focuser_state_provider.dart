import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/autofocus_result.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

final focuserStateProvider =
    StateNotifierProvider<FocuserStateNotifier, FocuserState>((ref) {
      return FocuserStateNotifier(ref);
    });

class FocuserStateNotifier extends DeviceSlotNotifier<FocuserState> {
  FocuserStateNotifier(Ref ref)
    : super(ref, DeviceType.focuser, const FocuserState());

  @override
  void setConnected({
    int? maxPosition,
    double? stepSize,
    bool? isAbsolute,
    bool? hasTemperature,
  }) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.connected,
      maxPosition: maxPosition,
      stepSize: stepSize,
      isAbsolute: isAbsolute,
      hasTemperature: hasTemperature,
      clearError: true,
    );
  }

  void updatePosition(int position) {
    state = state.copyWith(position: position);
  }

  void updateTemperature(double temp) {
    state = state.copyWith(temperature: temp);
  }

  void setMoving(bool moving) {
    state = state.copyWith(isMoving: moving);
  }
}

final autofocusResultProvider = StateProvider<AutofocusResult?>((ref) => null);

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

final guiderStateProvider =
    StateNotifierProvider<GuiderStateNotifier, GuiderState>((ref) {
      return GuiderStateNotifier(ref);
    });

class GuiderStateNotifier extends DeviceSlotNotifier<GuiderState> {
  GuiderStateNotifier(Ref ref)
    : super(ref, DeviceType.guider, const GuiderState());

  /// A guider that died still owes the operator a reason: the built-in
  /// guider's task can fail on its own ("Calibration star match failed") and
  /// report a disconnect right after the error. Keeping `lastError` here lets
  /// the Guiding panel name the failure instead of "No guider connected".
  @override
  void setDisconnected() {
    state = GuiderState(
      autoReconnectEnabled: state.autoReconnectEnabled,
      lastError: state.lastError,
    );
  }

  void setGuiding(bool guiding) {
    state = state.copyWith(isGuiding: guiding);
  }

  void updateRms(double ra, double dec, double total) {
    state = state.copyWith(rmsRa: ra, rmsDec: dec, rmsTotal: total);
  }

  /// Record the guider's pixel scale (arcsec/px), or clear it with null when
  /// the guider reports none.
  void setPixelScale(double? arcsecPerPixel) {
    final known =
        arcsecPerPixel != null && arcsecPerPixel.isFinite && arcsecPerPixel > 0;
    state = state.copyWith(
      pixelScaleArcsecPerPixel: known ? arcsecPerPixel : null,
      clearPixelScale: !known,
    );
  }
}

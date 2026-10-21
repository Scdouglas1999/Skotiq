// The device commands the Overview, Camera and Focus tabs issue, behind one
// seam so a widget test swaps in a fake.
//
// Each command goes to the service the rest of the app already uses for it.
// Every method throws on failure; the tab shows the error. Nothing here
// parks the mount or stops a run: there is no such method.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

abstract interface class NightPanelOps {
  /// Cooler on at [targetTemp] °C.
  Future<void> setCoolerSetpoint(double targetTemp);

  /// The gradual warm-up (`CameraWarmupController`), which turns the cooler
  /// off once its power reaches zero.
  Future<void> warmUpCamera();

  /// Cooler off at once.
  Future<void> coolerOff();

  /// The manual (snapshot and loop) exposure settings.
  void updateManualExposure(ExposureSettings settings);

  /// Zero-based slot.
  Future<void> setFilterSlot(int slot);

  Future<void> moveFocuserBy(int steps);
  Future<void> moveFocuserTo(int position);
  Future<void> haltFocuser();

  /// Cancels an autofocus this screen did not start (a sequencer step).
  Future<void> cancelAutofocus();

  /// Starts PHD2 looping (the "Before you start" guider row).
  Future<void> startGuiderLoop();
}

final nightPanelOpsProvider = Provider<NightPanelOps>(ServiceNightPanelOps.new);

class ServiceNightPanelOps implements NightPanelOps {
  ServiceNightPanelOps(this._ref);

  final Ref _ref;

  DeviceService get _devices => _ref.read(deviceServiceProvider);

  @override
  Future<void> setCoolerSetpoint(double targetTemp) =>
      _devices.setCameraCooling(enabled: true, targetTemp: targetTemp);

  @override
  Future<void> warmUpCamera() => _devices.warmCamera();

  @override
  Future<void> coolerOff() async {
    _devices.cancelWarmCamera(restorePriorSetting: false);
    await _devices.setCameraCooling(enabled: false);
  }

  @override
  void updateManualExposure(ExposureSettings settings) =>
      _ref.read(manualExposureSettingsUpdaterProvider).update(settings);

  @override
  Future<void> setFilterSlot(int slot) => _devices.setFilterWheelPosition(slot);

  @override
  Future<void> moveFocuserBy(int steps) => _devices.moveFocuserRelative(steps);

  @override
  Future<void> moveFocuserTo(int position) => _devices.moveFocuserTo(position);

  @override
  Future<void> haltFocuser() => _devices.haltFocuser();

  @override
  Future<void> cancelAutofocus() => _devices.cancelAutofocus();

  @override
  Future<void> startGuiderLoop() => _ref.read(phd2ControllerProvider).loop();
}

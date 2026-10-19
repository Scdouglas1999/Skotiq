// What the Camera tab shows, gathered in one provider so a widget test pins
// it with a plain value (the tab's other inputs are the contract providers
// and `nightCoolerHistoryProvider`).
//
// Unknown stays null: a camera that never reported its cooler power shows a
// dash, and the setpoint shows only while the cooler is on, because the
// camera state carries a default setpoint even when nobody set one.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../actions/night_action_controller.dart';
import '../../data/plan/night_header_provider.dart';
import '../../data/plan/night_run_phase_provider.dart';
import '../../data/plan/plan_steps_provider.dart';
import '../../data/session/before_you_start_provider.dart';
import '../../data/session/session_stats_provider.dart';

/// How close to the setpoint the sensor reads "At setpoint", in °C.
const double kNightAtSetpointTolerance = 0.5;

/// The camera's own warm-up rate (`CameraWarmupController.start`), °C/min.
const double kNightWarmUpRatePerMin = 2;

enum NightCoolerState { notConnected, off, cooling, atSetpoint, warming }

/// Exposure values, from the manual settings or the run's step.
@immutable
class NightCaptureValues {
  const NightCaptureValues({
    this.exposureSecs,
    this.gain,
    this.offset,
    this.frameType,
    this.binning,
    this.filter,
  });

  factory NightCaptureValues.fromSettings(ExposureSettings settings) =>
      NightCaptureValues(
        exposureSecs: settings.exposureTime,
        gain: settings.gain,
        offset: settings.offset,
        frameType: settings.frameType,
        binning:
            settings.binningX == settings.binningY ? settings.binningX : null,
        filter: settings.filter,
      );

  factory NightCaptureValues.fromStep(ExposureNode node) => NightCaptureValues(
        exposureSecs: node.durationSecs,
        gain: node.gain,
        offset: node.offset,
        frameType: node.frameType,
        binning: node.binning.index + 1,
        filter: node.filter,
      );

  final double? exposureSecs;

  /// Null on a step means the camera's own gain or offset.
  final int? gain;
  final int? offset;
  final FrameType? frameType;

  /// N for N×N binning.
  final int? binning;
  final String? filter;
}

/// The wheel's slots and the focus offsets measured for them.
@immutable
class NightFilterSlotsVm {
  const NightFilterSlotsVm({
    required this.connected,
    this.names = const <String>[],
    this.current,
    this.moving = false,
    this.offsets = const <String, int>{},
    this.referenceFilter,
  });

  final bool connected;
  final List<String> names;

  /// Zero-based; null when the wheel has not reported one.
  final int? current;
  final bool moving;
  final Map<String, int> offsets;
  final String? referenceFilter;

  String? get currentName =>
      current != null && current! >= 0 && current! < names.length
          ? names[current!]
          : null;

  /// The current filter's focus offset from the reference filter; null
  /// when none was measured.
  int? get currentOffset {
    final name = currentName;
    return name == null ? null : offsets[name];
  }
}

@immutable
class NightCameraPanelVm {
  const NightCameraPanelVm({
    required this.canCommand,
    required this.runLive,
    required this.connected,
    required this.coolerState,
    required this.filters,
    this.deviceName,
    this.sensorTemp,
    this.setpoint,
    this.coolerPower,
    this.defaultSetpoint,
    this.manual,
    this.step,
    this.stepNodeId,
    this.stepLabel,
    this.stepIndex,
    this.sensorSpecs,
    this.savesTo,
    this.diskFreeBytes,
    this.nightsOfSpace,
  });

  /// False on a viewer that cannot command the rig.
  final bool canCommand;

  /// A run owns the camera, wheel and cooler: capture values are the step's
  /// and read-only, filter changes are off.
  final bool runLive;

  final bool connected;
  final String? deviceName;
  final NightCoolerState coolerState;
  final double? sensorTemp;

  /// The cooler's setpoint while it is on.
  final double? setpoint;
  final double? coolerPower;

  /// What the setpoint field starts with: the profile's setpoint.
  final double? defaultSetpoint;

  /// The manual exposure settings; null during a run.
  final ExposureSettings? manual;

  /// The run's active exposure step; null when the active step is not an
  /// exposure, or no run is live.
  final NightCaptureValues? step;
  final String? stepNodeId;

  /// "Ha 60 × 180 s"; the active step even when it is not an exposure.
  final String? stepLabel;

  /// 1-based, as the header counts steps.
  final int? stepIndex;

  final NightFilterSlotsVm filters;

  /// "4656 × 3520 · 3.80 µm"; null when the specs are unknown.
  final String? sensorSpecs;

  /// The capture folder.
  final String? savesTo;
  final int? diskFreeBytes;

  /// How many nights like the loaded plan the free space holds.
  final int? nightsOfSpace;
}

NightCoolerState nightCoolerState(CameraStateSnapshot camera) {
  if (camera.connectionState != DeviceConnectionState.connected) {
    return NightCoolerState.notConnected;
  }
  if (camera.isWarming) return NightCoolerState.warming;
  if (!camera.isCooling) return NightCoolerState.off;
  final temp = camera.temperature;
  if (temp != null &&
      (temp - camera.targetTemp).abs() <= kNightAtSetpointTolerance) {
    return NightCoolerState.atSetpoint;
  }
  return NightCoolerState.cooling;
}

String? _sensorSpecs(ResolvedCameraSensorSpecs? specs) {
  if (specs == null) return null;
  final width = specs.sensorWidthPx?.value;
  final height = specs.sensorHeightPx?.value;
  final pixel = specs.pixelSizeMicrons?.value;
  final parts = <String>[
    if (width != null && height != null) '$width × $height',
    if (pixel != null) '${pixel.toStringAsFixed(2)} µm',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

final nightCameraPanelProvider = Provider<NightCameraPanelVm>((ref) {
  final camera = ref.watch(cameraStateProvider);
  final wheel = ref.watch(filterWheelStateProvider);
  final offsets = ref.watch(filterOffsetProvider);
  final runLive = ref.watch(nightRunPhaseProvider).isRunLive;
  final connected = camera.connectionState == DeviceConnectionState.connected;
  final coolerState = nightCoolerState(camera);

  final activeStep = runLive ? ref.watch(nightActiveStepProvider) : null;
  final stepNode = activeStep?.node;
  final projection = ref.watch(nightDiskProjectionProvider);
  final free =
      projection?.freeBytes ?? ref.watch(nightCaptureFreeBytesProvider);
  final perNight = projection?.projectedBytes;
  final outputPath =
      ref.watch(appSettingsProvider).valueOrNull?.imageOutputPath ?? '';

  return NightCameraPanelVm(
    canCommand: ref.watch(backendCanCommandProvider),
    runLive: runLive,
    connected: connected,
    deviceName: camera.deviceName,
    coolerState: coolerState,
    sensorTemp: connected ? camera.temperature : null,
    setpoint: connected && (camera.isCooling || camera.isWarming)
        ? camera.targetTemp
        : null,
    coolerPower: connected ? camera.coolerPower : null,
    defaultSetpoint: ref.watch(nightCoolerSetpointProvider),
    manual: runLive ? null : ref.watch(exposureSettingsProvider),
    step:
        stepNode is ExposureNode ? NightCaptureValues.fromStep(stepNode) : null,
    stepNodeId: stepNode?.id,
    stepLabel: stepNode == null ? null : nightStepLabel(stepNode),
    stepIndex: runLive
        ? ref.watch(nightHeaderProvider.select((h) => h.stepIndex))
        : null,
    filters: NightFilterSlotsVm(
      connected: wheel.connectionState == DeviceConnectionState.connected,
      names: wheel.filterNames,
      current: wheel.currentPosition,
      moving: wheel.isMoving,
      offsets: offsets.offsets,
      referenceFilter: offsets.referenceFilter,
    ),
    sensorSpecs: _sensorSpecs(
      ref.watch(activeCameraSensorSpecsProvider).valueOrNull,
    ),
    savesTo: outputPath.isEmpty ? null : outputPath,
    diskFreeBytes: free,
    nightsOfSpace: free != null && perNight != null && perNight > 0
        ? free ~/ perNight
        : null,
  );
});

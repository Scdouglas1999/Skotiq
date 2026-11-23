import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/filters.dart';
// bridge-boundary: device_handlers
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:shelf/shelf.dart';

import '../command_correlator.dart';
import '../device_commands_route.dart';
import '../display_buffer_jpeg.dart';
import '../job_manager.dart';
import '../mount_move.dart';
import '../response_helpers.dart';
import '../utils/device_type_parser.dart';
import '../validation.dart';
import 'frame_measurement_headers.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_core/errors.dart';

part 'device_handlers/connection_lifecycle.dart';
part 'device_handlers/camera_handlers.dart';
part 'device_handlers/mount_handlers.dart';
part 'device_handlers/mount_guard_handlers.dart';
part 'device_handlers/focuser_handlers.dart';
part 'device_handlers/filter_wheel_handlers.dart';
part 'device_handlers/rotator_handlers.dart';
part 'device_handlers/helpers.dart';

/// Handlers for device control endpoints (camera, mount, focuser, filter wheel, rotator)
class DeviceHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    DeviceApi.connectDevice: handleConnectDevice,
    DeviceApi.disconnectDevice: handleDisconnectDevice,
    DeviceApi.cameraExpose: handleCameraExpose,
    DeviceApi.cameraAbort: handleCameraAbort,
    DeviceApi.cameraGetLastImage: handleCameraGetLastImage,
    DeviceApi.cameraGetLastImageJpeg: handleCameraGetLastImageJpeg,
    DeviceApi.cameraLiveViewFrame: handleCameraLiveViewFrame,
    DeviceApi.cameraSetCooling: handleCameraSetCooling,
    DeviceApi.cameraGetCooling: handleCameraGetCooling,
    DeviceApi.cameraStartWarmUp: handleCameraStartWarmUp,
    DeviceApi.cameraCancelWarmUp: handleCameraCancelWarmUp,
    DeviceApi.cameraGetWarmUp: handleCameraGetWarmUp,
    DeviceApi.cameraGetRetainedCaptures: handleCameraGetRetainedCaptures,
    DeviceApi.cameraRetrieveRetainedCapture:
        handleCameraRetrieveRetainedCapture,
    DeviceApi.cameraSetGain: handleCameraSetGain,
    DeviceApi.cameraSetOffset: handleCameraSetOffset,
    DeviceApi.cameraGetRecommendedSettings: handleCameraGetRecommendedSettings,
    DeviceApi.mountSlew: handleMountSlew,
    DeviceApi.mountSync: handleMountSync,
    DeviceApi.mountPark: handleMountPark,
    DeviceApi.mountSiteCapabilities: handleMountSiteCapabilities,
    DeviceApi.mountGetSite: handleMountGetSite,
    DeviceApi.mountSetSite: handleMountSetSite,
    DeviceApi.mountGetTime: handleMountGetTime,
    DeviceApi.mountSetTime: handleMountSetTime,
    DeviceApi.mountUnpark: handleMountUnpark,
    DeviceApi.mountSetTracking: handleMountSetTracking,
    DeviceApi.mountPulseGuide: handleMountPulseGuide,
    DeviceApi.mountAbort: handleMountAbort,
    DeviceApi.mountGetStatus: handleMountGetStatus,
    DeviceApi.mountSetTrackingRate: handleMountSetTrackingRate,
    DeviceApi.mountMoveAxis: handleMountMoveAxis,
    DeviceApi.mountSlewAltAz: handleMountSlewAltAz,
    DeviceApi.mountHomeHome: handleMountHome,
    DeviceApi.mountHomeFindHome: handleMountHome,
    DeviceApi.mountSetPark: handleMountSetPark,
    DeviceApi.mountGuardState: handleMountGuardState,
    DeviceApi.mountGuardAcknowledge: handleMountGuardAcknowledge,
    DeviceApi.mountGuardConfirmHome: handleMountGuardConfirmHome,
    DeviceApi.mountGuardSolve: handleMountGuardSolve,
    DeviceApi.mountGuardRecoverySync: handleMountGuardRecoverySync,
    DeviceApi.focuserMoveTo: handleFocuserMoveTo,
    DeviceApi.focuserMoveRelative: handleFocuserMoveRelative,
    DeviceApi.focuserHalt: handleFocuserHalt,
    DeviceApi.autofocusStart: handleAutofocusStart,
    DeviceApi.autofocusCancel: handleAutofocusCancel,
    DeviceApi.focuserBacklashCalibrationStart:
        handleFocuserBacklashCalibrationStart,
    DeviceApi.focuserBacklashCalibrationCancel:
        handleFocuserBacklashCalibrationCancel,
    DeviceApi.focuserBacklashCalibrationPlan:
        handleFocuserBacklashCalibrationPlan,
    DeviceApi.filterWheelSetPosition: handleFilterWheelSetPosition,
    DeviceApi.filterWheelGetPosition: handleFilterWheelGetPosition,
    DeviceApi.filterWheelGetNames: handleFilterWheelGetNames,
    DeviceApi.filterWheelSetNames: handleFilterWheelSetNames,
    DeviceApi.filterWheelSetByName: handleFilterWheelSetByName,
    DeviceApi.rotatorMoveTo: handleRotatorMoveTo,
    DeviceApi.rotatorMoveRelative: handleRotatorMoveRelative,
    DeviceApi.rotatorGetStatus: handleRotatorGetStatus,
    DeviceApi.rotatorHalt: handleRotatorHalt,
    DeviceApi.rotatorSync: handleRotatorSync,
    DeviceApi.rotatorSetReverse: handleRotatorSetReverse,
  };

  final ProviderContainer container;

  /// optional command correlator. When set, every action POST
  /// generates a UUID v4 commandId and includes it in the response. The
  /// later SkotiqEvent that completes the command picks the id back
  /// up via `correlatingCommandId`. Null in unit tests that don't care
  /// about correlation.
  final CommandCorrelator? commandCorrelator;

  /// Runs the long-running endpoints (autofocus, backlash calibration): they
  /// answer `{jobId, status: queued, commandId}` at once and report progress
  /// on the WS event stream.
  final JobManager jobManager;

  DeviceHandlers(
    this.container, {
    this.commandCorrelator,
    required this.jobManager,
  });

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'DeviceHandlers');

  void _logWarning(String message) =>
      _logger.warning(message, source: 'DeviceHandlers');
}

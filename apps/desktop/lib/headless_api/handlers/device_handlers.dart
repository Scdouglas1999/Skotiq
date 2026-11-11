import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// bridge-boundary: device_handlers
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../command_correlator.dart';
import '../device_commands_route.dart';
import '../display_buffer_jpeg.dart';
import '../job_manager.dart';
import '../response_helpers.dart';
import '../utils/device_type_parser.dart';
import '../validation.dart';
import 'frame_measurement_headers.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

part 'device_handlers/connection_lifecycle.dart';
part 'device_handlers/camera_handlers.dart';
part 'device_handlers/mount_handlers.dart';
part 'device_handlers/mount_guard_handlers.dart';
part 'device_handlers/focuser_handlers.dart';
part 'device_handlers/filter_wheel_handlers.dart';
part 'device_handlers/rotator_handlers.dart';
part 'device_handlers/helpers.dart';

/// MIME-style `Accept` header value that opts the caller into the
/// pre-synchronous response shape for autofocus / plate-solve /
/// center-on-target / polar-alignment. New clients should not send this;
/// the audit's spec keeps the legacy path so pinned mobile builds stay
/// functional during the rollout.
const String legacyBlockingAcceptType = 'application/x.skotiq.legacy-blocking';

/// True when the request's `Accept` header explicitly opts into the
/// legacy synchronous response shape.
bool requestPrefersLegacyBlocking(Request request) {
  final accept = request.headers['accept'] ?? '';
  if (accept.isEmpty) return false;
  // Accept may be a comma-separated list; do a case-insensitive contains
  // check against the documented opt-in type.
  return accept.toLowerCase().contains(legacyBlockingAcceptType);
}

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
    DeviceApi.cameraGetReadoutModes: handleCameraGetReadoutModes,
    DeviceApi.cameraSetReadoutMode: handleCameraSetReadoutMode,
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
  /// about correlation (those tests still validate the legacy response
  /// shape).
  final CommandCorrelator? commandCorrelator;

  /// optional job manager. When set, long-running endpoints
  /// (currently autofocus) return `{jobId, status: queued, commandId}`
  /// immediately and surface progress via the WS event stream. When null
  /// (unit tests / legacy callers), the handler falls back to the
  /// blocking response shape.
  final JobManager? jobManager;

  DeviceHandlers(this.container, {this.commandCorrelator, this.jobManager});

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'DeviceHandlers');

  void _logWarning(String message) =>
      _logger.warning(message, source: 'DeviceHandlers');
}

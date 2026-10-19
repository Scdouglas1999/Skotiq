/// Declarative route table for direct device control.
///
/// Counterpart to `handlers/device_handlers.dart`. Combines the
/// connect/disconnect surface with the per-device-class action verbs
/// (camera, mount, focuser, filter wheel, rotator). Read-only equipment
/// status / capabilities lives in [buildEquipmentRoutes]; the discovery
/// surface (which devices exist) lives in
/// [buildDeviceDiscoveryRoutes].
library;

import '../handlers/device_handlers.dart';
import 'headless_route.dart';

/// Build the declarative route table for [DeviceHandlers].
List<HeadlessRoute> buildDeviceRoutes(DeviceHandlers h) => <HeadlessRoute>[
  // Device management
  HeadlessRoute(HttpMethod.post, '/api/devices/connect', h.handleConnectDevice),
  HeadlessRoute(
    HttpMethod.post,
    '/api/devices/disconnect',
    h.handleDisconnectDevice,
  ),

  // Camera Control
  HeadlessRoute(HttpMethod.post, '/api/camera/expose', h.handleCameraExpose),
  HeadlessRoute(HttpMethod.post, '/api/camera/abort', h.handleCameraAbort),
  HeadlessRoute(
    HttpMethod.get,
    '/api/camera/last-image',
    h.handleCameraGetLastImage,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/camera/last-image/jpeg',
    h.handleCameraGetLastImageJpeg,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/camera/live-view/frame',
    h.handleCameraLiveViewFrame,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/camera/cooling',
    h.handleCameraSetCooling,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/camera/cooling',
    h.handleCameraGetCooling,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/camera/readout-modes',
    h.handleCameraGetReadoutModes,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/camera/readoutMode',
    h.handleCameraSetReadoutMode,
  ),
  HeadlessRoute(HttpMethod.post, '/api/camera/gain', h.handleCameraSetGain),
  HeadlessRoute(HttpMethod.post, '/api/camera/offset', h.handleCameraSetOffset),
  HeadlessRoute(
    HttpMethod.get,
    '/api/camera/recommended-settings',
    h.handleCameraGetRecommendedSettings,
  ),

  // Mount Control
  HeadlessRoute(HttpMethod.post, '/api/mount/slew', h.handleMountSlew),
  HeadlessRoute(HttpMethod.post, '/api/mount/sync', h.handleMountSync),
  HeadlessRoute(HttpMethod.post, '/api/mount/park', h.handleMountPark),
  HeadlessRoute(
    HttpMethod.get,
    '/api/mount/site-capabilities',
    h.handleMountSiteCapabilities,
  ),
  HeadlessRoute(HttpMethod.get, '/api/mount/site', h.handleMountGetSite),
  HeadlessRoute(HttpMethod.post, '/api/mount/site', h.handleMountSetSite),
  HeadlessRoute(HttpMethod.get, '/api/mount/time', h.handleMountGetTime),
  HeadlessRoute(HttpMethod.post, '/api/mount/time', h.handleMountSetTime),
  HeadlessRoute(HttpMethod.post, '/api/mount/unpark', h.handleMountUnpark),
  HeadlessRoute(
    HttpMethod.post,
    '/api/mount/tracking',
    h.handleMountSetTracking,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/mount/pulse-guide',
    h.handleMountPulseGuide,
  ),
  HeadlessRoute(HttpMethod.post, '/api/mount/abort', h.handleMountAbort),
  HeadlessRoute(HttpMethod.get, '/api/mount/status', h.handleMountGetStatus),
  HeadlessRoute(
    HttpMethod.post,
    '/api/mount/set-tracking-rate',
    h.handleMountSetTrackingRate,
  ),
  HeadlessRoute(HttpMethod.post, '/api/mount/move-axis', h.handleMountMoveAxis),
  HeadlessRoute(
    HttpMethod.post,
    '/api/mount/slew-alt-az',
    h.handleMountSlewAltAz,
  ),
  HeadlessRoute(HttpMethod.post, '/api/mount/home', h.handleMountHome),
  // The original spelling, kept so clients built before `/api/mount/home`
  // existed keep working. Same handler, same checks.
  HeadlessRoute(HttpMethod.post, '/api/mount/find-home', h.handleMountHome),
  HeadlessRoute(HttpMethod.post, '/api/mount/set-park', h.handleMountSetPark),

  // Focuser Control
  HeadlessRoute(HttpMethod.post, '/api/focuser/move-to', h.handleFocuserMoveTo),
  HeadlessRoute(
    HttpMethod.post,
    '/api/focuser/move-relative',
    h.handleFocuserMoveRelative,
  ),
  HeadlessRoute(HttpMethod.post, '/api/focuser/halt', h.handleFocuserHalt),
  HeadlessRoute(
    HttpMethod.post,
    '/api/focuser/autofocus/start',
    h.handleAutofocusStart,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/focuser/autofocus/cancel',
    h.handleAutofocusCancel,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/focuser/backlash-calibration/start',
    h.handleFocuserBacklashCalibrationStart,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/focuser/backlash-calibration/cancel',
    h.handleFocuserBacklashCalibrationCancel,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/focuser/backlash-calibration/plan',
    h.handleFocuserBacklashCalibrationPlan,
  ),

  // Filter Wheel Control
  HeadlessRoute(
    HttpMethod.post,
    '/api/filter-wheel/position',
    h.handleFilterWheelSetPosition,
  ),
  // GET sibling of POST /api/filter-wheel/position so mobile
  // can render the current slot, name, and "is moving" flag.
  HeadlessRoute(
    HttpMethod.get,
    '/api/filter-wheel/position',
    h.handleFilterWheelGetPosition,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/filter-wheel/names',
    h.handleFilterWheelGetNames,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/filter-wheel/names',
    h.handleFilterWheelSetNames,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/filter-wheel/set-by-name',
    h.handleFilterWheelSetByName,
  ),

  // Rotator Control
  HeadlessRoute(HttpMethod.post, '/api/rotator/move-to', h.handleRotatorMoveTo),
  HeadlessRoute(
    HttpMethod.post,
    '/api/rotator/move-relative',
    h.handleRotatorMoveRelative,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/rotator/status',
    h.handleRotatorGetStatus,
  ),
  HeadlessRoute(HttpMethod.post, '/api/rotator/halt', h.handleRotatorHalt),
  HeadlessRoute(HttpMethod.post, '/api/rotator/sync', h.handleRotatorSync),
  HeadlessRoute(
    HttpMethod.post,
    '/api/rotator/set-reverse',
    h.handleRotatorSetReverse,
  ),
];

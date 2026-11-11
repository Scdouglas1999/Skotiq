import '../api_route.dart';

enum DeviceApi implements ApiEndpoint {
  connectDevice(
    ApiRoute.post(
      '/api/devices/connect',
      resource: ApiResource.devices,
      rate: ApiRateTier.highRisk,
      audit: 'device_connect',
    ),
  ),
  disconnectDevice(
    ApiRoute.post(
      '/api/devices/disconnect',
      resource: ApiResource.devices,
      rate: ApiRateTier.highRisk,
      audit: 'device_disconnect',
    ),
  ),
  cameraExpose(
    ApiRoute.post(
      '/api/camera/expose',
      resource: ApiResource.camera,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  cameraAbort(
    ApiRoute.post(
      '/api/camera/abort',
      resource: ApiResource.camera,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  cameraGetLastImage(
    ApiRoute.get('/api/camera/last-image', resource: ApiResource.camera),
  ),
  cameraGetLastImageJpeg(
    ApiRoute.get('/api/camera/last-image/jpeg', resource: ApiResource.camera),
  ),
  cameraLiveViewFrame(
    ApiRoute.get(
      '/api/camera/live-view/frame',
      resource: ApiResource.camera,
      bucket: ApiBucket.liveView,
    ),
  ),
  cameraSetCooling(
    ApiRoute.post(
      '/api/camera/cooling',
      resource: ApiResource.camera,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  cameraGetCooling(
    ApiRoute.get('/api/camera/cooling', resource: ApiResource.camera),
  ),
  cameraStartWarmUp(
    ApiRoute.post(
      '/api/camera/warm-up',
      resource: ApiResource.camera,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  cameraCancelWarmUp(
    ApiRoute.post(
      '/api/camera/warm-up/cancel',
      resource: ApiResource.camera,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  cameraGetWarmUp(
    ApiRoute.get('/api/camera/warm-up', resource: ApiResource.camera),
  ),
  cameraGetReadoutModes(
    ApiRoute.get('/api/camera/readout-modes', resource: ApiResource.camera),
  ),
  cameraSetReadoutMode(
    ApiRoute.post(
      '/api/camera/readoutMode',
      resource: ApiResource.camera,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  cameraSetGain(
    ApiRoute.post(
      '/api/camera/gain',
      resource: ApiResource.camera,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  cameraSetOffset(
    ApiRoute.post(
      '/api/camera/offset',
      resource: ApiResource.camera,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  cameraGetRecommendedSettings(
    ApiRoute.get(
      '/api/camera/recommended-settings',
      resource: ApiResource.camera,
    ),
  ),
  mountSlew(
    ApiRoute.post(
      '/api/mount/slew',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_slew',
      sessionOwner: true,
    ),
  ),
  mountSync(
    ApiRoute.post(
      '/api/mount/sync',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  mountPark(
    ApiRoute.post(
      '/api/mount/park',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_park',
      sessionOwner: true,
    ),
  ),
  mountSiteCapabilities(
    ApiRoute.get('/api/mount/site-capabilities', resource: ApiResource.mount),
  ),
  mountGetSite(ApiRoute.get('/api/mount/site', resource: ApiResource.mount)),
  mountSetSite(
    ApiRoute.post(
      '/api/mount/site',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
    ),
  ),
  mountGetTime(ApiRoute.get('/api/mount/time', resource: ApiResource.mount)),
  mountSetTime(
    ApiRoute.post(
      '/api/mount/time',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
    ),
  ),
  mountUnpark(
    ApiRoute.post(
      '/api/mount/unpark',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_unpark',
      sessionOwner: true,
    ),
  ),
  mountSetTracking(
    ApiRoute.post(
      '/api/mount/tracking',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  mountPulseGuide(
    ApiRoute.post(
      '/api/mount/pulse-guide',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  mountAbort(
    ApiRoute.post(
      '/api/mount/abort',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  mountGetStatus(
    ApiRoute.get('/api/mount/status', resource: ApiResource.mount),
  ),
  mountSetTrackingRate(
    ApiRoute.post(
      '/api/mount/set-tracking-rate',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  mountMoveAxis(
    ApiRoute.post(
      '/api/mount/move-axis',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  mountSlewAltAz(
    ApiRoute.post(
      '/api/mount/slew-alt-az',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_slew_alt_az',
      sessionOwner: true,
    ),
  ),
  mountHomeHome(
    ApiRoute.post(
      '/api/mount/home',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_home',
      sessionOwner: true,
    ),
  ),
  mountHomeFindHome(
    ApiRoute.post(
      '/api/mount/find-home',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_home',
      sessionOwner: true,
    ),
  ),
  mountSetPark(
    ApiRoute.post(
      '/api/mount/set-park',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_set_park',
      sessionOwner: true,
    ),
  ),
  mountGuardState(
    ApiRoute.get('/api/mount/guard', resource: ApiResource.mount),
  ),
  mountGuardAcknowledge(
    ApiRoute.post(
      '/api/mount/guard/acknowledge',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  mountGuardConfirmHome(
    ApiRoute.post(
      '/api/mount/guard/confirm-home',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_guard_confirm_home',
      sessionOwner: true,
    ),
  ),
  mountGuardSolve(
    ApiRoute.post(
      '/api/mount/guard/solve',
      resource: ApiResource.mount,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  mountGuardRecoverySync(
    ApiRoute.post(
      '/api/mount/guard/recovery-sync',
      resource: ApiResource.mount,
      rate: ApiRateTier.highRisk,
      audit: 'mount_guard_recovery_sync',
      sessionOwner: true,
    ),
  ),
  focuserMoveTo(
    ApiRoute.post(
      '/api/focuser/move-to',
      resource: ApiResource.focuser,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  focuserMoveRelative(
    ApiRoute.post(
      '/api/focuser/move-relative',
      resource: ApiResource.focuser,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  focuserHalt(
    ApiRoute.post(
      '/api/focuser/halt',
      resource: ApiResource.focuser,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  autofocusStart(
    ApiRoute.post(
      '/api/focuser/autofocus/start',
      resource: ApiResource.focuser,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  autofocusCancel(
    ApiRoute.post(
      '/api/focuser/autofocus/cancel',
      resource: ApiResource.focuser,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  focuserBacklashCalibrationStart(
    ApiRoute.post(
      '/api/focuser/backlash-calibration/start',
      resource: ApiResource.focuser,
      rate: ApiRateTier.control,
    ),
  ),
  focuserBacklashCalibrationCancel(
    ApiRoute.post(
      '/api/focuser/backlash-calibration/cancel',
      resource: ApiResource.focuser,
      rate: ApiRateTier.control,
    ),
  ),
  focuserBacklashCalibrationPlan(
    ApiRoute.post(
      '/api/focuser/backlash-calibration/plan',
      resource: ApiResource.focuser,
      rate: ApiRateTier.control,
    ),
  ),
  filterWheelSetPosition(
    ApiRoute.post(
      '/api/filter-wheel/position',
      resource: ApiResource.filterWheel,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  filterWheelGetPosition(
    ApiRoute.get(
      '/api/filter-wheel/position',
      resource: ApiResource.filterWheel,
    ),
  ),
  filterWheelGetNames(
    ApiRoute.get('/api/filter-wheel/names', resource: ApiResource.filterWheel),
  ),
  filterWheelSetNames(
    ApiRoute.post(
      '/api/filter-wheel/names',
      resource: ApiResource.filterWheel,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  filterWheelSetByName(
    ApiRoute.post(
      '/api/filter-wheel/set-by-name',
      resource: ApiResource.filterWheel,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  rotatorMoveTo(
    ApiRoute.post(
      '/api/rotator/move-to',
      resource: ApiResource.rotator,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  rotatorMoveRelative(
    ApiRoute.post(
      '/api/rotator/move-relative',
      resource: ApiResource.rotator,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  rotatorGetStatus(
    ApiRoute.get('/api/rotator/status', resource: ApiResource.rotator),
  ),
  rotatorHalt(
    ApiRoute.post(
      '/api/rotator/halt',
      resource: ApiResource.rotator,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  rotatorSync(
    ApiRoute.post(
      '/api/rotator/sync',
      resource: ApiResource.rotator,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  rotatorSetReverse(
    ApiRoute.post(
      '/api/rotator/set-reverse',
      resource: ApiResource.rotator,
      rate: ApiRateTier.control,
    ),
  );

  const DeviceApi(this.route);

  @override
  final ApiRoute route;
}

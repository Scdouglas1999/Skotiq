part of '../ffi_backend.dart';

extension _FfiBackendBridgeModelMappers on _FfiBackendBase {
  dart_status.CameraStatus _fromBridgeCameraStatus(
    bridge_device.CameraStatus s,
  ) {
    return dart_status.CameraStatus(
      connected: s.connected,
      state: _fromBridgeCameraState(s.state),
      sensorTemp: s.sensorTemp,
      coolerPower: s.coolerPower,
      targetTemp: s.targetTemp,
      coolerOn: s.coolerOn,
      gain: s.gain,
      offset: s.offset,
      binX: s.binX,
      binY: s.binY,
      sensorWidth: s.sensorWidth,
      sensorHeight: s.sensorHeight,
      pixelSizeX: s.pixelSizeX,
      pixelSizeY: s.pixelSizeY,
      maxAdu: s.maxAdu,
      canCool: s.canCool,
      canSetGain: s.canSetGain,
      canSetOffset: s.canSetOffset,
    );
  }

  dart_types.CameraState _fromBridgeCameraState(bridge_device.CameraState s) {
    switch (s) {
      case bridge_device.CameraState.idle:
        return dart_types.CameraState.idle;
      case bridge_device.CameraState.waiting:
        return dart_types.CameraState.waiting;
      case bridge_device.CameraState.exposing:
        return dart_types.CameraState.exposing;
      case bridge_device.CameraState.reading:
        return dart_types.CameraState.reading;
      case bridge_device.CameraState.download:
        return dart_types.CameraState.download;
      case bridge_device.CameraState.error:
        return dart_types.CameraState.error;
    }
  }

  dart_status.MountStatus _fromBridgeMountStatus(bridge_device.MountStatus s) {
    return dart_status.MountStatus(
      connected: s.connected,
      tracking: s.tracking,
      slewing: s.slewing,
      parked: s.parked,
      atHome: s.atHome ?? false,
      sideOfPier: s.sideOfPier == null
          ? dart_types.PierSide.unknown
          : _fromBridgePierSide(s.sideOfPier!),
      rightAscension: s.rightAscension,
      declination: s.declination,
      // Pass the horizon frame through as the native side reported it. These
      // three carried `?? 0.0`, which turned "this mount cannot say" — what
      // `sim_gate::apply_derived_mount_telemetry` returns when no observing
      // site is configured — into a settled `0.00°` on every panel that
      // prints them. The panels already render `--` for null.
      altitude: s.altitude,
      azimuth: s.azimuth,
      siderealTime: s.siderealTime,
      trackingRate: s.trackingRate == null
          ? dart_caps.TrackingRate.sidereal
          : _fromBridgeTrackingRate(s.trackingRate!),
      canPark: s.canPark,
      canSlew: s.canSlew,
      canSync: s.canSync,
      canPulseGuide: s.canPulseGuide,
      canSetTrackingRate: s.canSetTrackingRate,
      availability: s.availability.map(
        (key, value) => MapEntry(key, _fieldAvailabilityToWire(value)),
      ),
    );
  }

  /// Serialize a flutter_rust_bridge [FieldAvailability] to the stable wire
  /// string the headless API and clients expect ('available' / 'unsupported' /
  /// `error: <reason>`). Using `.toString()` would leak the Dart class name
  /// ('FieldAvailability.available()') into the JSON contract.
  String _fieldAvailabilityToWire(bridge_device.FieldAvailability v) {
    return v.when(
      available: () => 'available',
      unsupported: () => 'unsupported',
      error: (reason) => 'error: $reason',
    );
  }

  dart_types.PierSide _fromBridgePierSide(bridge_device.PierSide s) {
    switch (s) {
      case bridge_device.PierSide.east:
        return dart_types.PierSide.east;
      case bridge_device.PierSide.west:
        return dart_types.PierSide.west;
      case bridge_device.PierSide.unknown:
        return dart_types.PierSide.unknown;
    }
  }

  dart_caps.TrackingRate _fromBridgeTrackingRate(bridge_device.TrackingRate r) {
    switch (r) {
      case bridge_device.TrackingRate.sidereal:
        return dart_caps.TrackingRate.sidereal;
      case bridge_device.TrackingRate.lunar:
        return dart_caps.TrackingRate.lunar;
      case bridge_device.TrackingRate.solar:
        return dart_caps.TrackingRate.solar;
      case bridge_device.TrackingRate.king:
        return dart_caps.TrackingRate.king;
      case bridge_device.TrackingRate.custom:
        return dart_caps.TrackingRate.custom;
    }
  }

  dart_status.FocuserStatus _fromBridgeFocuserStatus(
    bridge_device.FocuserStatus s,
  ) {
    return dart_status.FocuserStatus(
      connected: s.connected,
      position: s.position,
      moving: s.moving,
      temperature: s.temperature,
      maxPosition: s.maxPosition,
      stepSize: s.stepSize,
      isAbsolute: s.isAbsolute,
      hasTemperature: s.hasTemperature,
    );
  }

  dart_status.FilterWheelStatus _fromBridgeFilterWheelStatus(
    bridge_device.FilterWheelStatus s,
  ) {
    return dart_status.FilterWheelStatus(
      connected: s.connected,
      position: s.position,
      moving: s.moving,
      filterCount: s.filterCount,
      filterNames: s.filterNames,
    );
  }

  dart_status.RotatorStatus _fromBridgeRotatorStatus(
    bridge_device.RotatorStatus s,
  ) {
    return dart_status.RotatorStatus(
      connected: s.connected,
      position: s.position,
      moving: s.moving,
      mechanicalPosition: s.mechanicalPosition,
      isMoving: s.isMoving,
      canReverse: s.canReverse,
    );
  }

  // Type conversion helpers

  bridge.DeviceType _toBridgeDeviceType(DeviceType type) {
    switch (type) {
      case DeviceType.camera:
        return bridge.DeviceType.camera;
      case DeviceType.mount:
        return bridge.DeviceType.mount;
      case DeviceType.focuser:
        return bridge.DeviceType.focuser;
      case DeviceType.filterWheel:
        return bridge.DeviceType.filterWheel;
      case DeviceType.guider:
        return bridge.DeviceType.guider;
      case DeviceType.dome:
        return bridge.DeviceType.dome;
      case DeviceType.rotator:
        return bridge.DeviceType.rotator;
      case DeviceType.weather:
        return bridge.DeviceType.weather;
      case DeviceType.safetyMonitor:
        return bridge.DeviceType.safetyMonitor;
      case DeviceType.switch_:
        return bridge.DeviceType.switch_;
      case DeviceType.coverCalibrator:
        return bridge.DeviceType.coverCalibrator;
    }
  }

  DeviceType _fromBridgeDeviceType(bridge.DeviceType type) {
    switch (type) {
      case bridge.DeviceType.camera:
        return DeviceType.camera;
      case bridge.DeviceType.mount:
        return DeviceType.mount;
      case bridge.DeviceType.focuser:
        return DeviceType.focuser;
      case bridge.DeviceType.filterWheel:
        return DeviceType.filterWheel;
      case bridge.DeviceType.guider:
        return DeviceType.guider;
      case bridge.DeviceType.dome:
        return DeviceType.dome;
      case bridge.DeviceType.rotator:
        return DeviceType.rotator;
      case bridge.DeviceType.weather:
        return DeviceType.weather;
      case bridge.DeviceType.safetyMonitor:
        return DeviceType.safetyMonitor;
      case bridge.DeviceType.switch_:
        return DeviceType.switch_;
      case bridge.DeviceType.coverCalibrator:
        return DeviceType.coverCalibrator;
    }
  }

  DriverType _fromBridgeDriverType(bridge.DriverType type) {
    switch (type) {
      case bridge.DriverType.ascom:
        return DriverType.ascom;
      case bridge.DriverType.alpaca:
        return DriverType.alpaca;
      case bridge.DriverType.indi:
        return DriverType.indi;
      case bridge.DriverType.native:
        return DriverType.native;
      case bridge.DriverType.simulator:
        return DriverType.simulator;
    }
  }

  // Mappers
  models.AppSettings _fromBridgeSettings(bridge.AppSettings s) {
    final loc = s.location != null ? _fromBridgeLocation(s.location!) : null;
    return models.AppSettings(
      location: loc,
      theme: s.theme,
      language: s.language,
      autoConnect: s.autoConnect,
      // Map location fields to direct fields for compatibility
      latitude: loc?.latitude ?? 0.0,
      longitude: loc?.longitude ?? 0.0,
      elevation: loc?.elevation ?? 0.0,
      // Keep defaults for other fields
      fileNamingPattern: '',
      meridianFlipMinutes: 5,
      autoFocusEveryMinutes: 60,
      ditherEveryFrames: 3,
      plateSolveTimeout: 60,
      plateSolveSearchRadius: 30.0,
      discordWebhook: '',
      pushoverKey: '',
      pushoverUser: '',
    );
  }

  bridge.AppSettings _toBridgeSettings(models.AppSettings s) {
    // Use location if available, otherwise create from direct fields
    final loc =
        s.location ??
        (s.latitude != 0.0 || s.longitude != 0.0
            ? models.ObserverLocation(
                latitude: s.latitude,
                longitude: s.longitude,
                elevation: s.elevation,
              )
            : null);
    return bridge.AppSettings(
      location: loc != null ? _toBridgeLocation(loc) : null,
      theme: s.theme,
      language: s.language,
      autoConnect: s.autoConnect,
    );
  }

  models.ObserverLocation _fromBridgeLocation(bridge.ObserverLocation l) {
    return models.ObserverLocation(
      latitude: l.latitude,
      longitude: l.longitude,
      elevation: l.elevation,
    );
  }

  bridge.ObserverLocation _toBridgeLocation(models.ObserverLocation l) {
    return bridge.ObserverLocation(
      latitude: l.latitude,
      longitude: l.longitude,
      elevation: l.elevation,
    );
  }

  EquipmentProfile _fromBridgeProfile(bridge.EquipmentProfile p) {
    return EquipmentProfile(
      id: p.id,
      name: p.name,
      cameraId: p.cameraId,
      mountId: p.mountId,
      focuserId: p.focuserId,
      filterWheelId: p.filterWheelId,
      guiderId: p.guiderId,
      rotatorId: p.rotatorId,
      domeId: p.domeId,
      weatherId: p.weatherId,
      safetyMonitorId: p.safetyMonitorId,
      coverCalibratorId: p.coverCalibratorId,
      telescopeFocalLength: p.telescopeFocalLength,
      telescopeAperture: p.telescopeAperture,
    );
  }

  bridge.EquipmentProfile _toBridgeProfile(EquipmentProfile p) {
    return bridge.EquipmentProfile(
      id: p.id,
      name: p.name,
      cameraId: p.cameraId,
      mountId: p.mountId,
      focuserId: p.focuserId,
      filterWheelId: p.filterWheelId,
      guiderId: p.guiderId,
      rotatorId: p.rotatorId,
      domeId: p.domeId,
      weatherId: p.weatherId,
      safetyMonitorId: p.safetyMonitorId,
      coverCalibratorId: p.coverCalibratorId,
      // The bridge schema still carries the legacy telescope* field names,
      // while current Drift profiles store optics in focalLength/aperture.
      // Serialize the effective values so legacy and current rows both reach
      // FFI consumers (notably the headless planetarium FOV endpoint).
      telescopeFocalLength: p.focalLength > 0
          ? p.focalLength
          : p.telescopeFocalLength,
      telescopeAperture: p.aperture > 0 ? p.aperture : p.telescopeAperture,
    );
  }
}

/// DepthLock bridge conversions.
///
/// Separate from [_FfiBackendBridgeModelMappers] only because the goal models
/// are plain Dart classes with no device-status lineage; the conventions are
/// the same. Revisions and queue counters are `u64` in Rust and arrive as
/// `BigInt`; selection timestamps are `i64` and arrive as `PlatformInt64`.
/// Both collapse to `int` here — a revision that overflowed a Dart int would
/// mean 2^63 edits of one goal.
extension _FfiBackendDepthLockMappers on _FfiBackendBase {
  SkyRectangle _fromBridgeSkyRectangle(bridge_api.ApiSkyRectangle r) =>
      SkyRectangle(
        raDeg: r.raDeg,
        decDeg: r.decDeg,
        widthArcsec: r.widthArcsec,
        heightArcsec: r.heightArcsec,
        rotationDeg: r.rotationDeg,
      );

  bridge_api.ApiSkyRectangle _toBridgeSkyRectangle(SkyRectangle r) =>
      bridge_api.ApiSkyRectangle(
        raDeg: r.raDeg,
        decDeg: r.decDeg,
        widthArcsec: r.widthArcsec,
        heightArcsec: r.heightArcsec,
        rotationDeg: r.rotationDeg,
      );

  // The generated geometry uses `cd11`-style names where the models keep the
  // FITS `CD1_1` spelling; this is the only place the two meet.
  ReferenceGeometry _fromBridgeReferenceGeometry(
    bridge_api.ApiReferenceGeometry g,
  ) => ReferenceGeometry(
    width: g.width,
    height: g.height,
    crval1: g.crval1,
    crval2: g.crval2,
    crpix1: g.crpix1,
    crpix2: g.crpix2,
    cd1_1: g.cd11,
    cd1_2: g.cd12,
    cd2_1: g.cd21,
    cd2_2: g.cd22,
  );

  bridge_api.ApiReferenceGeometry _toBridgeReferenceGeometry(
    ReferenceGeometry g,
  ) => bridge_api.ApiReferenceGeometry(
    width: g.width,
    height: g.height,
    crval1: g.crval1,
    crval2: g.crval2,
    crpix1: g.crpix1,
    crpix2: g.crpix2,
    cd11: g.cd1_1,
    cd12: g.cd1_2,
    cd21: g.cd2_1,
    cd22: g.cd2_2,
  );

  AcquisitionSettings _fromBridgeAcquisitionSettings(
    bridge_api.ApiAcquisitionSettings a,
  ) => AcquisitionSettings(
    instrument: a.instrument,
    filter: a.filter,
    exposureSecs: a.exposureSecs,
    gain: a.gain,
    offset: a.offset,
    binX: a.binX,
    binY: a.binY,
    ccdTempC: a.ccdTempC,
  );

  bridge_api.ApiAcquisitionSettings _toBridgeAcquisitionSettings(
    AcquisitionSettings a,
  ) => bridge_api.ApiAcquisitionSettings(
    instrument: a.instrument,
    filter: a.filter,
    exposureSecs: a.exposureSecs,
    gain: a.gain,
    offset: a.offset,
    binX: a.binX,
    binY: a.binY,
    ccdTempC: a.ccdTempC,
  );

  DepthLockMeasurement _fromBridgeDepthMeasurement(
    bridge_api.ApiDepthMeasurement m,
  ) => DepthLockMeasurement(
    region: _fromBridgeSkyRectangle(m.region),
    background: _fromBridgeSkyRectangle(m.background),
    scaleArcsec: m.scaleArcsec,
    threshold: m.threshold,
    minCoverage: m.minCoverage,
    systematicFloorAdu: m.systematicFloorAdu,
    systematicFloorSource: m.systematicFloorSource,
  );

  bridge_api.ApiDepthMeasurement _toBridgeDepthMeasurement(
    DepthLockMeasurement m,
  ) => bridge_api.ApiDepthMeasurement(
    region: _toBridgeSkyRectangle(m.region),
    background: _toBridgeSkyRectangle(m.background),
    scaleArcsec: m.scaleArcsec,
    threshold: m.threshold,
    minCoverage: m.minCoverage,
    systematicFloorAdu: m.systematicFloorAdu,
    systematicFloorSource: m.systematicFloorSource,
  );

  DepthLockGoalDefinition _fromBridgeDepthGoalDefinition(
    bridge_api.ApiDepthGoalDefinition d,
  ) => DepthLockGoalDefinition(
    label: d.label,
    projectId: d.projectId,
    targetId: d.targetId,
    profileId: d.profileId,
    filterName: d.filterName,
    filterIndex: d.filterIndex,
    referencePath: d.referencePath,
    reference: _fromBridgeReferenceGeometry(d.reference),
    acquisition: _fromBridgeAcquisitionSettings(d.acquisition),
    temperatureToleranceC: d.temperatureToleranceC,
    darkPath: d.darkPath,
    flatPath: d.flatPath,
    measurement: _fromBridgeDepthMeasurement(d.measurement),
    enabled: d.enabled,
    automaticCompletion: d.automaticCompletion,
  );

  bridge_api.ApiDepthGoalDefinition _toBridgeDepthGoalDefinition(
    DepthLockGoalDefinition d,
  ) => bridge_api.ApiDepthGoalDefinition(
    label: d.label,
    projectId: d.projectId,
    targetId: d.targetId,
    profileId: d.profileId,
    filterName: d.filterName,
    filterIndex: d.filterIndex,
    referencePath: d.referencePath,
    reference: _toBridgeReferenceGeometry(d.reference),
    acquisition: _toBridgeAcquisitionSettings(d.acquisition),
    temperatureToleranceC: d.temperatureToleranceC,
    darkPath: d.darkPath,
    flatPath: d.flatPath,
    measurement: _toBridgeDepthMeasurement(d.measurement),
    enabled: d.enabled,
    automaticCompletion: d.automaticCompletion,
  );

  DepthLockForecast _fromBridgeDepthForecast(bridge_api.ApiDepthForecast f) =>
      DepthLockForecast(
        framesToThreshold: f.framesToThreshold,
        framesToConfirm: f.framesToConfirm,
        reachable: f.reachable,
        ceilingScore: f.ceilingScore,
        perFrameNoiseAdu: f.perFrameNoiseAdu,
        recentFrameNoiseAdu: f.recentFrameNoiseAdu,
        bestFrameNoiseAdu: f.bestFrameNoiseAdu,
      );

  DepthLockCurvePoint _fromBridgeDepthCurvePoint(
    bridge_api.ApiDepthCurvePoint p,
  ) => DepthLockCurvePoint(
    frames: p.frames,
    score: p.score,
    conservativeScore: p.conservativeScore,
    projected: p.projected,
  );

  DepthLockReport _fromBridgeDepthReport(bridge_api.ApiDepthReport r) =>
      DepthLockReport(
        state: DepthLockState.fromWire(r.state),
        score: r.score,
        conservativeScore: r.conservativeScore,
        uncertaintyAdu: r.uncertaintyAdu,
        coverage: r.coverage,
        evidenceFrames: r.evidenceFrames,
        confirmationFrames: r.confirmationFrames,
        reason: r.reason,
        forecast: r.forecast == null
            ? null
            : _fromBridgeDepthForecast(r.forecast!),
      );

  DepthLockGoal _fromBridgeDepthGoal(bridge_api.ApiDepthGoal g) =>
      DepthLockGoal(
        id: g.id,
        revision: g.revision.toInt(),
        definition: _fromBridgeDepthGoalDefinition(g.definition),
        selectedAtMs: g.selectedAtMs.toInt(),
        evidenceFrames: g.evidenceFrames,
        evidenceRevision: g.evidenceRevision.toInt(),
        analysisCurrent: g.analysisCurrent,
        report: g.report == null ? null : _fromBridgeDepthReport(g.report!),
        candidateFrames: g.candidateFrames,
        lastIssue: g.lastIssue,
        archivedRevisions: g.archivedRevisions,
        estimatorVersion: g.estimatorVersion,
      );

  DepthLockReferenceInfo _fromBridgeDepthReferenceInfo(
    bridge_api.ApiDepthReferenceInfo i,
  ) => DepthLockReferenceInfo(
    width: i.width,
    height: i.height,
    pixelType: i.pixelType,
    monochrome: i.monochrome,
    geometry: i.geometry == null
        ? null
        : _fromBridgeReferenceGeometry(i.geometry!),
    geometryIssue: i.geometryIssue,
    pixelScaleArcsec: i.pixelScaleArcsec,
    acquisition: i.acquisition == null
        ? null
        : _fromBridgeAcquisitionSettings(i.acquisition!),
    acquisitionIssue: i.acquisitionIssue,
  );

  DepthLockFloorSuggestion _fromBridgeDepthFloorSuggestion(
    bridge_api.ApiDepthFloorSuggestion s,
  ) => DepthLockFloorSuggestion(
    floorAdu: s.floorAdu,
    darkNoiseAdu: s.darkNoiseAdu,
    flatRelativeNoise: s.flatRelativeNoise,
    skyAdu: s.skyAdu,
    aperturePixels: s.aperturePixels,
    source: s.source,
  );

  DepthLockStatus _fromBridgeDepthLockStatus(bridge_api.ApiDepthLockStatus s) =>
      DepthLockStatus(
        available: s.available,
        goals: s.goals,
        queueCapacity: s.queueCapacity,
        queued: s.queued.toInt(),
        processed: s.processed.toInt(),
        dropped: s.dropped.toInt(),
        evidenceAdded: s.evidenceAdded.toInt(),
        evidenceRejected: s.evidenceRejected.toInt(),
        lastFrameMs: s.lastFrameMs.toInt(),
        maxFrameMs: s.maxFrameMs.toInt(),
      );
}

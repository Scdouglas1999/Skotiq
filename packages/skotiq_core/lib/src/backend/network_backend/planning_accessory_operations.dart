part of '../network_backend.dart';

mixin _NetworkBackendPlanningAccessoryOperations on _NetworkBackendTransport {
  Future<Map<String, dynamic>> awaitOperationResult(
    Map<String, dynamic> response, {
    required String operation,
    required Duration timeout,
  });

  Future<void> slewToTarget(double ra, double dec) async {
    await _post(FramingApi.slewToTarget, body: {'ra': ra, 'dec': dec});
  }

  /// Center on target with plate solving
  Future<Map<String, dynamic>> centerOnTarget({
    required double ra,
    required double dec,
    int? maxIterations,
    double? toleranceArcsec,
    double? exposureTime,
    int? binning,
    int? gain,
    bool? syncMount,
  }) async {
    final start = await _post(
      FramingApi.centerOnTarget,
      body: {
        'ra': ra,
        'dec': dec,
        if (maxIterations != null) 'maxIterations': maxIterations,
        if (toleranceArcsec != null) 'toleranceArcsec': toleranceArcsec,
        if (exposureTime != null) 'exposureTime': exposureTime,
        if (binning != null) 'binning': binning,
        if (gain != null) 'gain': gain,
        if (syncMount != null) 'syncMount': syncMount,
      },
    );
    return awaitOperationResult(
      start,
      operation: 'center on target',
      timeout: const Duration(minutes: 10),
    );
  }

  Future<void> syncMountToCoordinates(double ra, double dec) async {
    await _post(FramingApi.syncMount, body: {'ra': ra, 'dec': dec});
  }

  Future<Map<String, dynamic>> getCurrentPosition() async {
    final response = await _get(FramingApi.getCurrentPosition);
    return response;
  }

  Future<void> abortSlew() async {
    await _post(FramingApi.abortSlew);
  }

  /// Push a framing target to the imaging host (Plan Tonight handoff).
  Future<void> framingSetTarget({
    required double ra,
    required double dec,
    required String name,
  }) async {
    await _post(
      FramingApi.setTarget,
      body: {'ra': ra, 'dec': dec, 'name': name},
    );
  }

  // The headless endpoints require an explicit deviceId. Keep it on every
  // command/status/capability request so multi-dome hosts and the server's
  // connected-device validation address the same physical device.

  @override
  Future<void> domeOpenShutter(String deviceId) async {
    await _post(DomeApi.open, body: {'deviceId': deviceId});
  }

  @override
  Future<void> domeCloseShutter(String deviceId) async {
    await _post(DomeApi.close, body: {'deviceId': deviceId});
  }

  @override
  Future<void> domeSlewToAzimuth(String deviceId, double azimuth) async {
    await _post(DomeApi.slew, body: {'deviceId': deviceId, 'azimuth': azimuth});
  }

  /// Enable/disable dome-mount sync (slaving)
  @override
  Future<void> domeSetSlaved(String deviceId, bool slaved) async {
    await _post(
      DomeApi.domeSync,
      body: {'deviceId': deviceId, 'enable': slaved},
    );
  }

  @override
  Future<void> domePark(String deviceId) async {
    await _post(DomeApi.park, body: {'deviceId': deviceId});
  }

  @override
  Future<void> domeFindHome(String deviceId) async {
    await _post(DomeApi.home, body: {'deviceId': deviceId});
  }

  @override
  Future<void> domeAbortSlew(String deviceId) async {
    await _post(DomeApi.halt, body: {'deviceId': deviceId});
  }

  Future<Map<String, dynamic>> getDomeStatus(String deviceId) async {
    return await _get(DomeApi.status, query: {'deviceId': deviceId});
  }

  /// Typed dome telemetry for the equipment card's live readouts.
  ///
  /// Fails loudly when the host reports the dome disconnected rather than
  /// returning a default-valued status the card would render as real hardware
  /// state (azimuth 0, shutter closed).
  @override
  Future<HardwareDomeStatus> getHardwareDomeStatus(String deviceId) async {
    final json = await getDomeStatus(deviceId);
    if (json['connected'] != true) {
      throw StateError('Dome $deviceId is not connected on the host');
    }
    double? number(String key) => (json[key] as num?)?.toDouble();
    bool flag(String key) => json[key] == true;
    return HardwareDomeStatus(
      azimuth: number('azimuth'),
      altitude: number('altitude'),
      // canSetShutter false => the driver exposes no shutter; stay unknown.
      shutterStatus: flag('canSetShutter')
          ? _shutterCodeFromName(json['shutterState'])
          : null,
      isSlewing: flag('slewing'),
      isAtHome: flag('atHome'),
      isParked: flag('atPark'),
      isSlaved: flag('syncEnabled'),
    );
  }

  static int? _shutterCodeFromName(Object? name) {
    switch (name) {
      case 'open':
        return 0;
      case 'closed':
        return 1;
      case 'opening':
        return 2;
      case 'closing':
        return 3;
      case 'error':
        return 4;
      default:
        return null;
    }
  }

  Future<DomeCapabilities?> getDomeCapabilities(String deviceId) async {
    final json = await _get(
      DomeApi.capabilities,
      query: {'deviceId': deviceId},
    );
    return DomeCapabilities.fromJson(json);
  }

  // Safety monitor

  Future<Map<String, dynamic>> getSafetyStatus({String? deviceId}) async {
    return await _get(
      SafetyMonitorApi.safetyStatus,
      query: deviceId != null ? {'deviceId': deviceId} : null,
    );
  }

  @override
  Future<HardwareWeatherConditions> getHardwareWeatherConditions(
    String deviceId,
  ) async {
    final json = await _get(WeatherApi.getCurrent);
    if (json['hardwareConnected'] != true || json['deviceId'] != deviceId) {
      throw StateError('Weather device $deviceId is not connected on the host');
    }
    double? number(String key) => (json[key] as num?)?.toDouble();
    return HardwareWeatherConditions(
      temperature: number('temperature'),
      humidity: number('humidity'),
      pressure: number('pressure'),
      cloudCover: number('cloudCover'),
      dewPoint: number('dewPoint'),
      windSpeed: number('windSpeedMps') ?? number('windSpeed'),
      windDirection: number('windDirection'),
      skyQuality: number('skyQuality'),
      skyTemperature: number('skyTemperature'),
      rainRate: number('rainRate'),
    );
  }

  @override
  Future<bool> getHardwareSafetyStatus(String deviceId) async {
    final json = await getSafetyStatus(deviceId: deviceId);
    if (json['connected'] != true || json['isSafe'] is! bool) {
      throw StateError('Safety monitor $deviceId did not return a valid state');
    }
    return json['isSafe'] as bool;
  }

  Future<Map<String, dynamic>> getSafetySettings() async {
    return await _get(SafetyMonitorApi.getSafetySettings);
  }

  Future<void> updateSafetySettings(Map<String, dynamic> settings) async {
    await _post(SafetyMonitorApi.updateSafetySettings, body: settings);
  }

  Future<void> acknowledgeSafetyCondition({
    required String reason,
    int? durationMinutes,
  }) async {
    await _post(
      SafetyMonitorApi.acknowledgeUnsafe,
      body: {
        'reason': reason,
        if (durationMinutes != null) 'durationMinutes': durationMinutes,
      },
    );
  }

  /// Cancel a previously acknowledged/snoozed unsafe condition on the host.
  Future<void> cancelSafetyAcknowledgement() async {
    await _post(SafetyMonitorApi.cancelAcknowledgement);
  }

  /// Get switch states.
  ///
  /// Pass [deviceId] to scope to a single device — that returns the
  /// `{switchCount, switches:[...]}` single-device shape the per-channel UI
  /// consumes. Omit it for the all-devices summary
  /// (`{devicesConnected, devices:[...]}`).
  Future<Map<String, dynamic>> getSwitchStatus({String? deviceId}) async {
    return await _get(
      AuxiliaryApi.switchStatus,
      query: {
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      },
    );
  }

  /// Set a switch value. [deviceId] is required by the server
  /// (`POST /api/switch/set`); [value] is a `bool` for boolean switches or a
  /// `num` for analog ones.
  Future<void> setSwitch({
    required String deviceId,
    required int switchId,
    required dynamic value,
  }) async {
    await _post(
      AuxiliaryApi.switchSet,
      body: {'deviceId': deviceId, 'switchId': switchId, 'value': value},
    );
  }

  Future<Map<String, dynamic>> getCoverStatus(String deviceId) async {
    return await _get(AuxiliaryApi.coverStatus, query: {'deviceId': deviceId});
  }

  // The headless endpoints validate the addressed connected device. Preserve
  // [deviceId] on every remote command just as the local FFI backend does.

  @override
  Future<void> coverOpen(String deviceId) async {
    await _post(AuxiliaryApi.coverOpen, body: {'deviceId': deviceId});
  }

  @override
  Future<void> coverClose(String deviceId) async {
    await _post(AuxiliaryApi.coverClose, body: {'deviceId': deviceId});
  }

  @override
  Future<void> calibratorOn(String deviceId, int brightness) async {
    await _post(
      AuxiliaryApi.calibratorOn,
      body: {'deviceId': deviceId, 'brightness': brightness},
    );
  }

  @override
  Future<void> calibratorOff(String deviceId) async {
    await _post(AuxiliaryApi.calibratorOff, body: {'deviceId': deviceId});
  }

  /// Get the imaging host's complete unattended-scheduler state.
  Future<Map<String, dynamic>> getSchedulerState() async {
    return _get(SchedulerApi.getState);
  }

  /// Run a lifecycle command against the imaging host's scheduler engine.
  Future<Map<String, dynamic>> controlScheduler(
    String action, {
    bool confirmWarnings = false,
  }) async {
    return _post(
      SchedulerApi.control,
      body: {'action': action, if (confirmWarnings) 'confirmWarnings': true},
    );
  }

  /// Persist and apply scheduler scoring configuration on the imaging host.
  Future<Map<String, dynamic>> updateSchedulerConfig(
    Map<String, dynamic> config,
  ) async {
    return _post(SchedulerApi.updateConfig, body: config);
  }

  Future<Map<String, dynamic>> getFocusModelData() async {
    return await _get(FocusModelApi.getFocusData);
  }

  Future<void> addFocusDataPoint({
    required double temperature,
    required int position,
    double? hfr,
    String? filter,
  }) async {
    await _post(
      FocusModelApi.addFocusPoint,
      body: {
        'temperature': temperature,
        'position': position,
        if (hfr != null) 'hfr': hfr,
        if (filter != null) 'filter': filter,
      },
    );
  }

  Future<void> clearFocusModelData() async {
    await _delete(FocusModelApi.clearFocusData);
  }

  Future<Map<String, dynamic>> getFocusModel() async {
    return await _get(FocusModelApi.getFocusModel);
  }

  /// Predict focus position for temperature
  Future<Map<String, dynamic>> predictFocusPosition({
    required double temperature,
    String? filter,
  }) async {
    return await _get(
      FocusModelApi.predictFocus,
      query: {'temperature': temperature, if (filter != null) 'filter': filter},
    );
  }

  Future<Map<String, dynamic>> getFilterFocusOffsets() async {
    return await _get(FocusModelApi.getFilterOffsets);
  }

  Future<void> setFilterFocusOffsets({
    required String referenceFilter,
    required Map<String, int> offsets,
  }) async {
    await _post(
      FocusModelApi.setFilterOffsets,
      body: {'referenceFilter': referenceFilter, 'offsets': offsets},
    );
  }

  /// Check if refocus needed based on temperature drift
  Future<Map<String, dynamic>> shouldRefocus({
    required double currentTemp,
    required double lastFocusTemp,
    int? maxDriftSteps,
  }) async {
    return await _get(
      FocusModelApi.shouldRefocus,
      query: {
        'currentTemp': currentTemp,
        'lastFocusTemp': lastFocusTemp,
        if (maxDriftSteps != null) 'maxDriftSteps': maxDriftSteps,
      },
    );
  }

  Future<Map<String, dynamic>> exportFocusModel() async {
    return await _get(FocusModelApi.exportFocusData);
  }

  Future<void> importFocusModel(Map<String, dynamic> data) async {
    await _post(FocusModelApi.importFocusData, body: data);
  }

  /// Get the real per-filter predictive-AF config and models used by the host.
  Future<Map<String, dynamic>> getPredictiveAfSettings() async {
    return _get(FocusModelApi.getPredictiveSettings);
  }

  Future<void> updatePredictiveAfConfig(Map<String, dynamic> config) async {
    await _post(FocusModelApi.updatePredictiveConfig, body: config);
  }

  Future<void> clearPredictiveAfSamples(String filterName) async {
    await _post(
      FocusModelApi.clearPredictiveSamples,
      body: {'filter': filterName},
    );
  }

  Future<String?> exportPredictiveAfModel(String filterName) async {
    final response = await _get(
      FocusModelApi.exportPredictiveModel,
      query: {'filter': filterName},
    );
    return response['json'] as String?;
  }

  Future<Map<String, dynamic>> planetariumCatalogSearch(String query) async {
    return await _get(PlanetariumApi.catalogSearch, query: {'query': query});
  }
}

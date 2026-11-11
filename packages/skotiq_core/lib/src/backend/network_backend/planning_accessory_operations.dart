part of '../network_backend.dart';

mixin _NetworkBackendPlanningAccessoryOperations on _NetworkBackendTransport {
  Future<Map<String, dynamic>> awaitJobResultOrLegacy(
    Map<String, dynamic> response, {
    required String operation,
    required Duration timeout,
  });

  Future<void> slewToTarget(double ra, double dec) async {
    await _post('framing/slew-to-target', {'ra': ra, 'dec': dec});
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
    final start = await _post('framing/center-on-target', {
      'ra': ra,
      'dec': dec,
      if (maxIterations != null) 'maxIterations': maxIterations,
      if (toleranceArcsec != null) 'toleranceArcsec': toleranceArcsec,
      if (exposureTime != null) 'exposureTime': exposureTime,
      if (binning != null) 'binning': binning,
      if (gain != null) 'gain': gain,
      if (syncMount != null) 'syncMount': syncMount,
    });
    return awaitJobResultOrLegacy(
      start,
      operation: 'center on target',
      timeout: const Duration(minutes: 10),
    );
  }

  Future<void> syncMountToCoordinates(double ra, double dec) async {
    await _post('framing/sync', {'ra': ra, 'dec': dec});
  }

  Future<Map<String, dynamic>> getCurrentPosition() async {
    final response = await _get('framing/current-position');
    return response;
  }

  Future<void> abortSlew() async {
    await _post('framing/abort-slew');
  }

  /// Push a framing target to the imaging host (Plan Tonight handoff).
  Future<void> framingSetTarget({
    required double ra,
    required double dec,
    required String name,
  }) async {
    await _post('framing/set-target', {'ra': ra, 'dec': dec, 'name': name});
  }

  // The headless endpoints require an explicit deviceId. Keep it on every
  // command/status/capability request so multi-dome hosts and the server's
  // connected-device validation address the same physical device.

  @override
  Future<void> domeOpenShutter(String deviceId) async {
    await _post('dome/open', {'deviceId': deviceId});
  }

  @override
  Future<void> domeCloseShutter(String deviceId) async {
    await _post('dome/close', {'deviceId': deviceId});
  }

  @override
  Future<void> domeSlewToAzimuth(String deviceId, double azimuth) async {
    await _post('dome/slew', {'deviceId': deviceId, 'azimuth': azimuth});
  }

  /// Enable/disable dome-mount sync (slaving)
  @override
  Future<void> domeSetSlaved(String deviceId, bool slaved) async {
    await _post('dome/sync', {'deviceId': deviceId, 'enable': slaved});
  }

  @override
  Future<void> domePark(String deviceId) async {
    await _post('dome/park', {'deviceId': deviceId});
  }

  @override
  Future<void> domeFindHome(String deviceId) async {
    await _post('dome/home', {'deviceId': deviceId});
  }

  @override
  Future<void> domeAbortSlew(String deviceId) async {
    await _post('dome/halt', {'deviceId': deviceId});
  }

  Future<Map<String, dynamic>> getDomeStatus(String deviceId) async {
    return await _get('dome/status', {'deviceId': deviceId});
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
    final json = await _get('dome/capabilities', {'deviceId': deviceId});
    return DomeCapabilities.fromJson(json);
  }

  // Safety monitor

  Future<Map<String, dynamic>> getSafetyStatus({String? deviceId}) async {
    return await _get(
      'safety/status',
      deviceId != null ? {'deviceId': deviceId} : null,
    );
  }

  @override
  Future<HardwareWeatherConditions> getHardwareWeatherConditions(
    String deviceId,
  ) async {
    final json = await _get('weather/current');
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
    return await _get('safety/settings');
  }

  Future<void> updateSafetySettings(Map<String, dynamic> settings) async {
    await _post('safety/settings', settings);
  }

  Future<void> acknowledgeSafetyCondition({
    required String reason,
    int? durationMinutes,
  }) async {
    await _post('safety/acknowledge', {
      'reason': reason,
      if (durationMinutes != null) 'durationMinutes': durationMinutes,
    });
  }

  /// Cancel a previously acknowledged/snoozed unsafe condition on the host.
  Future<void> cancelSafetyAcknowledgement() async {
    await _post('safety/cancel-acknowledgement');
  }

  /// Get switch states.
  ///
  /// Pass [deviceId] to scope to a single device — that returns the
  /// `{switchCount, switches:[...]}` single-device shape the per-channel UI
  /// consumes. Omit it for the all-devices summary
  /// (`{devicesConnected, devices:[...]}`).
  Future<Map<String, dynamic>> getSwitchStatus({String? deviceId}) async {
    return await _get('switch/status', {
      if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
    });
  }

  /// Set a switch value. [deviceId] is required by the server
  /// (`POST /api/switch/set`); [value] is a `bool` for boolean switches or a
  /// `num` for analog ones.
  Future<void> setSwitch({
    required String deviceId,
    required int switchId,
    required dynamic value,
  }) async {
    await _post('switch/set', {
      'deviceId': deviceId,
      'switchId': switchId,
      'value': value,
    });
  }

  Future<Map<String, dynamic>> getCoverStatus(String deviceId) async {
    return await _get('cover/status', {'deviceId': deviceId});
  }

  // The headless endpoints validate the addressed connected device. Preserve
  // [deviceId] on every remote command just as the local FFI backend does.

  @override
  Future<void> coverOpen(String deviceId) async {
    await _post('cover/open', {'deviceId': deviceId});
  }

  @override
  Future<void> coverClose(String deviceId) async {
    await _post('cover/close', {'deviceId': deviceId});
  }

  @override
  Future<void> calibratorOn(String deviceId, int brightness) async {
    await _post('cover/calibrator-on', {
      'deviceId': deviceId,
      'brightness': brightness,
    });
  }

  @override
  Future<void> calibratorOff(String deviceId) async {
    await _post('cover/calibrator-off', {'deviceId': deviceId});
  }

  /// Get the imaging host's complete unattended-scheduler state.
  Future<Map<String, dynamic>> getSchedulerState() async {
    return _get('scheduler/state');
  }

  /// Run a lifecycle command against the imaging host's scheduler engine.
  Future<Map<String, dynamic>> controlScheduler(
    String action, {
    bool confirmWarnings = false,
  }) async {
    return _post('scheduler/control', {
      'action': action,
      if (confirmWarnings) 'confirmWarnings': true,
    });
  }

  /// Persist and apply scheduler scoring configuration on the imaging host.
  Future<Map<String, dynamic>> updateSchedulerConfig(
    Map<String, dynamic> config,
  ) async {
    return _post('scheduler/config', config);
  }

  Future<Map<String, dynamic>> getFocusModelData() async {
    return await _get('focus-model/data');
  }

  Future<void> addFocusDataPoint({
    required double temperature,
    required int position,
    double? hfr,
    String? filter,
  }) async {
    await _post('focus-model/add-point', {
      'temperature': temperature,
      'position': position,
      if (hfr != null) 'hfr': hfr,
      if (filter != null) 'filter': filter,
    });
  }

  Future<void> clearFocusModelData() async {
    await _delete('focus-model/clear');
  }

  Future<Map<String, dynamic>> getFocusModel() async {
    return await _get('focus-model/model');
  }

  /// Predict focus position for temperature
  Future<Map<String, dynamic>> predictFocusPosition({
    required double temperature,
    String? filter,
  }) async {
    return await _get('focus-model/predict', {
      'temperature': temperature,
      if (filter != null) 'filter': filter,
    });
  }

  Future<Map<String, dynamic>> getFilterFocusOffsets() async {
    return await _get('focus-model/filter-offsets');
  }

  Future<void> setFilterFocusOffsets({
    required String referenceFilter,
    required Map<String, int> offsets,
  }) async {
    await _post('focus-model/filter-offsets', {
      'referenceFilter': referenceFilter,
      'offsets': offsets,
    });
  }

  /// Check if refocus needed based on temperature drift
  Future<Map<String, dynamic>> shouldRefocus({
    required double currentTemp,
    required double lastFocusTemp,
    int? maxDriftSteps,
  }) async {
    return await _get('focus-model/should-refocus', {
      'currentTemp': currentTemp,
      'lastFocusTemp': lastFocusTemp,
      if (maxDriftSteps != null) 'maxDriftSteps': maxDriftSteps,
    });
  }

  Future<Map<String, dynamic>> exportFocusModel() async {
    return await _get('focus-model/export');
  }

  Future<void> importFocusModel(Map<String, dynamic> data) async {
    await _post('focus-model/import', data);
  }

  /// Get the real per-filter predictive-AF config and models used by the host.
  Future<Map<String, dynamic>> getPredictiveAfSettings() async {
    return _get('focus-model/predictive');
  }

  Future<void> updatePredictiveAfConfig(Map<String, dynamic> config) async {
    await _post('focus-model/predictive/config', config);
  }

  Future<void> clearPredictiveAfSamples(String filterName) async {
    await _post('focus-model/predictive/clear-samples', {'filter': filterName});
  }

  Future<String?> exportPredictiveAfModel(String filterName) async {
    final response = await _get('focus-model/predictive/export', {
      'filter': filterName,
    });
    return response['json'] as String?;
  }

  Future<Map<String, dynamic>> planetariumCatalogSearch(String query) async {
    return await _get('planetarium/catalog/search', {'query': query});
  }

}

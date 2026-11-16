part of '../network_backend.dart';

mixin _NetworkBackendPlanningAccessoryOperations on NetworkBackendTransport {
  Future<Map<String, dynamic>> awaitOperationResult(
    Map<String, dynamic> response, {
    required String operation,
    required Duration timeout,
  });

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

  // Safety monitor

  Future<Map<String, dynamic>> getSafetyStatus({String? deviceId}) async {
    return await _get(
      SafetyMonitorApi.safetyStatus,
      query: deviceId != null ? {'deviceId': deviceId} : null,
    );
  }
}

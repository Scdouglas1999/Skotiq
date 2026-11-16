part of '../network_backend.dart';

/// Weather settings and the weather-safety verdict of a linked imaging host.
mixin HostWeather on NetworkBackendTransport {
  Future<Map<String, dynamic>> getWeatherSettings() async {
    final response = await _get(WeatherApi.getSettings);
    return _sessionScienceObject(
      response,
      'settings',
      'GET /api/weather/settings',
    );
  }

  Future<void> updateWeatherSettings(Map<String, dynamic> settings) async {
    await _post(WeatherApi.updateSettings, body: settings);
  }

  Future<Map<String, dynamic>> getSafetyStatus({String? deviceId});

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
}

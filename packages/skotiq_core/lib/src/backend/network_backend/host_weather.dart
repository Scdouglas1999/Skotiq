part of '../network_backend.dart';

/// Weather settings and the weather-safety verdict of a linked imaging host.
final class HostWeather {
  HostWeather(this._host);

  final NetworkBackend _host;

  Future<Map<String, dynamic>> getWeatherSettings() async {
    final response = await _host._get(WeatherApi.getSettings);
    return _host._sessionScienceObject(
      response,
      'settings',
      'GET /api/weather/settings',
    );
  }

  Future<void> updateWeatherSettings(Map<String, dynamic> settings) async {
    await _host._post(WeatherApi.updateSettings, body: settings);
  }

  // Safety monitor

  Future<Map<String, dynamic>> getSafetyStatus({String? deviceId}) async {
    return await _host._get(
      SafetyMonitorApi.safetyStatus,
      query: deviceId != null ? {'deviceId': deviceId} : null,
    );
  }

  Future<void> acknowledgeSafetyCondition({
    required String reason,
    int? durationMinutes,
  }) async {
    await _host._post(
      SafetyMonitorApi.acknowledgeUnsafe,
      body: {
        'reason': reason,
        if (durationMinutes != null) 'durationMinutes': durationMinutes,
      },
    );
  }

  /// Cancel a previously acknowledged/snoozed unsafe condition on the host.
  Future<void> cancelSafetyAcknowledgement() async {
    await _host._post(SafetyMonitorApi.cancelAcknowledgement);
  }
}

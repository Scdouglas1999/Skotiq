/// Weather settings and the weather-safety verdict of a linked imaging host.
abstract interface class HostWeather {
  /// Get weather settings
  Future<Map<String, dynamic>> getWeatherSettings();

  /// Update weather settings
  Future<void> updateWeatherSettings(Map<String, dynamic> settings);

  /// Get safety status
  Future<Map<String, dynamic>> getSafetyStatus({String? deviceId});

  /// Acknowledge unsafe condition
  Future<void> acknowledgeSafetyCondition({
    required String reason,
    int? durationMinutes,
  });

  /// Cancel a previously acknowledged/snoozed unsafe condition on the host.
  Future<void> cancelSafetyAcknowledgement();
}

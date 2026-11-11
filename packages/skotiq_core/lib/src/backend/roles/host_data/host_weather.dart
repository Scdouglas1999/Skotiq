/// Weather settings and the weather-safety verdict of a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostWeather {
  Future<Map<String, dynamic>> getWeatherSettings();

  Future<void> updateWeatherSettings(Map<String, dynamic> settings);

  Future<Map<String, dynamic>> getSafetyStatus({String? deviceId});

  Future<void> acknowledgeSafetyCondition({
    required String reason,
    int? durationMinutes,
  });

  Future<void> cancelSafetyAcknowledgement();
}

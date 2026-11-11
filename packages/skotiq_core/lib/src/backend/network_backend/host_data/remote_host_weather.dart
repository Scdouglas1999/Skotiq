import 'package:skotiq_core/skotiq_core.dart';

/// [HostWeather] on a linked host.
final class RemoteHostWeather implements HostWeather {
  RemoteHostWeather(this._host);

  final NetworkBackend _host;

  @override
  Future<Map<String, dynamic>> getWeatherSettings() =>
      _host.getWeatherSettings();

  @override
  Future<void> updateWeatherSettings(Map<String, dynamic> settings) =>
      _host.updateWeatherSettings(settings);

  @override
  Future<Map<String, dynamic>> getSafetyStatus({String? deviceId}) =>
      _host.getSafetyStatus(deviceId: deviceId);

  @override
  Future<void> acknowledgeSafetyCondition({
    required String reason,
    int? durationMinutes,
  }) => _host.acknowledgeSafetyCondition(
    reason: reason,
    durationMinutes: durationMinutes,
  );

  @override
  Future<void> cancelSafetyAcknowledgement() =>
      _host.cancelSafetyAcknowledgement();
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/equipment/equipment_models.dart';
import '../../equipment/dome_state_provider.dart';
import '../../equipment/safety_monitor_state_provider.dart';
import '../../equipment/weather_state_provider.dart';
import '../runtime_mirror_channel.dart';

typedef EnvironmentReadings = ({
  WeatherState weather,
  DomeState dome,
  SafetyMonitorState safety,
});

final _environmentReadingsProvider = Provider<EnvironmentReadings>(
  (ref) => (
    weather: ref.watch(weatherStateProvider),
    dome: ref.watch(domeStateProvider),
    safety: ref.watch(safetyMonitorStateProvider),
  ),
);

/// Readings of the weather station, dome and safety monitor.
///
/// Only the process that connected a device polls it, so a linked client knows
/// these devices are connected (that travels with the device events) but never
/// sees a reading. The host shares the readings it polls; connection state is
/// left to the device events.
class EnvironmentChannel extends RuntimeMirrorChannel<EnvironmentReadings> {
  const EnvironmentChannel();

  @override
  String get key => 'environment';

  @override
  get source => _environmentReadingsProvider;

  @override
  Duration get minInterval => const Duration(seconds: 2);

  bool _connected(DeviceConnectionState state) =>
      state == DeviceConnectionState.connected;

  @override
  Map<String, dynamic>? encode(EnvironmentReadings value) {
    final w = value.weather;
    final d = value.dome;
    final s = value.safety;
    return {
      if (_connected(w.connectionState))
        'weather': {
          'deviceId': w.deviceId,
          'temperature': finiteOrNull(w.temperature),
          'humidity': finiteOrNull(w.humidity),
          'pressure': finiteOrNull(w.pressure),
          'cloudCover': finiteOrNull(w.cloudCover),
          'dewPoint': finiteOrNull(w.dewPoint),
          'windSpeed': finiteOrNull(w.windSpeed),
          'windDirection': finiteOrNull(w.windDirection),
          'skyQuality': finiteOrNull(w.skyQuality),
          'skyTemperature': finiteOrNull(w.skyTemperature),
          'rainRate': finiteOrNull(w.rainRate),
        },
      if (_connected(d.connectionState))
        'dome': {
          'deviceId': d.deviceId,
          'azimuth': finiteOrNull(d.azimuth),
          'shutter': d.shutterStatus.name,
          'slewing': d.isSlewing,
          'parked': d.isParked,
          'atHome': d.isAtHome,
          'slaved': d.isSlaved,
        },
      if (_connected(s.connectionState))
        'safety': {'deviceId': s.deviceId, 'safe': s.isSafe},
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null) return;
    // A reading lands only on the card of the device it was read from; the
    // card's connection state comes from the device events.
    bool sameDevice(Object? id, String? current) =>
        id is String && current != null && id == current;

    final weather = value['weather'];
    final weatherNotifier = context.read(weatherStateProvider.notifier);
    if (weather is Map &&
        sameDevice(weather['deviceId'], weatherNotifier.deviceId)) {
      weatherNotifier.updateConditions(
        temperature: jsonDouble(weather['temperature']),
        humidity: jsonDouble(weather['humidity']),
        pressure: jsonDouble(weather['pressure']),
        cloudCover: jsonDouble(weather['cloudCover']),
        dewPoint: jsonDouble(weather['dewPoint']),
        windSpeed: jsonDouble(weather['windSpeed']),
        windDirection: jsonDouble(weather['windDirection']),
        skyQuality: jsonDouble(weather['skyQuality']),
        skyTemperature: jsonDouble(weather['skyTemperature']),
        rainRate: jsonDouble(weather['rainRate']),
      );
    }

    final dome = value['dome'];
    final domeNotifier = context.read(domeStateProvider.notifier);
    if (dome is Map && sameDevice(dome['deviceId'], domeNotifier.deviceId)) {
      domeNotifier.applyStatus(
        azimuth: jsonDouble(dome['azimuth']),
        shutterStatus: ShutterStatus.values.firstWhere(
          (s) => s.name == dome['shutter'],
          orElse: () => ShutterStatus.unknown,
        ),
        isSlewing: dome['slewing'] == true,
        isAtHome: dome['atHome'] == true,
        isParked: dome['parked'] == true,
        isSlaved: dome['slaved'] == true,
      );
    }

    final safety = value['safety'];
    final safetyNotifier = context.read(safetyMonitorStateProvider.notifier);
    if (safety is Map &&
        sameDevice(safety['deviceId'], safetyNotifier.deviceId) &&
        safety['safe'] is bool) {
      safetyNotifier.updateSafetyStatus(safety['safe'] as bool);
    }
  }
}

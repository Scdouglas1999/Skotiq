import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart'
    show PluginHostEvents, pluginHostProvider;

import 'equipment/focuser_state_provider.dart';
import 'equipment/weather_state_provider.dart';

/// Publishes the app's readings to the plugins that listen for them, for as
/// long as something listens to this provider:
///
/// * `weather.updated` on each new weather-station reading, with the figures
///   the station gave (temperature, humidity, pressure, cloud cover, dew
///   point, wind speed and direction, sky quality and temperature, rain
///   rate, all in the units the weather state holds);
/// * `focuser.moved` when the focuser reports a new position, with that
///   position and the focuser's temperature when it has one.
final pluginHostEventsProvider = Provider<void>((ref) {
  ref.listen(weatherStateProvider, (previous, next) {
    final sampledAt = next.lastUpdated;
    if (sampledAt == null || sampledAt == previous?.lastUpdated) return;
    ref
        .read(pluginHostProvider)
        .publishHostEvent(PluginHostEvents.weatherUpdated, {
          'temperature': ?next.temperature,
          'humidity': ?next.humidity,
          'pressure': ?next.pressure,
          'cloud_cover': ?next.cloudCover,
          'dew_point': ?next.dewPoint,
          'wind_speed': ?next.windSpeed,
          'wind_direction': ?next.windDirection,
          'sky_quality': ?next.skyQuality,
          'sky_temperature': ?next.skyTemperature,
          'rain_rate': ?next.rainRate,
          'sampled_at': sampledAt.toUtc().toIso8601String(),
        });
  });
  ref.listen(focuserStateProvider, (previous, next) {
    final position = next.position;
    if (position == null || position == previous?.position) return;
    ref.read(pluginHostProvider).publishHostEvent(
      PluginHostEvents.focuserMoved,
      {'position': position, 'temperature': ?next.temperature},
    );
  });
});

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Weather state provider
final weatherStateProvider =
    StateNotifierProvider<WeatherStateNotifier, WeatherState>((ref) {
      return WeatherStateNotifier(ref);
    });

class WeatherStateNotifier extends DeviceSlotNotifier<WeatherState> {
  WeatherStateNotifier(Ref ref)
    : super(ref, DeviceType.weather, const WeatherState());

  void updateConditions({
    double? temperature,
    double? humidity,
    double? pressure,
    double? cloudCover,
    double? dewPoint,
    double? windSpeed,
    double? windDirection,
    double? skyQuality,
    double? skyTemperature,
    double? rainRate,
  }) {
    state = state.copyWith(
      temperature: temperature,
      humidity: humidity,
      pressure: pressure,
      cloudCover: cloudCover,
      dewPoint: dewPoint,
      windSpeed: windSpeed,
      windDirection: windDirection,
      skyQuality: skyQuality,
      skyTemperature: skyTemperature,
      rainRate: rainRate,
      lastUpdated: DateTime.now(),
    );
  }
}

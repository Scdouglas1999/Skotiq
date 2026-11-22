import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/weather/weather_safety_state.dart';
import '../../weather_safety_provider.dart';
import '../runtime_mirror_channel.dart';

/// The imaging host's weather-safety verdict, which the conditions card, the
/// safety banner and the run's weather hold read.
///
/// Host to client only, and display only: a client never parks or pauses on
/// it; the host acts on its own verdict. The client's ten-second poll of
/// `GET /api/safety/status` stays beside it: it reads the host when the
/// client's safety state is first shown, and marks the verdict unavailable
/// when the host cannot be read. A client that shows no safety state yet
/// takes nothing from the channel.
class WeatherSafetyChannel extends RuntimeMirrorChannel<WeatherSafetyState> {
  const WeatherSafetyChannel();

  @override
  String get key => 'weatherSafety';

  @override
  get source => weatherSafetyProvider;

  @override
  Duration get minInterval => const Duration(seconds: 1);

  /// A failed poll can mark the verdict unavailable while the host's value
  /// has not changed; the re-read after a reconnect then shows it again.
  @override
  bool get reappliesOnReread => true;

  /// Reading the verdict must not start the safety poll of a client that
  /// shows none.
  @override
  WeatherSafetyState readSource(ProviderContainer container) =>
      container.exists(weatherSafetyProvider)
      ? container.read(weatherSafetyProvider)
      : WeatherSafetyState.initial();

  @override
  Map<String, dynamic> encode(WeatherSafetyState value) => value.toJson();

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null ||
        context.networkBackend == null ||
        !context.container.exists(weatherSafetyProvider)) {
      return;
    }
    context
        .read(weatherSafetyProvider.notifier)
        .applyHostVerdict(WeatherSafetyState.fromJson(value));
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../host_forecast_cloud_cover.dart';
import '../../weather_providers.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';
import 'environment_channel.dart';

/// The environment channel plus the host's forecast cloud cover.
///
/// The forecast is not the weather device's cloud cover. It is read from
/// the host's [cloudCoverPercentageProvider] when encoding, and written to
/// [hostForecastCloudCoverProvider] when applying, so the client's copy of
/// [cloudCoverPercentageProvider] does not feed this channel.
class EnvironmentForecastChannel extends EnvironmentChannel {
  const EnvironmentForecastChannel();

  @override
  Iterable<ProviderListenable<Object?>> get alsoEncodes => [
    ...super.alsoEncodes,
    cloudCoverPercentageProvider,
  ];

  @override
  Map<String, dynamic>? encodeCurrent(ProviderContainer container) {
    final encoded = super.encodeCurrent(container);
    if (encoded == null) return null;
    final forecast = container.read(cloudCoverPercentageProvider).valueOrNull;
    return {
      ...encoded,
      'forecastCloudCover': finiteOrNull(forecast),
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    super.apply(context, value);
    if (value == null || !value.containsKey('forecastCloudCover')) return;
    context.read(hostForecastCloudCoverProvider.notifier).state = jsonDouble(
      value['forecastCloudCover'],
    );
  }
}

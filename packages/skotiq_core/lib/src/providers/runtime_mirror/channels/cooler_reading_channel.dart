import '../../imaging_provider.dart'
    show TemperaturePoint, temperatureHistoryProvider;
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The newest cooler reading of the host's camera poller.
///
/// The poller runs in the process that connected the camera, so a linked
/// client had a cooler card with no history and an empty cooling chart. Each
/// reading the host takes (every 5 s while cooling, every 30 s otherwise) is
/// sent as one point, and the client adds it to its own history with the
/// host's reading time. The history from before the client connected is not
/// sent.
class CoolerReadingChannel
    extends RuntimeMirrorChannel<List<TemperaturePoint>> {
  const CoolerReadingChannel();

  @override
  String get key => 'coolerReading';

  @override
  get source => temperatureHistoryProvider;

  @override
  Map<String, dynamic>? encode(List<TemperaturePoint> value) {
    if (value.isEmpty) return null;
    final point = value.last;
    final temperature = finiteOrNull(point.temperature);
    if (temperature == null) return null;
    return {
      'at': point.time.toUtc().millisecondsSinceEpoch,
      'temperature': temperature,
      'target': finiteOrNull(point.targetTemp),
      'power': finiteOrNull(point.coolerPower),
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null) return;
    final at = jsonInstant(value['at']);
    final temperature = jsonDouble(value['temperature']);
    if (at == null || temperature == null) return;
    final history = context.read(temperatureHistoryProvider);
    if (history.isNotEmpty && !at.isAfter(history.last.time)) return;
    context
        .read(temperatureHistoryProvider.notifier)
        .addPoint(
          temperature,
          targetTemp: jsonDouble(value['target']),
          coolerPower: jsonDouble(value['power']),
          at: at.toLocal(),
        );
  }
}

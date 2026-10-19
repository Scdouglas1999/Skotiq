// Number formatting and small statistics shared by the session providers.
//
// The values here become the strings in a MetricVm or a NightText.literal,
// so they follow the boards: a true minus sign, grouped focuser steps
// ("45 484"), degrees with "°C". Unknown input returns null, never "0".

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// The session providers' "now". Tests pin it; the app reads the shared
/// 30-second ticker so elapsed times and the dawn row stay current.
final nightSessionNowProvider = Provider<DateTime>((ref) {
  return ref.watch(tickerProvider(TickerCadence.thirtySeconds)).valueOrNull ??
      DateTime.now();
});

const String _minus = '−';
const String _groupSeparator = ' ';

/// [value] with [decimals] places and a true minus sign.
String nightFixed(double value, int decimals) {
  final text = value.toStringAsFixed(decimals);
  return text.startsWith('-') ? '$_minus${text.substring(1)}' : text;
}

/// `45 484`: thousands grouped with a no-break space.
String nightGrouped(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? _minus : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(_groupSeparator);
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// `+0.02`, `−0.04`; a delta that rounds to zero carries no sign.
String nightSignedDelta(double delta, int decimals) {
  final text = delta.abs().toStringAsFixed(decimals);
  if (double.parse(text) == 0) return text;
  return delta > 0 ? '+$text' : '$_minus$text';
}

/// `−10.0 °C`.
String nightCelsius(double value) => '${nightFixed(value, 1)} °C';

/// `639 GB`, `2.6 GB`, `512 MB`.
String nightBytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= 100 * gb) return '${(bytes / gb).round()} GB';
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).round()} MB';
}

/// `4h 12m`; null for no time at all.
String? nightDuration(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  return DurationFormat.seconds(seconds, style: DurationStyle.compactTrimmed);
}

/// The fewest values a night median is taken over. One or two frames make a
/// "median" that is just the frame being compared, so the delta says nothing.
const int kNightMedianMinSamples = 3;

/// The median of [values], or null with fewer than [kNightMedianMinSamples].
double? nightMedian(Iterable<double?> values) {
  final sorted = <double>[
    for (final v in values)
      if (v != null && v.isFinite) v,
  ]..sort();
  if (sorted.length < kNightMedianMinSamples) return null;
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Wall-clock `HH:mm` for an instant, in the app's configured time zone.
String nightClockTime(Clock clock, DateTime instant) {
  final wall = clock.fromUtc(instant.toUtc());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(wall.hour)}:${two(wall.minute)}';
}

/// Whether [state] is an explicit, live connection.
bool nightConnected(DeviceConnectionState state) =>
    state == DeviceConnectionState.connected;

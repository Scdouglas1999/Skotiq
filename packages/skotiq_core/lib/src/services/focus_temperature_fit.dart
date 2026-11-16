/// One autofocus result, as the temperature fit reads it.
typedef FocusSample = ({
  double temperatureCelsius,
  int focusPosition,
  double hfr,
});

/// The line best focus follows with temperature.
class FocusTemperatureLine {
  /// Steps per degree Celsius.
  final double slope;

  /// The line passes through the mean of the fitted points.
  final double meanTemperatureCelsius;
  final double meanPosition;
  final double rSquared;

  /// How many points the line was fitted through.
  final int points;

  const FocusTemperatureLine({
    required this.slope,
    required this.meanTemperatureCelsius,
    required this.meanPosition,
    required this.rSquared,
    required this.points,
  });

  /// The position at 0 °C.
  double get intercept => meanPosition - slope * meanTemperatureCelsius;
}

/// Least squares through the sharpest autofocus (lowest HFR) of each 1 °C
/// band of [samples]; null with fewer than three bands or no spread of
/// temperature.
FocusTemperatureLine? fitFocusTemperatureLine(Iterable<FocusSample> samples) {
  final sharpest = <int, FocusSample>{};
  for (final s in samples) {
    final band = s.temperatureCelsius.round();
    final best = sharpest[band];
    if (best == null || s.hfr < best.hfr) sharpest[band] = s;
  }
  final points = sharpest.values.toList(growable: false);
  final n = points.length;
  if (n < 3) return null;

  var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0;
  for (final p in points) {
    final x = p.temperatureCelsius;
    final y = p.focusPosition.toDouble();
    sumX += x;
    sumY += y;
    sumXY += x * y;
    sumX2 += x * x;
  }
  final denominator = n * sumX2 - sumX * sumX;
  if (denominator.abs() < 1e-10) return null;

  final slope = (n * sumXY - sumX * sumY) / denominator;
  final meanX = sumX / n;
  final meanY = sumY / n;
  var ssTot = 0.0, ssRes = 0.0;
  for (final p in points) {
    final predicted = meanY + slope * (p.temperatureCelsius - meanX);
    ssTot += (p.focusPosition - meanY) * (p.focusPosition - meanY);
    ssRes += (p.focusPosition - predicted) * (p.focusPosition - predicted);
  }
  return FocusTemperatureLine(
    slope: slope,
    meanTemperatureCelsius: meanX,
    meanPosition: meanY,
    rSquared: ssTot > 0 ? (1.0 - ssRes / ssTot).clamp(0.0, 1.0) : 0.0,
    points: n,
  );
}

import 'dart:math' as math;

/// A "nice" axis: ticks on human-readable multiples, with the axis bounds
/// snapped to those same ticks.
///
/// fl_chart labels the interval ticks AND both axis boundaries. With bounds set
/// to data +/- some percentage and ticks placed independently, the boundary
/// label lands a fraction of a tick away from the outermost tick and the two
/// draw on top of each other — observed live as "2.83" over "2.75" on an HFR
/// axis and "101.0" over "100.0" on a transparency axis. Snapping the bounds to
/// tick multiples makes the boundary labels BE ticks, so nothing overlaps.
class NiceAxis {
  final double min;
  final double max;
  final double interval;
  final int decimals;

  const NiceAxis({
    required this.min,
    required this.max,
    required this.interval,
    required this.decimals,
  });

  factory NiceAxis.forRange(
    double dataMin,
    double dataMax, {
    int targetTicks = 4,
    double padFraction = 0.15,
  }) {
    // A series with no variation still deserves a readable axis rather than an
    // invented one: centre it and use a symmetric window.
    if (!(dataMax - dataMin).isFinite || dataMax - dataMin <= 0) {
      final centre = dataMin.isFinite ? dataMin : 0.0;
      final pad = centre.abs() > 1 ? centre.abs() * 0.01 : 0.5;
      final interval = niceStep(2 * pad / targetTicks);
      // The window has to be snapped to tick multiples for the same reason the
      // varying branch below snaps: an unsnapped bound is still labelled by
      // fl_chart, and it lands a fraction of a tick from the outermost tick.
      // A flat 0.70 guiding series produced min = 0.70 - 2 x 0.25 = 0.20
      // against ticks at multiples of 0.25, so "0.20" printed on top of "0.25".
      // Snapping the CENTRE (rather than flooring the min and ceiling the max)
      // also keeps the window exactly four intervals wide, so the axis never
      // grows a sixth label the plot has no room for.
      final snappedCentre = (centre / interval).roundToDouble() * interval;
      return NiceAxis(
        min: snappedCentre - interval * 2,
        max: snappedCentre + interval * 2,
        interval: interval,
        decimals: decimalsFor(interval),
      );
    }

    final padded = (dataMax - dataMin) * (1 + padFraction);
    final interval = niceStep(padded / targetTicks);
    final min = (dataMin / interval).floorToDouble() * interval;
    final max = (dataMax / interval).ceilToDouble() * interval;
    return NiceAxis(
      min: min,
      // Guard against min == max after snapping (all values on one tick).
      max: max > min ? max : min + interval,
      interval: interval,
      decimals: decimalsFor(interval),
    );
  }

  /// Round a step up to the nearest 1, 2, 2.5 or 5 times a power of ten.
  static double niceStep(double raw) {
    if (!raw.isFinite || raw <= 0) return 1.0;
    final exponent = (math.log(raw) / math.ln10).floor();
    final magnitude = math.pow(10, exponent).toDouble();
    final normalised = raw / magnitude;
    final double step;
    if (normalised <= 1.0) {
      step = 1.0;
    } else if (normalised <= 2.0) {
      step = 2.0;
    } else if (normalised <= 2.5) {
      step = 2.5;
    } else if (normalised <= 5.0) {
      step = 5.0;
    } else {
      step = 10.0;
    }
    return step * magnitude;
  }

  static int decimalsFor(double interval) {
    if (interval >= 10) return 0;
    if (interval >= 1) return 1;
    if (interval >= 0.1) return 2;
    if (interval >= 0.01) return 3;
    return 4;
  }

  String label(double value) {
    // -0.00 is a rounding artefact, never a measurement.
    final rounded = double.parse(value.toStringAsFixed(decimals));
    return (rounded == 0 ? 0.0 : rounded).toStringAsFixed(decimals);
  }
}

/// Elapsed-time label for a time axis measured in seconds from the first
/// sample. Chooses the unit from the magnitude so a 90-second run does not read
/// "1m" and a five-hour one does not read "300m".
String elapsedAxisLabel(double seconds) {
  final total = seconds.round();
  if (total < 90) return '${total}s';
  final minutes = total ~/ 60;
  if (minutes < 90) return '${minutes}m';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0 ? '${hours}h' : '${hours}h${remainder}m';
}

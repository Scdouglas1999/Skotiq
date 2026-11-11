/// Tick and range math for every chart: which values an axis labels, how many
/// decimals show them exactly, and where a range snaps so its ends are ticks.
library;

import 'dart:math' as math;

/// The values an axis labels and the precision that shows them exactly.
class ChartTicks {
  const ChartTicks(this.values, this.decimals);

  final List<double> values;

  /// Decimals that print every value in [values] without rounding (at most 4).
  final int decimals;

  /// The gap between neighboring ticks, or 0 with fewer than two.
  double get step => values.length < 2 ? 0 : values[1] - values[0];

  /// [value] as this axis prints it. `-0.00` is a rounding artifact, never a
  /// measurement, so it prints as zero.
  String label(double value) => _fixed(value, decimals);

  /// [value] read off this axis: a measured value (a median, the point under
  /// the pointer) to a finer place than the ticks, so a 2.02 px median on an
  /// axis ticked every 0.5 px does not read "2.0".
  String reading(double value) {
    final s = step.abs();
    final digits = s == 0 || s >= 10
        ? decimals
        : s >= 1
        ? 1
        : s >= 0.1
        ? 2
        : s >= 0.01
        ? 3
        : 4;
    return _fixed(value, digits < decimals ? decimals : digits);
  }

  static String _fixed(double value, int digits) {
    final text = value.toStringAsFixed(digits);
    return double.parse(text) == 0 ? 0.toStringAsFixed(digits) : text;
  }
}

/// A value range whose ends are ticks.
class ChartRange {
  const ChartRange(this.min, this.max, this.ticks);

  final double min;
  final double max;
  final ChartTicks ticks;

  double get span => max - min;
}

abstract final class ChartScale {
  /// [raw] rounded up to 1, 2, 2.5 or 5 times a power of ten.
  static double niceStep(double raw) {
    if (!raw.isFinite || raw <= 0) return 1;
    final magnitude = math
        .pow(10, (math.log(raw) / math.ln10).floor())
        .toDouble();
    final normalized = raw / magnitude;
    for (final mantissa in const <double>[1, 2, 2.5, 5]) {
      if (normalized <= mantissa * (1 + 1e-9)) return mantissa * magnitude;
    }
    return 10 * magnitude;
  }

  /// Decimals that show a step of [step] exactly (at most 4).
  static int decimalsFor(double step) {
    if (!step.isFinite || step <= 0) return 0;
    for (var d = 0; d < 4; d++) {
      final scaled = step * math.pow(10, d);
      if ((scaled - scaled.roundToDouble()).abs() <
          1e-6 * scaled.abs() + 1e-9) {
        return d;
      }
    }
    return 4;
  }

  /// Up to [maxTicks] round values inside [lo]..[hi] without changing the
  /// range: the finest round step that fits, thinned to evenly spaced values
  /// with both outer ones kept when even the coarsest step is too many, and
  /// the two ends when no round value lands inside.
  static ChartTicks ticksWithin(double lo, double hi, int maxTicks) {
    if (!(hi > lo) || !lo.isFinite || !hi.isFinite || maxTicks < 1) {
      return ChartTicks(<double>[lo], 1);
    }
    List<double> inside(double step) => <double>[
      for (
        var v = (lo / step - 1e-9).ceil() * step;
        v <= hi + step * 1e-9;
        v += step
      )
        _snap(v, step),
    ];

    final exponent = (math.log(hi - lo) / math.ln10).floor();
    var best = const <double>[];
    var bestStep = 0.0;
    for (var e = exponent; e >= exponent - 3; e--) {
      for (final mantissa in const <double>[5, 2.5, 2, 1]) {
        final step = mantissa * math.pow(10, e).toDouble();
        final ticks = inside(step);
        if (ticks.length <= maxTicks) {
          if (ticks.length > best.length) {
            best = ticks;
            bestStep = step;
          }
          continue;
        }
        if (best.length >= 2) return ChartTicks(best, decimalsFor(bestStep));
        final last = ticks.length - 1;
        return ChartTicks(<double>[
          for (var i = 0; i < maxTicks; i++)
            ticks[(i * last / math.max(1, maxTicks - 1)).round()],
        ], decimalsFor(step));
      }
    }
    if (best.length >= 2) return ChartTicks(best, decimalsFor(bestStep));
    return ChartTicks(<double>[lo, hi], 2);
  }

  /// A range around [dataMin]..[dataMax] snapped outward to round ticks, about
  /// [targetTicks] of them.
  ///
  /// Snapping the ends is what keeps the end labels from landing a fraction of
  /// a tick from their neighbors ("2.83" drawn over "2.75"). A flat series
  /// gets a window centered on its value, four steps wide.
  static ChartRange niceRange(
    double dataMin,
    double dataMax, {
    int targetTicks = 4,
    double padFraction = 0.15,
    bool includeZero = false,
  }) {
    var lo = dataMin;
    var hi = dataMax;
    if (includeZero) {
      lo = math.min(lo, 0);
      hi = math.max(hi, 0);
    }
    if (!(hi - lo).isFinite || hi - lo <= 0) {
      final center = lo.isFinite ? lo : 0.0;
      final pad = center.abs() > 1 ? center.abs() * 0.01 : 0.5;
      final step = niceStep(2 * pad / targetTicks);
      final snapped = (center / step).roundToDouble() * step;
      return _range(snapped - step * 2, snapped + step * 2, step);
    }
    final step = niceStep((hi - lo) * (1 + padFraction) / targetTicks);
    final min = (lo / step + 1e-9).floorToDouble() * step;
    final max = (hi / step - 1e-9).ceilToDouble() * step;
    return _range(min, max > min ? max : min + step, step);
  }

  static ChartRange _range(double min, double max, double step) {
    final count = ((max - min) / step).round();
    return ChartRange(
      _snap(min, step),
      _snap(max, step),
      ChartTicks(<double>[
        for (var i = 0; i <= count; i++) _snap(min + i * step, step),
      ], decimalsFor(step)),
    );
  }

  /// Snap away float noise such as 0.30000000000000004 and -0.0.
  static double _snap(double v, double step) {
    final snapped = (v / step).round() * step;
    final fixed = double.parse(snapped.toStringAsFixed(decimalsFor(step) + 2));
    return fixed == 0 ? 0 : fixed;
  }

  /// Values at 1, 2 and 5 times each power of ten inside [lo]..[hi], for an
  /// axis drawn on a logarithmic scale; thinned to the powers of ten when
  /// there are more than [maxTicks]. A range that holds none gets its ends.
  static List<double> logTicks(double lo, double hi, {int maxTicks = 6}) {
    if (!(lo > 0) || !(hi > lo)) return <double>[lo];
    List<double> at(List<double> mantissas) => <double>[
      for (
        var e = (math.log(lo) / math.ln10).floor();
        e <= (math.log(hi) / math.ln10).ceil();
        e++
      )
        for (final m in mantissas)
          if (m * math.pow(10, e) >= lo * (1 - 1e-9) &&
              m * math.pow(10, e) <= hi * (1 + 1e-9))
            double.parse((m * math.pow(10, e)).toStringAsPrecision(6)),
    ];
    for (final mantissas in const <List<double>>[
      <double>[1, 2, 5],
      <double>[1, 3],
      <double>[1],
    ]) {
      final ticks = at(mantissas);
      if (ticks.length >= 2 && ticks.length <= maxTicks) return ticks;
    }
    final decades = at(const <double>[1]);
    return decades.length >= 2 ? decades : <double>[lo, hi];
  }

  static const List<int> _clockSteps = <int>[
    1, 2, 5, 10, 15, 30, 60, 120, 180, 240, 360, 720, 1440, //
  ];

  /// Clock ticks between [from] and [to] on a round minute step counted from
  /// midnight, at most [maxLabels] of them.
  static List<DateTime> clockTicks(DateTime from, DateTime to, int maxLabels) {
    final span = to.difference(from).inMinutes;
    if (span <= 0 || maxLabels <= 0) return const <DateTime>[];
    for (final step in _clockSteps) {
      if (span / step > maxLabels + 1) continue;
      final startOfDay = DateTime(from.year, from.month, from.day);
      final minutesIn = from.difference(startOfDay).inMinutes;
      var t = startOfDay.add(Duration(minutes: (minutesIn ~/ step + 1) * step));
      final ticks = <DateTime>[];
      for (; !t.isAfter(to); t = t.add(Duration(minutes: step))) {
        ticks.add(t);
      }
      if (ticks.length <= maxLabels) return ticks;
    }
    return const <DateTime>[];
  }

  static const List<int> _elapsedSteps = <int>[
    1, 2, 5, 10, 15, 30, //
    60, 120, 300, 600, 900, 1800, //
    3600, 7200, 10800, 21600, 43200, //
    86400, 172800, 604800, 2592000, //
  ];

  /// Ticks for an axis of seconds on a round time step (1 s, 5 s, 1 min,
  /// 15 min, 1 h, 1 day), at most [maxTicks] of them. A span of 7 h 8 min is
  /// labeled every 2 h, not every 1 h 47 min.
  static List<double> elapsedTicks(double lo, double hi, int maxTicks) {
    if (!(hi > lo) || maxTicks < 1) return <double>[lo];
    for (final step in _elapsedSteps) {
      final first = (lo / step - 1e-9).ceil() * step;
      final count = ((hi - first) / step + 1e-9).floor() + 1;
      if (count <= maxTicks) {
        return <double>[
          for (var i = 0; i < count; i++) first + i * step.toDouble(),
        ];
      }
    }
    return <double>[lo, hi];
  }

  /// A number of seconds as an axis label, in the unit its size calls for:
  /// `45s`, `12m`, `1h30m`, `3d`. A negative value keeps its sign.
  static String elapsedLabel(double seconds) {
    final total = seconds.round();
    if (total < 0) return '-${elapsedLabel(-seconds)}';
    if (total < 60) return '${total}s';
    if (total < 3600) {
      final s = total % 60;
      return s == 0
          ? '${total ~/ 60}m'
          : '${total ~/ 60}:${s.toString().padLeft(2, '0')}';
    }
    final minutes = total ~/ 60;
    final hours = minutes ~/ 60;
    if (hours >= 48) return '${(hours / 24).round()}d';
    final rest = minutes % 60;
    return rest == 0 ? '${hours}h' : '${hours}h${rest}m';
  }
}

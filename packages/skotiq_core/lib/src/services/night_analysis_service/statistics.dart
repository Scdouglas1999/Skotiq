part of '../night_analysis_service.dart';

// Numeric helpers (pure)

double? _focuserTempDrift(Iterable<NightSub> subs) {
  final temps = [
    for (final s in subs)
      if (s.focuserTemp != null) s.focuserTemp!,
  ];
  if (temps.length < 4) return null;
  final drift = temps.last - temps.first;
  return drift.abs() >= 1.0 ? drift : null;
}

double? _median(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final n = sorted.length;
  if (n.isOdd) return sorted[n ~/ 2];
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
}

/// Median absolute deviation about [center] — a robust spread estimate.
double? _mad(List<double> values, double? center) {
  if (values.isEmpty || center == null) return null;
  final devs = [for (final v in values) (v - center).abs()];
  return _median(devs);
}

/// Pearson correlation; null when undefined (too few points or zero variance).
double? _pearson(List<double> xs, List<double> ys) {
  final n = math.min(xs.length, ys.length);
  if (n < 3) return null;
  var sx = 0.0, sy = 0.0;
  for (var i = 0; i < n; i++) {
    sx += xs[i];
    sy += ys[i];
  }
  final mx = sx / n, my = sy / n;
  var num = 0.0, dx = 0.0, dy = 0.0;
  for (var i = 0; i < n; i++) {
    final ax = xs[i] - mx, ay = ys[i] - my;
    num += ax * ay;
    dx += ax * ax;
    dy += ay * ay;
  }
  if (dx <= 0 || dy <= 0) return null;
  return num / math.sqrt(dx * dy);
}

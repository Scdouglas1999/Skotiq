
// Small formatters shared by the center column's widgets. Times arrive on
// the operator's clock already (the view models' rule), so these only print.

/// The thumbnail fallback for a frame whose file is not on this machine (a
/// remote viewer): no path, so the tile shows its placeholder.
const String nightNoLocalFile = '';

/// `180 s`, `2.5 s`, `0.25 s`, `2.2 ms`.
String nightExposure(double seconds) {
  if (seconds >= 10 || seconds == seconds.roundToDouble()) {
    return '${seconds.round()} s';
  }
  if (seconds >= 1) return '${seconds.toStringAsFixed(1)} s';
  if (seconds >= 0.1) return '${seconds.toStringAsFixed(2)} s';
  return '${(seconds * 1000).toStringAsFixed(1)} ms';
}

/// `Ha 180 s`, `180 s`, `Ha`; null when neither is known.
String? nightFilterExposure(String? filter, double? exposureSecs) {
  final parts = <String>[
    if (filter != null && filter.isNotEmpty) filter,
    if (exposureSecs != null && exposureSecs > 0) nightExposure(exposureSecs),
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

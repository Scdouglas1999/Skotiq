// Small formatters shared by the center column's widgets. Times arrive on
// the operator's clock already (the view models' rule), so these only print.

/// The thumbnail fallback for a frame whose file is not on this machine (a
/// remote viewer): no path, so the tile shows its placeholder.
const String nightNoLocalFile = '';

String _two(int value) => value.toString().padLeft(2, '0');

/// `23:49`.
String nightClockHm(DateTime at) => '${_two(at.hour)}:${_two(at.minute)}';

/// `23:49:12`.
String nightClockHms(DateTime at) => '${nightClockHm(at)}:${_two(at.second)}';

/// `180 s`, `2.5 s`, `0.01 s`.
String nightExposure(double seconds) {
  if (seconds >= 10 || seconds == seconds.roundToDouble()) {
    return '${seconds.round()} s';
  }
  if (seconds >= 1) return '${seconds.toStringAsFixed(1)} s';
  return '${seconds.toStringAsFixed(2)} s';
}

/// `Ha 180 s`, `180 s`, `Ha`; null when neither is known.
String? nightFilterExposure(String? filter, double? exposureSecs) {
  final parts = <String>[
    if (filter != null && filter.isNotEmpty) filter,
    if (exposureSecs != null && exposureSecs > 0) nightExposure(exposureSecs),
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

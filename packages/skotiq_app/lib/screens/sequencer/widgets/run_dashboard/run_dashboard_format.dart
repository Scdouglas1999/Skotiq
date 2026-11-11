/// Utility formatters shared across run-dashboard panels.
///
/// Kept in one file so all duration / RA / Dec strings on the dashboard look
/// the same.
library;


/// Friendly duration: "2h 12m", "45m", "30s", "—" for nulls.
String formatDuration(Duration? d) {
  if (d == null) return '—';
  if (d.isNegative) return '—';
  final total = d.inSeconds;
  if (total == 0) return '0s';
  if (total >= 3600) {
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    return m > 0 ? '${h}h ${m}m' : '${h}h';
  }
  if (total >= 60) {
    final m = total ~/ 60;
    final s = total % 60;
    return s > 0 && m < 5 ? '${m}m ${s}s' : '${m}m';
  }
  return '${total}s';
}

String formatSeconds(double seconds) {
  return formatDuration(Duration(seconds: seconds.round()));
}


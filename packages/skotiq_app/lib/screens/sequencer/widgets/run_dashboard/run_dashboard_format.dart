/// Utility formatters shared across run-dashboard panels.
///
/// Kept in one file so all duration / RA / Dec strings on the dashboard look
/// the same.
library;

import 'package:skotiq_astro/format.dart';

/// Friendly duration: "2h 12m", "45m", "30s", "—" for nulls.
String formatDuration(Duration? d) => d == null || d.isNegative
    ? '—'
    : DurationFormat.of(d, style: DurationStyle.short);

String formatSeconds(double seconds) {
  return formatDuration(Duration(seconds: seconds.round()));
}

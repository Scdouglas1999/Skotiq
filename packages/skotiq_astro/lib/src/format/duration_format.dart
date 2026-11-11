/// Lengths of time as text: integration, elapsed and remaining times.
///
/// One formatter, so two surfaces cannot disagree about the same run (a dialog
/// that printed whole minutes read "0 minutes" for a 12-second session while
/// the dashboard read "12s").
library;

import 'quantity_format.dart';

/// How much of a duration the text carries.
enum DurationStyle {
  /// Every unit from the largest down: `1h 2m 3s`, `2m 3s`, `3s`. For a
  /// recorded total where the seconds are real.
  exact,

  /// The two largest units, a zero second one dropped: `1h 2m`, `2h`,
  /// `2m 3s`, `2m`, `3s`.
  short,

  /// Hours and minutes only once a minute has passed: `1h 2m`, `2h`, `2m`,
  /// `3s`. For estimates and long totals, where seconds are noise.
  coarse,
}

/// How a fractional-seconds input is reduced to whole seconds.
enum DurationRounding {
  /// Round to nearest, so `59.6` reads `1m` rather than `60s`.
  nearest,

  /// Truncate towards zero, as a caller reading `Duration.inSeconds` does.
  truncate,
}

abstract final class DurationFormat {
  /// Format [value] seconds.
  ///
  /// [rounding] governs only the fractional part of the input. With
  /// [roundToMinute], [DurationStyle.coarse] rounds the leftover seconds into
  /// the minutes instead of dropping them, and a 60th minute carries into the
  /// hours.
  ///
  /// Sub-minute times always show their seconds, so no style can print `0m`
  /// for a run that did capture something. Non-finite, zero and negative
  /// inputs read `0s`.
  static String seconds(
    num value, {
    DurationStyle style = DurationStyle.exact,
    DurationRounding rounding = DurationRounding.nearest,
    bool roundToMinute = false,
  }) {
    final v = value.toDouble();
    if (!v.isFinite || v <= 0) return '0s';
    final total = rounding == DurationRounding.truncate ? v.floor() : v.round();
    if (total <= 0) return '0s';
    return _render(total, style, roundToMinute);
  }

  /// Format a [Duration]. Sub-second precision is truncated.
  static String of(
    Duration d, {
    DurationStyle style = DurationStyle.exact,
    bool roundToMinute = false,
  }) {
    final total = d.inSeconds;
    if (total <= 0) return '0s';
    return _render(total, style, roundToMinute);
  }

  /// Total integration the way imagers quote it: decimal hours from one hour
  /// up (`1.5h`, `12h`, `12.3h`, `140h`), the [DurationStyle.coarse] text below
  /// (`45m`, `30s`).
  static String decimalHours(num seconds) {
    final v = seconds.toDouble();
    if (!v.isFinite || v <= 0) return '0s';
    final hours = v / 3600;
    if (hours < 1)
      return DurationFormat.seconds(v, style: DurationStyle.coarse);
    return '${QuantityFormat.trimmed(hours, maxDecimals: hours < 99.95 ? 1 : 0)}h';
  }

  static String _render(int totalSeconds, DurationStyle style, bool toMinute) {
    var total = totalSeconds;
    if (toMinute && total >= 60 && style == DurationStyle.coarse) {
      total = (total / 60).round() * 60;
    }
    final hours = total ~/ 3600;
    final mins = (total % 3600) ~/ 60;
    final secs = total % 60;
    switch (style) {
      case DurationStyle.exact:
        if (hours > 0) return '${hours}h ${mins}m ${secs}s';
        if (mins > 0) return '${mins}m ${secs}s';
        return '${secs}s';
      case DurationStyle.short:
        if (hours > 0) return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
        if (mins > 0) return secs > 0 ? '${mins}m ${secs}s' : '${mins}m';
        return '${secs}s';
      case DurationStyle.coarse:
        if (hours > 0) return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
        if (mins > 0) return '${mins}m';
        return '${secs}s';
    }
  }
}

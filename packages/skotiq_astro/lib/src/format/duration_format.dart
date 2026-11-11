/// Human-readable integration / elapsed times, in the one shape the app uses.
///
/// One formatter, so two surfaces cannot disagree: a dialog that formats
/// integration as whole minutes reads "0 minutes" for a 12-second session and
/// "2 minutes" for 90 seconds, while the dashboard's last-run card renders the
/// same run as "12s". Reporting real captured photons as "0 minutes" reads as
/// "the run did nothing".
///
/// Four distinct output shapes are in use across the app, so [DurationFormat]
/// is parameterised by [DurationStyle] rather than picking a winner and
/// silently restyling half the surfaces.
///
/// All four styles render seconds below one minute, so "0m" is unreachable: a
/// whole-minutes-only rendering puts "4 planned exposures • 0m" next to a
/// "~20s" estimate for the same node. Above one minute the styles agree with
/// their call sites.
library;

/// Which units a duration string shows, and where it stops.
enum DurationStyle {
  /// `1h 2m 3s` / `2m 3s` / `3s` — units dropped from the left only, so the
  /// string never silently loses precision.
  hms,

  /// `1h 2m` / `2m 3s` / `3s` — hours suppress the seconds field, but a
  /// sub-hour duration still carries its seconds.
  hoursMinutes,

  /// [hoursMinutes] with a zero trailing field dropped: `1h 2m` / `1h` /
  /// `2m 3s` / `2m` / `3s`.
  hoursMinutesTrimmed,

  /// `1h 2m` / `2h 0m` / `2m` / `3s` — the two largest units, seconds only
  /// below one minute. A zero minutes field is kept when hours are present.
  compact,

  /// [compact] with a zero minutes field dropped: `1h 2m` / `2h` / `2m` / `3s`.
  compactTrimmed,
}

/// How a fractional-seconds input is reduced to whole seconds.
enum DurationRounding {
  /// Round to nearest, so `59.6` reads `1m 0s` rather than `60s`.
  nearest,

  /// Truncate towards zero, matching a `Duration`-based caller that read
  /// `inHours` / `inMinutes` / `inSeconds`.
  truncate,
}

/// One duration formatter, parameterised to reproduce every shape the app
/// actually renders.
///
/// The output of every method is a **user-visible contract** pinned by
/// `duration_format_parity_test.dart`; changing a glyph changes screens.
abstract final class DurationFormat {
  /// Format [value] seconds.
  ///
  /// [rounding] governs only the fractional part of the input. [roundToMinute]
  /// applies to [DurationStyle.compact] / [DurationStyle.compactTrimmed], whose
  /// smallest rendered unit above a minute is the minute: with it set, the
  /// leftover seconds round into the minutes field instead of being dropped,
  /// and a minute that rounds up to 60 carries into the hours field (the
  /// retired copies rendered `1h 60m` there).
  ///
  /// Non-finite, zero and negative inputs collapse to `0s` rather than
  /// rendering a nonsense duration.
  static String seconds(
    num value, {
    DurationStyle style = DurationStyle.hms,
    DurationRounding rounding = DurationRounding.nearest,
    bool roundToMinute = false,
  }) {
    final v = value.toDouble();
    if (!v.isFinite || v <= 0) return '0s';
    final total = rounding == DurationRounding.truncate ? v.floor() : v.round();
    if (total <= 0) return '0s';
    return _render(total, style, roundToMinute);
  }

  /// Format a [Duration]. Sub-second precision is truncated, which is what a
  /// caller reading `d.inSeconds` already did.
  static String of(
    Duration d, {
    DurationStyle style = DurationStyle.hms,
    bool roundToMinute = false,
  }) {
    final total = d.inSeconds;
    if (total <= 0) return '0s';
    return _render(total, style, roundToMinute);
  }

  static String _render(int totalSeconds, DurationStyle style, bool toMinute) {
    var total = totalSeconds;
    if (toMinute &&
        total >= 60 &&
        (style == DurationStyle.compact ||
            style == DurationStyle.compactTrimmed)) {
      // Quantize at the minute so a rounded 60th minute carries into hours
      // structurally instead of printing "1h 60m".
      total = (total / 60).round() * 60;
    }
    final hours = total ~/ 3600;
    final mins = (total % 3600) ~/ 60;
    final secs = total % 60;
    switch (style) {
      case DurationStyle.hms:
        if (hours > 0) return '${hours}h ${mins}m ${secs}s';
        if (mins > 0) return '${mins}m ${secs}s';
        return '${secs}s';
      case DurationStyle.hoursMinutes:
        if (hours > 0) return '${hours}h ${mins}m';
        if (mins > 0) return '${mins}m ${secs}s';
        return '${secs}s';
      case DurationStyle.hoursMinutesTrimmed:
        if (hours > 0) return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
        if (mins > 0) return secs > 0 ? '${mins}m ${secs}s' : '${mins}m';
        return '${secs}s';
      case DurationStyle.compact:
        if (hours > 0) return '${hours}h ${mins}m';
        if (mins > 0) return '${mins}m';
        return '${secs}s';
      case DurationStyle.compactTrimmed:
        if (hours > 0) return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
        if (mins > 0) return '${mins}m';
        return '${secs}s';
    }
  }
}

/// Format [seconds] as `1h 2m 3s` / `2m 3s` / `3s`.
///
/// Units are dropped from the left only: once hours are present, minutes and
/// seconds are always shown, so the string never silently loses precision.
/// Negative and non-finite inputs collapse to `0s` rather than rendering a
/// nonsense duration.
String formatIntegrationSeconds(double seconds) =>
    DurationFormat.seconds(seconds, style: DurationStyle.hms);

/// [formatIntegrationSeconds] for a value already expressed in hours.
String formatIntegrationHours(double hours) =>
    formatIntegrationSeconds(hours * 3600);

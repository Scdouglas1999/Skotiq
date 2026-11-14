/// Clock times and calendar dates as text.
///
/// Every function here prints the fields of the [DateTime] it is given and
/// never converts between zones. A caller holding an instant picks the clock
/// first: `.toLocal()` for the device clock, or the site clock
/// (`Clock.fromUtc`) on the surfaces that show observatory time. Converting
/// inside the formatter is how a site in another zone gets shifted twice.
library;

/// [value] as at least two digits (`7` -> `07`).
String pad2(int value) => value.toString().padLeft(2, '0');

const List<String> _monthNames = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
];

const List<String> _weekdayNames = <String>[
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', //
];

abstract final class ClockFormat {
  /// `23:52`.
  static String hm(DateTime t) => '${pad2(t.hour)}:${pad2(t.minute)}';

  /// `23:52:07`.
  static String hms(DateTime t) => '${hm(t)}:${pad2(t.second)}';

  /// `23:52:07.045`, for log lines.
  static String hmsMillis(DateTime t) =>
      '${hms(t)}.${t.millisecond.toString().padLeft(3, '0')}';

  /// `2026-11-10`.
  static String date(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${pad2(t.month)}-${pad2(t.day)}';

  /// `2026-11-10 23:52`.
  static String dateHm(DateTime t) => '${date(t)} ${hm(t)}';

  /// `2026-11-10 23:52:07`.
  static String dateHms(DateTime t) => '${date(t)} ${hms(t)}';

  /// `Nov 10`.
  static String monthDay(DateTime t) => '${_monthNames[t.month - 1]} ${t.day}';

  /// `Nov 10, 2026`.
  static String monthDayYear(DateTime t) => '${monthDay(t)}, ${t.year}';

  /// `Nov 10 23:52`.
  static String monthDayHm(DateTime t) => '${monthDay(t)} ${hm(t)}';

  /// `Nov 10, 2026 23:52`.
  static String monthDayYearHm(DateTime t) => '${monthDayYear(t)} ${hm(t)}';

  /// `Tue, Nov 10`, for a night or a day someone has to find on a calendar.
  static String weekdayMonthDay(DateTime t) =>
      '${_weekdayNames[t.weekday - 1]}, ${monthDay(t)}';

  /// `Tue, Nov 10, 2026`.
  static String weekdayMonthDayYear(DateTime t) =>
      '${weekdayMonthDay(t)}, ${t.year}';

  /// `20261110_235207`, for a file name: sorts by time and has no character
  /// a file system refuses.
  static String fileStamp(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}${pad2(t.month)}${pad2(t.day)}_'
      '${pad2(t.hour)}${pad2(t.minute)}${pad2(t.second)}';

  /// [t] as `23:52` when it falls on the same calendar day as [reference],
  /// else `Nov 10 23:52`.
  static String hmOrMonthDayHm(DateTime t, DateTime reference) =>
      t.year == reference.year &&
          t.month == reference.month &&
          t.day == reference.day
      ? hm(t)
      : monthDayHm(t);

  /// A time of day given as decimal hours (sidereal time, an hour angle folded
  /// onto the clock) as `HH:MM`. Folded into [0, 24) and truncated to the
  /// minute, so 23.9999 h reads `23:59` and never `24:00`.
  static String hoursOfDay(double hours) {
    final minutes = ((hours % 24) * 60).floor() % (24 * 60);
    return minutesOfDay(minutes);
  }

  /// A time of day given as minutes after midnight, as `HH:MM`.
  static String minutesOfDay(int minutes) =>
      '${pad2(minutes ~/ 60)}:${pad2(minutes % 60)}';

  /// A running length as a stopwatch: `0:07`, `12:07`, `1:02:07`. A negative
  /// length reads as zero.
  static String stopwatch(Duration d) {
    final total = d.isNegative ? 0 : d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = pad2(total % 60);
    return h > 0 ? '$h:${pad2(m)}:$s' : '$m:$s';
  }

  /// A running length with every field padded: `00:12:07`.
  static String stopwatchPadded(Duration d) {
    final total = d.isNegative ? 0 : d.inSeconds;
    return '${pad2(total ~/ 3600)}:${pad2((total % 3600) ~/ 60)}:'
        '${pad2(total % 60)}';
  }
}

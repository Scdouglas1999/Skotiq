/// The date that names an observing night at a site: the night of D runs from
/// the site's mean solar noon on D to its solar noon on D + 1.
///
/// A night is named by a date, never by an instant. An instant past local
/// midnight belongs to the night of the day before, so the night APIs
/// (`AstronomyCalculations.nightStartOf`, `nightMiddleOf`,
/// `calculateTwilightTimes`, `calculateObjectVisibility`) take this value
/// rather than a `DateTime`. Get one from an instant with
/// `AstronomyCalculations.nightDateOf`; [NightDate.ofCalendarDay] names the
/// night by a calendar day the caller already holds.
class NightDate {
  const NightDate(this.year, this.month, this.day);

  /// The night that opens on the calendar day of [date]: only its year,
  /// month and day are read. A timestamp past midnight names the NEXT night.
  NightDate.ofCalendarDay(DateTime date)
    : this(date.year, date.month, date.day);

  final int year;
  final int month;
  final int day;

  /// The calendar day as local midnight.
  DateTime get calendarDay => DateTime(year, month, day);

  /// The night [days] after this one (before it when negative).
  NightDate addDays(int days) {
    final shifted = DateTime.utc(year, month, day + days);
    return NightDate(shifted.year, shifted.month, shifted.day);
  }

  @override
  bool operator ==(Object other) =>
      other is NightDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  /// The date as `YYYY-MM-DD`.
  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

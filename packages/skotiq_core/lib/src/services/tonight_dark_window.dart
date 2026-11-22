import 'package:skotiq_astro/skotiq_astro.dart'
    show AstronomyCalculations, NoDarkWindow;

/// What the planners say when the Sun does not set at the site tonight
/// (midnight sun): there is no dark window to plan or rank targets in.
const String midnightSunNotice =
    'The Sun does not set at this location tonight, so there are no targets '
    'to suggest.';

/// Whether the Sun stays up all night at the site tonight (midnight sun):
/// no twilight boundary is crossed and the Sun is not below the horizon all
/// day.
bool sunStaysUpTonight({
  required DateTime now,
  required double latitudeDeg,
  required double longitudeDeg,
}) => switch (AstronomyCalculations.darkWindow(
  now: now,
  latitudeDeg: latitudeDeg,
  longitudeDeg: longitudeDeg,
)) {
  NoDarkWindow(polarNight: false) => true,
  _ => false,
};

/// The window every planner takes in polar night, when the Sun crosses no
/// boundary and stays below the horizon: 21:00 local on [now]'s day, for
/// eight hours.
({DateTime start, DateTime end}) polarNightClockWindow(DateTime now) {
  final local = now.toLocal();
  final start = DateTime(local.year, local.month, local.day, 21);
  return (start: start, end: start.add(const Duration(hours: 8)));
}

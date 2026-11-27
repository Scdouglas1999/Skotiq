import 'package:skotiq_astro/skotiq_astro.dart'
    show AstronomyCalculations, NightDarkWindow, NoDarkWindow, TwilightTimes;

/// What the planners say when the Sun does not set at the site tonight
/// (midnight sun): there is no dark window to plan or rank targets in.
const String midnightSunNotice =
    'The Sun does not set at this location tonight, so there are no targets '
    'to suggest.';

/// Tonight's window as every planner takes it: the dark window
/// ([AstronomyCalculations.darkWindow]); in polar night, when the Sun stays
/// below the horizon, [polarNightClockWindow] ([polarNight] true); null under
/// midnight sun, when there is none.
({DateTime start, DateTime end, bool polarNight, TwilightTimes twilight})?
planningNight({
  required DateTime now,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final window = AstronomyCalculations.darkWindow(
    now: now,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );
  switch (window) {
    case NightDarkWindow(:final start, :final end):
      return (
        start: start,
        end: end,
        polarNight: false,
        twilight: window.twilight,
      );
    case NoDarkWindow(polarNight: true):
      final clock = polarNightClockWindow(now);
      return (
        start: clock.start,
        end: clock.end,
        polarNight: true,
        twilight: window.twilight,
      );
    case NoDarkWindow(polarNight: false):
      return null;
  }
}

/// Whether the Sun stays up all night at the site tonight (midnight sun):
/// no twilight boundary is crossed and the Sun is not below the horizon all
/// day.
bool sunStaysUpTonight({
  required DateTime now,
  required double latitudeDeg,
  required double longitudeDeg,
}) =>
    planningNight(
      now: now,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    ) ==
    null;

/// The window every planner takes in polar night, when the Sun crosses no
/// boundary and stays below the horizon: 21:00 local on [now]'s day, for
/// eight hours.
({DateTime start, DateTime end}) polarNightClockWindow(DateTime now) {
  final local = now.toLocal();
  final start = DateTime(local.year, local.month, local.day, 21);
  return (start: start, end: start.add(const Duration(hours: 8)));
}

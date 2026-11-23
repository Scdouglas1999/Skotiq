import 'package:skotiq_astro/skotiq_astro.dart';

/// The next [dawn] after [now] at a site: this night's while it is still
/// ahead, otherwise the next night's. Null when neither night has one (a
/// polar summer has no nautical dawn).
DateTime? nextDawn(
  DateTime now, {
  required double latitudeDeg,
  required double longitudeDeg,
  required DateTime? Function(TwilightTimes twilight) dawn,
}) {
  DateTime? dawnOf(NightDate night) => dawn(
        AstronomyCalculations.calculateTwilightTimes(
          date: night,
          latitudeDeg: latitudeDeg,
          longitudeDeg: longitudeDeg,
        ),
      );

  final tonight = dawnOf(NightDate.ofCalendarDay(now));
  if (tonight != null && !tonight.isBefore(now)) return tonight;
  return dawnOf(NightDate.ofCalendarDay(now.add(const Duration(days: 1))));
}

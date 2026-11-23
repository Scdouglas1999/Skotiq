import 'package:skotiq_astro/skotiq_astro.dart';

/// The next [dawn] after [now] at a site: the dawn of the site's night that
/// holds [now] while it is still ahead, otherwise the next night's. Null when neither night has one (a
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

  final night = AstronomyCalculations.nightDateOf(
    now,
    longitudeDeg: longitudeDeg,
  );
  final tonight = dawnOf(night);
  if (tonight != null && !tonight.isBefore(now)) return tonight;
  return dawnOf(night.addDays(1));
}

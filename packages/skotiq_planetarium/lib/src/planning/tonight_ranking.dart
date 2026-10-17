import 'dart:math' as math;

import '../astronomy/astronomy_calculations.dart';
import '../celestial_object.dart';
import '../coordinate_system.dart';
import 'target_scoring.dart';

/// Altitude floor a target has to clear to count as usable, degrees.
const double kTonightMinAltitudeDeg = 30;

/// How many ranked targets [rankTonightTargets] keeps.
const int kTonightRankingLimit = 20;

/// Share of the ranking key taken by tonight's OBSERVING CONDITIONS, i.e. the
/// app's own [TargetScoringService] night score.
const double kTonightConditionsWeight = 0.7;

/// Share of the ranking key taken by how well the object suits the rig
/// (catalog brightness, apparent size against the active FOV, object type).
///
/// This axis is NOT part of [TargetScoringService], so the ranking here is
/// deliberately not identical to the planner's ordering. Anything shown to an
/// operator has to say so — see [kTonightRankingTooltip].
const double kTonightCatalogFitWeight = 1 - kTonightConditionsWeight;

/// The rule "Best Targets Tonight" is actually ranked by, in operator words.
///
/// Kept next to the weights it describes, and derived from them, because the
/// first version of this panel told the user it used "the same score the
/// planner uses" while a third of the key was a catalog-fit term the planner
/// has never heard of — so the row at the top could have FEWER usable dark
/// hours than the row under it, on a card whose own headline number is those
/// hours.
final String kTonightRankingTooltip =
    'Ranked ${(kTonightConditionsWeight * 100).round()}% on tonight’s '
    'conditions (usable hours above ${kTonightMinAltitudeDeg.round()}° '
    'in darkness, peak altitude, moon separation, transit timing, airmass) '
    'and ${(kTonightCatalogFitWeight * 100).round()}% on how well the object '
    'suits your rig (brightness, size against the current field of view, '
    'type). Objects that only clear ${kTonightMinAltitudeDeg.round()}° '
    'in daylight are not listed. Because brightness and framing count too, '
    'the order can differ from the hours column.';

/// The stretch of tonight worth pointing a camera at.
class DarknessWindow {
  /// When the sky reaches the darkest band this site gets tonight.
  final DateTime start;

  /// When it stops being that dark.
  final DateTime end;

  /// True when [start]/[end] are astronomical dusk and dawn.
  ///
  /// False where the site never gets astronomical night (mid-summer at high
  /// latitude); the darkest band it does get is used instead, because
  /// "no targets tonight" would be a worse answer than "these, in nautical
  /// twilight".
  final bool isAstronomical;

  const DarknessWindow({
    required this.start,
    required this.end,
    required this.isAstronomical,
  });

  Duration get duration => end.difference(start);

  double get hours => duration.inSeconds / 3600.0;
}

/// Tonight's darkness window, or null when the sun never sets far enough for
/// the site to have one at all (polar summer).
DarknessWindow? darknessWindowOf(TwilightTimes twilight) {
  bool usable(DateTime? start, DateTime? end) =>
      start != null && end != null && end.isAfter(start);

  if (usable(twilight.astronomicalDusk, twilight.astronomicalDawn)) {
    return DarknessWindow(
      start: twilight.astronomicalDusk!,
      end: twilight.astronomicalDawn!,
      isAstronomical: true,
    );
  }
  // Degrade one band at a time rather than falling straight to sunset/sunrise,
  // so a site that only loses astronomical night still plans against the
  // darkest sky it has.
  for (final band in [
    (twilight.nauticalDusk, twilight.nauticalDawn),
    (twilight.civilDusk, twilight.civilDawn),
    (twilight.sunset, twilight.sunrise),
  ]) {
    if (usable(band.$1, band.$2)) {
      return DarknessWindow(
        start: band.$1!,
        end: band.$2!,
        isAstronomical: false,
      );
    }
  }
  return null;
}

/// One ranked target, identified by its index into the input coordinate arrays.
class TonightRanking {
  final int index;

  /// Rise / transit / set against the [kTonightMinAltitudeDeg] floor — the same
  /// shape the rest of the app consumes.
  final ObjectVisibility visibility;

  /// Hours the target spends above the altitude floor INSIDE the darkness
  /// window. This — not a peak altitude reached at noon — is what an operator
  /// can actually integrate tonight.
  final double hoursInDarkness;

  /// Highest altitude reached inside the darkness window, degrees.
  final double peakAltitudeDeg;

  /// When that peak happens. Always an instant inside the darkness window.
  final DateTime? peakTime;

  /// The ranking key (0-100): the app's own [TargetScoringService] night score
  /// at [kTonightConditionsWeight], blended with a catalog-fit term
  /// (brightness / size against the FOV / type) at [kTonightCatalogFitWeight].
  ///
  /// NOT the planner's score on its own — do not label it as one in the UI.
  final double score;

  const TonightRanking({
    required this.index,
    required this.visibility,
    required this.hoursInDarkness,
    required this.peakAltitudeDeg,
    required this.peakTime,
    required this.score,
  });
}

/// Rank catalog positions for the night of [nightDate] at the given site.
///
/// Only targets usable during the darkness window are returned. They are
/// scored by altitude, moon separation, timing, usable hours, and airmass.
/// Primitive coordinate arrays keep this function isolate-safe.
List<TonightRanking> rankTonightTargets({
  required List<double> raDeg,
  required List<double> decDeg,
  required double latitudeDeg,
  required double longitudeDeg,
  required DateTime nightDate,
  int limit = kTonightRankingLimit,
  double minAltitudeDeg = kTonightMinAltitudeDeg,
  List<double?>? magnitudes,
  List<double?>? sizesArcMin,
  List<int?>? objectTypes,
  double? fovWidthDeg,
  double? fovHeightDeg,
}) {
  final twilight = AstronomyCalculations.calculateTwilightTimes(
    date: nightDate,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );
  final window = darknessWindowOf(twilight);
  // Midnight sun: there is no dark time to plan, so there is nothing to rank.
  if (window == null) return const [];

  final mid = window.start.add(
    Duration(seconds: window.duration.inSeconds ~/ 2),
  );
  final (moonRaOfDate, moonDecOfDate, _) = AstronomyCalculations.moonPosition(
    mid,
  );
  // Catalog positions are J2000; the moon theory is of-date. Separations
  // measured across frames are wrong by the precession angle.
  final (moonRa, moonDec) = AstronomyCalculations.precessFromDateToJ2000(
    raDeg: moonRaOfDate,
    decDeg: moonDecOfDate,
    dt: mid,
  );

  final scorer = TargetScoringService(
    latitude: latitudeDeg,
    longitude: longitudeDeg,
    observationTime: mid,
    moonPosition: (moonRa, moonDec),
    moonIllumination: AstronomyCalculations.moonIllumination(mid),
    twilight: twilight,
  );

  final scored =
      <
        ({
          int index,
          double score,
          double hours,
          double peak,
          DateTime? peakTime,
        })
      >[];
  for (var i = 0; i < raDeg.length; i++) {
    final score = scorer.scoreTargetForNight(
      target: DeepSkyObject(
        id: '$i',
        name: '$i',
        coordinates: CelestialCoordinate.fromDegrees(
          raDegrees: raDeg[i],
          decDegrees: decDeg[i],
        ),
        type: DsoType.other,
      ),
      nightStart: window.start,
      nightEnd: window.end,
      minAltitude: minAltitudeDeg,
    );
    final hours = score.visibility.hoursAboveMinAlt;
    final peak = score.visibility.peakAltitude;
    // Nothing that is never usable during darkness belongs on a list headed
    // "Best Targets Tonight", however high it climbs at lunchtime.
    if (score.visibility.neverRises ||
        hours == null ||
        hours <= 0 ||
        peak == null) {
      continue;
    }
    final catalogQuality = _catalogQualityScore(
      magnitude: _at(magnitudes, i),
      sizeArcMin: _at(sizesArcMin, i),
      objectType: _at(objectTypes, i),
      fovWidthDeg: fovWidthDeg,
      fovHeightDeg: fovHeightDeg,
    );
    // Conditions remain the dominant signal, but a target with no useful
    // catalog fit must not win solely because its coordinates culminate well.
    final blendedScore =
        score.totalScore * kTonightConditionsWeight +
        catalogQuality * kTonightCatalogFitWeight;
    scored.add((
      index: i,
      score: blendedScore,
      hours: hours,
      peak: peak,
      peakTime: score.visibility.peakAltitudeTime,
    ));
  }

  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byHours = b.hours.compareTo(a.hours);
    if (byHours != 0) return byHours;
    // Catalog order last so the list is stable between rebuilds.
    return a.index.compareTo(b.index);
  });

  // Rise / transit / set are only needed for the handful that survive, and
  // they are measured against the altitude FLOOR (not the horizon) because
  // that is what the sequencer builder reads back out of them.
  return [
    for (final entry in scored.take(limit))
      TonightRanking(
        index: entry.index,
        visibility: AstronomyCalculations.calculateObjectVisibility(
          raDeg: raDeg[entry.index],
          decDeg: decDeg[entry.index],
          date: nightDate,
          latitudeDeg: latitudeDeg,
          longitudeDeg: longitudeDeg,
          minAltitude: minAltitudeDeg,
        ),
        hoursInDarkness: entry.hours,
        peakAltitudeDeg: entry.peak,
        peakTime: entry.peakTime,
        score: entry.score,
      ),
  ];
}

T? _at<T>(List<T?>? values, int index) =>
    values != null && index < values.length ? values[index] : null;

double _catalogQualityScore({
  required double? magnitude,
  required double? sizeArcMin,
  required int? objectType,
  required double? fovWidthDeg,
  required double? fovHeightDeg,
}) {
  var score = 50.0;
  if (magnitude != null && magnitude.isFinite) {
    score += ((12.0 - magnitude) * 5.0).clamp(-35.0, 35.0);
  }
  if (sizeArcMin != null && sizeArcMin.isFinite && sizeArcMin > 0) {
    final fovArcMin = [fovWidthDeg, fovHeightDeg]
        .whereType<double>()
        .fold<double?>(
          null,
          (smallest, value) => smallest == null
              ? value * 60.0
              : math.min(smallest, value * 60.0),
        );
    if (fovArcMin != null && fovArcMin > 0) {
      final fill = sizeArcMin / fovArcMin;
      if (fill < 0.02) {
        score -= 30;
      } else if (fill > 1.2) {
        score -= 15;
      } else if (fill >= 0.08 && fill <= 0.8) {
        score += 12;
      }
    } else if (sizeArcMin < 1.0) {
      score -= 10;
    }
  }
  // The catalog type is a weak prior only; missing metadata stays neutral.
  if (objectType != null &&
      objectType >= 0 &&
      objectType < DsoType.values.length) {
    final type = DsoType.values[objectType];
    if (type.isGalaxy || type.isNebula || type.isCluster) score += 4;
    if (type == DsoType.star || type == DsoType.doubleStar) score -= 4;
  }
  return score.clamp(0.0, 100.0);
}

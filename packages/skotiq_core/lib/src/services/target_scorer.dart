import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        ApiFloorSample,
        ApiNightScore,
        ApiNightSky,
        ApiNightTarget,
        ApiSchedulerTarget,
        ApiScoringWeights;

import '../backend/target_scoring.dart';

/// A TargetScheduler step's target.
class SchedulerTarget {
  final String id;
  final String name;
  final double raHours;
  final double decDegrees;
  final double? minAltitudeDeg;
  final DateTime? startAfter;
  final DateTime? endBefore;
  final int priority;

  const SchedulerTarget({
    required this.id,
    required this.name,
    required this.raHours,
    required this.decDegrees,
    this.minAltitudeDeg,
    this.startAfter,
    this.endBefore,
    this.priority = 0,
  });
}

/// A TargetScheduler step's target scored now.
class SchedulerTargetScore {
  final SchedulerTarget target;
  final double totalScore;
  final double altitudeDeg;

  /// Null below the horizon.
  final double? airmass;
  final double moonDistanceDeg;
  final bool runnable;

  /// Why the step would not run this target now.
  final String? skipReason;

  const SchedulerTargetScore({
    required this.target,
    required this.totalScore,
    required this.altitudeDeg,
    required this.airmass,
    required this.moonDistanceDeg,
    required this.runnable,
    required this.skipReason,
  });
}

/// The app's target scorer: a TargetScheduler step's ranking now and the
/// night score the planner and the planetarium rank by. The scoring itself is
/// the native sequencer's; this turns the app's values into its terms and
/// back.
class TargetScorer {
  const TargetScorer(this._scoring);

  final TargetScoring _scoring;

  /// [targets] ranked as the step ranks them at [now]: runnable first, then by
  /// score, then by priority.
  Future<List<SchedulerTargetScore>> rankSchedulerTargets({
    required double latitudeDeg,
    required double longitudeDeg,
    required DateTime now,
    required List<SchedulerTarget> targets,
    required ScoringWeights weights,
    double? minMoonSeparationDeg,
    required AltitudeFloorSamples floor,
  }) async {
    final scores = await _scoring.rankSchedulerTargets(
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      nowUnixMs: now.millisecondsSinceEpoch,
      targets: [
        for (final (i, t) in targets.indexed)
          ApiSchedulerTarget(
            id: '$i',
            name: t.name,
            raHours: t.raHours,
            decDegrees: t.decDegrees,
            minAltitudeDeg: t.minAltitudeDeg,
            startAfterUnixSecs: _unixSeconds(t.startAfter),
            endBeforeUnixSecs: _unixSeconds(t.endBefore),
            priority: t.priority,
          ),
      ],
      weights: _apiWeights(weights, minMoonSeparationDeg),
      floor: _apiFloor(floor),
    );
    return [
      for (final s in scores)
        if (_requested(targets, s.targetId) case final target?)
          SchedulerTargetScore(
            target: target,
            totalScore: s.totalScore,
            altitudeDeg: s.altitudeDeg,
            airmass: s.airmass.isFinite ? s.airmass : null,
            moonDistanceDeg: s.moonDistanceDeg,
            runnable: s.runnable,
            skipReason: s.skipReason,
          ),
    ];
  }

  /// The targets of [request] above the floor at some point of the night,
  /// each with its night score; the [NightScorer] the app hands the
  /// planetarium.
  Future<List<TargetScore>> scoreForNight(NightScoringRequest request) async {
    final scores = await _scoring.scoreTargetsForNight(
      sky: ApiNightSky(
        latitudeDeg: request.latitudeDeg,
        longitudeDeg: request.longitudeDeg,
        nowUnixMs: request.now.millisecondsSinceEpoch,
        nightStartUnixMs: request.nightStart.millisecondsSinceEpoch,
        nightEndUnixMs: request.nightEnd.millisecondsSinceEpoch,
        moonRaDeg: request.moon?.$1,
        moonDecDeg: request.moon?.$2,
        moonIlluminationPercent: request.moonIlluminationPercent,
        floor: _apiFloor(request.floor),
      ),
      targets: [
        for (final (i, t) in request.targets.indexed)
          ApiNightTarget(
            id: '$i',
            raDeg: t.coordinates.raDegrees,
            decDeg: t.coordinates.dec,
          ),
      ],
      weights: _apiWeights(request.weights, null),
    );
    return [
      for (final s in scores)
        if (_requested(request.targets, s.targetId) case final target?)
          _nightScore(target, s),
    ];
  }
}

/// The request's target a score names: the scorer is sent each target's index
/// in the request as its id.
T? _requested<T>(List<T> targets, String id) {
  final index = int.tryParse(id);
  return index != null && index >= 0 && index < targets.length
      ? targets[index]
      : null;
}

int? _unixSeconds(DateTime? at) =>
    at == null ? null : at.millisecondsSinceEpoch ~/ 1000;

DateTime? _instant(int? unixMs) => unixMs == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(unixMs, isUtc: true);

ApiScoringWeights _apiWeights(ScoringWeights w, double? minMoonSeparationDeg) =>
    ApiScoringWeights(
      altitude: w.altitudeWeight,
      moonDistance: w.moonDistanceWeight,
      transitProximity: w.transitProximityWeight,
      darkness: w.darknessWeight,
      airmass: w.airmassWeight,
      minMoonSeparationDeg: minMoonSeparationDeg,
    );

List<ApiFloorSample> _apiFloor(AltitudeFloorSamples floor) => [
  for (var i = 0; i < floor.azimuths.length; i++)
    ApiFloorSample(
      azimuthDeg: floor.azimuths[i],
      altitudeDeg: floor.altitudes[i],
    ),
];

/// A night score as the app's [TargetScore]: the scorer's figures, with no
/// warnings and no rise or set times. Those are shown by the app's own
/// visibility rule, so a caller that shows them adds them ([nightWarnings],
/// [AstronomyCalculations.calculateObjectVisibilityAround]).
TargetScore _nightScore(CelestialObject target, ApiNightScore s) => TargetScore(
  target: target,
  totalScore: s.totalScore,
  altitudeScore: s.altitudeScore,
  moonDistanceScore: s.moonDistanceScore,
  transitProximityScore: s.transitProximityScore,
  darknessScore: s.darknessScore,
  airmassScore: s.airmassScore,
  warnings: const [],
  visibility: TargetVisibilityInfo(
    currentAltitude: s.currentAltitudeDeg,
    currentAzimuth: s.currentAzimuthDeg,
    airmass: AstronomyCalculations.airmass(s.currentAltitudeDeg),
    moonDistance: s.moonDistanceDeg,
    peakAltitude: s.peakAltitudeDeg,
    peakAzimuth: s.peakAzimuthDeg,
    peakAltitudeTime: _instant(s.peakUnixMs),
    hoursAboveMinAlt: s.hoursAboveFloor,
    aboveFloorFrom: _instant(s.aboveFloorFromUnixMs),
    aboveFloorUntil: _instant(s.aboveFloorUntilUnixMs),
    bestAirmass: s.bestAirmass,
  ),
);

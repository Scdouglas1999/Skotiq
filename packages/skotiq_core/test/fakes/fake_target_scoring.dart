import 'dart:math' as math;

import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        ApiFloorSample,
        ApiNightScore,
        ApiNightSky,
        ApiNightTarget,
        ApiSchedulerTarget,
        ApiScoringWeights,
        ApiTargetScoreNow;
import 'package:skotiq_core/backend.dart' show TargetScoring;

/// A [TargetScoring] for tests of the scorer's callers. The scoring itself is
/// the native sequencer's and is tested there; this stands in with a rough
/// model: a target counts as reaching its meridian altitude
/// (90 - |latitude - dec|) for six hours of the night when that clears the
/// floor toward the meridian, scores that altitude, and is otherwise left
/// out as never usable.
class FakeTargetScoring implements TargetScoring {
  final nightRequests = <({ApiNightSky sky, List<ApiNightTarget> targets})>[];

  @override
  Future<List<ApiNightScore>> scoreTargetsForNight({
    required ApiNightSky sky,
    required List<ApiNightTarget> targets,
    required ApiScoringWeights weights,
  }) async {
    nightRequests.add((sky: sky, targets: targets));
    final middle =
        sky.nightStartUnixMs + (sky.nightEndUnixMs - sky.nightStartUnixMs) ~/ 2;
    return [
      for (final t in targets)
        if (_meridianAltitude(sky.latitudeDeg, t.decDeg) case final peak
            when peak >= _floorToward(sky.floor, sky.latitudeDeg, t.decDeg))
          ApiNightScore(
            targetId: t.id,
            totalScore: peak.clamp(0, 100).toDouble(),
            altitudeScore: peak.clamp(0, 100).toDouble(),
            moonDistanceScore: 90,
            transitProximityScore: 90,
            darknessScore: 90,
            airmassScore: 90,
            currentAltitudeDeg: peak,
            currentAzimuthDeg: t.decDeg < sky.latitudeDeg ? 180 : 0,
            peakAltitudeDeg: peak,
            peakAzimuthDeg: t.decDeg < sky.latitudeDeg ? 180 : 0,
            peakUnixMs: middle,
            hoursAboveFloor: 6,
            aboveFloorFromUnixMs: sky.nightStartUnixMs,
            aboveFloorUntilUnixMs: sky.nightStartUnixMs + 6 * 3600000,
            bestAirmass: 1 / math.sin(peak * math.pi / 180),
            moonDistanceDeg: _moonDistance(sky, t),
          ),
    ];
  }

  @override
  Future<List<ApiTargetScoreNow>> rankSchedulerTargets({
    required double latitudeDeg,
    required double longitudeDeg,
    required int nowUnixMs,
    required List<ApiSchedulerTarget> targets,
    required ApiScoringWeights weights,
    required List<ApiFloorSample> floor,
  }) async => [
    for (final t in targets)
      ApiTargetScoreNow(
        targetId: t.id,
        totalScore: _meridianAltitude(latitudeDeg, t.decDegrees),
        altitudeScore: 0,
        moonDistanceScore: 0,
        transitProximityScore: 0,
        darknessScore: 0,
        airmassScore: 0,
        altitudeDeg: _meridianAltitude(latitudeDeg, t.decDegrees),
        azimuthDeg: 180,
        airmass: 1,
        moonDistanceDeg: 90,
        runnable: true,
        skipReason: null,
      ),
  ];

  static double _meridianAltitude(double latitudeDeg, double decDeg) =>
      90 - (latitudeDeg - decDeg).abs();

  static double _floorToward(
    List<ApiFloorSample> floor,
    double latitudeDeg,
    double decDeg,
  ) {
    if (floor.isEmpty) return 0;
    final meridian = decDeg < latitudeDeg ? 180.0 : 0.0;
    double gap(ApiFloorSample s) {
      final d = (s.azimuthDeg - meridian).abs() % 360;
      return math.min(d, 360 - d);
    }

    return floor.reduce((a, b) => gap(a) <= gap(b) ? a : b).altitudeDeg;
  }

  static double _moonDistance(ApiNightSky sky, ApiNightTarget t) {
    final (ra, dec) = (sky.moonRaDeg, sky.moonDecDeg);
    if (ra == null || dec == null) return 180;
    double rad(double d) => d * math.pi / 180;
    final cos =
        math.sin(rad(dec)) * math.sin(rad(t.decDeg)) +
        math.cos(rad(dec)) *
            math.cos(rad(t.decDeg)) *
            math.cos(rad(ra - t.raDeg));
    return math.acos(cos.clamp(-1.0, 1.0)) * 180 / math.pi;
  }
}

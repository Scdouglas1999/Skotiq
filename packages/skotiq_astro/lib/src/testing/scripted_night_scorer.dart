import 'package:skotiq_astro/skotiq_astro.dart';

/// A [NightScorer] that answers with scripted figures instead of scoring:
/// the scoring itself is the native sequencer's and is tested there.
///
/// Every requested target comes back with [total] points, [hours] above the
/// floor and a [peak] altitude at the middle of the night, unless [byIndex]
/// names other figures for its index in the request; a `null` entry leaves
/// that target out, as the scorer does with one that is never usable.
class ScriptedNightScorer {
  ScriptedNightScorer({
    this.total = 70,
    this.hours = 6,
    this.peak = 60,
    this.byIndex = const {},
  });

  final double total;
  final double hours;
  final double peak;
  final Map<int, ({double total, double hours})?> byIndex;

  final requests = <NightScoringRequest>[];

  Future<List<TargetScore>> call(NightScoringRequest request) async {
    requests.add(request);
    final middle = request.nightStart.add(
      request.nightEnd.difference(request.nightStart) ~/ 2,
    );
    return [
      for (final (i, target) in request.targets.indexed)
        if (!byIndex.containsKey(i) || byIndex[i] != null)
          TargetScore(
            target: target,
            totalScore: byIndex[i]?.total ?? total,
            altitudeScore: 0,
            moonDistanceScore: 0,
            transitProximityScore: 0,
            darknessScore: 0,
            airmassScore: 0,
            warnings: const [],
            visibility: TargetVisibilityInfo(
              currentAltitude: peak,
              currentAzimuth: 180,
              airmass: 1,
              moonDistance: 90,
              peakAltitude: peak,
              peakAzimuth: 180,
              peakAltitudeTime: middle,
              hoursAboveMinAlt: byIndex[i]?.hours ?? hours,
            ),
          ),
    ];
  }
}

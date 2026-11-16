import 'package:skotiq_astro/format.dart';

import '../astronomy/altitude_floor_search.dart';
import '../astronomy/astronomy_calculations.dart';
import '../celestial_object.dart';

import 'target_scoring/models.dart';

export 'target_scoring/models.dart';

part 'target_scoring/warnings.dart';

/// What a night ranking is asked: the site, the dark stretch of the night,
/// the Moon over it and the positions to score.
class NightScoringRequest {
  final double latitudeDeg;
  final double longitudeDeg;

  /// When the "current altitude" figures are read.
  final DateTime now;

  /// The dark stretch the targets are scored over.
  final DateTime nightStart;
  final DateTime nightEnd;

  /// The Moon for the night, RA and Dec in degrees in the targets' frame
  /// (J2000); null scores every target as far from it.
  final (double raDeg, double decDeg)? moon;

  /// Illuminated percentage, 0-100.
  final double moonIlluminationPercent;

  /// The altitude floor by azimuth.
  final AltitudeFloorSamples floor;

  final List<CelestialObject> targets;
  final ScoringWeights weights;

  const NightScoringRequest({
    required this.latitudeDeg,
    required this.longitudeDeg,
    required this.now,
    required this.nightStart,
    required this.nightEnd,
    required this.moon,
    required this.moonIlluminationPercent,
    required this.floor,
    required this.targets,
    this.weights = const ScoringWeights(),
  });
}

/// Scores [NightScoringRequest.targets] over the night and answers for the
/// ones above the floor at some point of it.
///
/// The app's one target scorer runs in the native sequencer, where the
/// TargetScheduler step ranks with it; the app supplies it as this function.
typedef NightScorer =
    Future<List<TargetScore>> Function(NightScoringRequest request);

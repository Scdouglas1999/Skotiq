part of '../weather_safety_provider.dart';

/// One light frame's detected star count, for [evaluateStarEvidence].
typedef StarSample = ({DateTime capturedAt, int stars, double exposureSecs});

/// What the run's own frames say about the sky: the newest light frame's star
/// count against what this session's frames usually show.
class SkyStarEvidence {
  /// Stars detected in the newest light frame.
  final int latestStars;

  /// The median star count of the session's earlier light frames.
  final int typicalStars;

  /// When the newest light frame was taken.
  final DateTime latestAt;

  /// The newest frame holds at least half the usual stars: the sky over the
  /// target was clear when it was taken, whatever a forecast says.
  final bool clear;

  const SkyStarEvidence({
    required this.latestStars,
    required this.typicalStars,
    required this.latestAt,
    required this.clear,
  });

  @override
  bool operator ==(Object other) =>
      other is SkyStarEvidence &&
      other.latestStars == latestStars &&
      other.typicalStars == typicalStars &&
      other.latestAt == latestAt &&
      other.clear == clear;

  @override
  int get hashCode => Object.hash(latestStars, typicalStars, latestAt, clear);
}

/// Fewest earlier frames that make a usable baseline.
const int _starEvidenceMinBaselineFrames = 3;

/// A baseline below this many stars is too sparse a field to judge cloud by.
const int _starEvidenceMinTypicalStars = 20;

/// Share of the usual star count the newest frame must keep to read clear.
const double _starEvidenceClearFraction = 0.5;

/// How old the newest frame may be and still speak for the sky now: fifteen
/// minutes, or three of its own exposures for long subs.
Duration _starEvidenceMaxAge(double exposureSecs) {
  final threeSubs = Duration(milliseconds: (exposureSecs * 3000).round());
  const floor = Duration(minutes: 15);
  return threeSubs > floor ? threeSubs : floor;
}

/// Judge the sky from the session's light frames, oldest first. `null` when
/// the frames cannot say: too few of them, a sparse field, or a newest frame
/// too old to speak for the sky now.
SkyStarEvidence? evaluateStarEvidence(List<StarSample> lights, DateTime now) {
  if (lights.length < _starEvidenceMinBaselineFrames + 1) return null;
  final latest = lights.last;
  if (now.difference(latest.capturedAt) >
      _starEvidenceMaxAge(latest.exposureSecs)) {
    return null;
  }
  final earlier = lights.sublist(0, lights.length - 1);
  final window = earlier.length > 20
      ? earlier.sublist(earlier.length - 20)
      : earlier;
  final counts = window.map((s) => s.stars).toList()..sort();
  final mid = counts.length ~/ 2;
  final typical = counts.length.isOdd
      ? counts[mid]
      : ((counts[mid - 1] + counts[mid]) / 2).round();
  if (typical < _starEvidenceMinTypicalStars) return null;
  return SkyStarEvidence(
    latestStars: latest.stars,
    typicalStars: typical,
    latestAt: latest.capturedAt,
    clear: latest.stars >= typical * _starEvidenceClearFraction,
  );
}

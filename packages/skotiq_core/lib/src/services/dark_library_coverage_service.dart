import 'package:skotiq_astro/format.dart';

import '../database/database.dart';
import '../models/calibration/dark_library_match_tolerances.dart';

/// A light-frame calibration requirement that should have matching darks.
class DarkFrameRequirement {
  final int gain;
  final int offset;
  final double durationSecs;
  final int binX;
  final int binY;
  final double? targetTemp;

  const DarkFrameRequirement({
    required this.gain,
    required this.offset,
    required this.durationSecs,
    required this.binX,
    required this.binY,
    required this.targetTemp,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DarkFrameRequirement &&
          gain == other.gain &&
          offset == other.offset &&
          durationSecs == other.durationSecs &&
          binX == other.binX &&
          binY == other.binY &&
          targetTemp == other.targetTemp;

  @override
  int get hashCode =>
      Object.hash(gain, offset, durationSecs, binX, binY, targetTemp);

  /// `300 s darks at gain 100, offset 50, -10.0°C, binning 1x1`.
  String describe() {
    final whole = durationSecs == durationSecs.roundToDouble();
    final seconds = whole
        ? durationSecs.toStringAsFixed(0)
        : durationSecs.toString();
    final temperature = targetTemp == null
        ? 'any temperature'
        : formatCelsius(targetTemp);
    return '$seconds s darks at gain $gain, offset $offset, $temperature, '
        'binning ${binX}x$binY';
  }
}

class DarkLibraryCoverageReport {
  final List<DarkFrameRequirement> missing;
  final Map<DarkFrameRequirement, int> underCovered;

  const DarkLibraryCoverageReport({
    required this.missing,
    required this.underCovered,
  });

  bool get isCovered => missing.isEmpty && underCovered.isEmpty;
}

/// Shared evaluator for dark-library coverage.
///
/// Keep this as the single place that defines exposure/temperature tolerance,
/// raw-frame quorum handling, and master-dark precedence. Preflight and Smart
/// Night both call through here so calibration warnings do not drift apart.
///
/// Tolerance values come from [DarkLibraryMatchTolerances] so this service and
/// `DarkLibraryDao.findBestMatch` can never disagree. A coverage UI on ±1.0s
/// exposure tolerance against a DAO on ±0.001s shows a green checkmark while
/// the runtime dark match silently returns null.
class DarkLibraryCoverageService {
  const DarkLibraryCoverageService();

  DarkLibraryCoverageReport evaluate({
    required Iterable<DarkFrameRequirement> requirements,
    required Iterable<DarkLibraryEntry> entries,
    required int minCoverage,
    DarkLibraryMatchTolerances tolerances = DarkLibraryMatchTolerances.defaults,
  }) {
    final missing = <DarkFrameRequirement>[];
    final underCovered = <DarkFrameRequirement, int>{};

    for (final req in requirements.toSet()) {
      final matches = entries
          .where((e) {
            if (e.frameType != 'dark') return false;
            if (e.gain != req.gain) return false;
            if (e.offset != req.offset) return false;
            if (e.binX != req.binX) return false;
            if (e.binY != req.binY) return false;
            if ((e.exposureTime - req.durationSecs).abs() >
                tolerances.exposureSecs) {
              return false;
            }
            if (req.targetTemp != null && e.temperature != null) {
              if ((e.temperature! - req.targetTemp!).abs() >
                  tolerances.temperatureC) {
                return false;
              }
            }
            return true;
          })
          .toList(growable: false);

      if (matches.isEmpty) {
        missing.add(req);
        continue;
      }

      if (matches.any((m) => m.masterDarkPath != null)) {
        continue;
      }

      if (matches.length < minCoverage) {
        underCovered[req] = matches.length;
      }
    }

    return DarkLibraryCoverageReport(
      missing: List.unmodifiable(missing),
      underCovered: Map.unmodifiable(underCovered),
    );
  }
}

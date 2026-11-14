import 'package:skotiq_astro/format.dart';

import '../database/database.dart';
import '../models/calibration/calibration_library_models.dart';
import '../models/calibration/dark_library_match_tolerances.dart';
import 'calibration/calibration_selection.dart';

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

/// Whether the dark library holds darks that calibrate each planned exposure
/// with no caveat ([darksWithinTolerance]), and enough raw frames where there
/// is no stacked master. Preflight and Smart Night both call through here.
///
/// A requirement reported missing can still draw a dark at run time: the
/// selection rule falls back to the nearest temperature. Coverage reports it so
/// the operator can shoot a closer one.
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

    final records = [
      for (final e in entries)
        if (e.frameType == 'dark') darkLibraryRecord(e),
    ];
    for (final req in requirements.toSet()) {
      final matches = darksWithinTolerance(
        records,
        LightFrameContext(
          gain: req.gain,
          offset: req.offset,
          exposureSeconds: req.durationSecs,
          temperature: req.targetTemp,
          binX: req.binX,
          binY: req.binY,
        ),
        tolerances,
      );

      if (matches.isEmpty) {
        missing.add(req);
        continue;
      }

      if (matches.any((m) => m.isMaster)) {
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

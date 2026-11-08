import 'package:skotiq_core/skotiq_core.dart';

import 'polar_alignment_error_format.dart';

/// Which measurement point the published status is talking about.
///
/// `state.currentPoint` is the point that has been MEASURED — the run only
/// advances it once the next point's frame is in hand — so during a move it
/// still reads the point behind, while the status text names the destination.
/// When the status names a point, that number wins.
int polarRunEffectivePoint(String status, int point) {
  final match = RegExp(r'point\s+(\d+)', caseSensitive: false).firstMatch(
    status,
  );
  final named = match == null ? null : int.tryParse(match.group(1)!);
  if (named == null || named < 1 || named > 3) return point;
  return named;
}

/// The activity line of a measuring run.
///
/// Derived from the status the run publishes, so two lines on screen cannot
/// disagree. A fixed "Capturing Point N" spans the plate solve that follows
/// the exposure and goes minutes stale.
String polarRunActivityLabel(String status, int point) {
  final phrase = status.toLowerCase();
  final at = polarRunEffectivePoint(status, point);
  if (phrase.contains('solv')) return 'Plate solving point $at of 3';
  if (phrase.contains('slew')) return 'Slewing to point $at of 3';
  if (phrase.contains('rotat')) return 'Rotating to point $at of 3';
  if (phrase.contains('captur') || phrase.contains('expos')) {
    return 'Capturing point $at of 3';
  }
  return 'Point $at of 3';
}

/// Whether a polar alignment run is in progress: measuring or adjusting.
bool polarRunIsLive(PolarAlignmentState state) =>
    state.phase == PolarAlignPhase.measuring ||
    state.phase == PolarAlignPhase.adjusting;

/// One line saying what a live run is doing, for surfaces outside the polar
/// alignment screen: "Capturing point 2 of 3", or "Adjusting · 36' 50"" once
/// the adjustment phase has a measurement. Null when no run is live.
String? polarRunSummary(PolarAlignmentState state) {
  switch (state.phase) {
    case PolarAlignPhase.measuring:
      return polarRunActivityLabel(state.statusMessage, state.currentPoint);
    case PolarAlignPhase.adjusting:
      final error = state.currentError;
      return error == null
          ? 'Adjusting · waiting for a frame'
          : 'Adjusting · ${formatPolarError(error.totalError)} off';
    case PolarAlignPhase.idle:
    case PolarAlignPhase.complete:
    case PolarAlignPhase.error:
      return null;
  }
}

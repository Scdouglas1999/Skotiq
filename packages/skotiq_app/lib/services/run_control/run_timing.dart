// When a run's finish time stops being a promise: the run has gone longer
// without progress than its own frame cadence allows.

import 'package:skotiq_core/models.dart';

/// Slack added to the run's own frame cadence before the run is called stalled.
///
/// Covers the honest gaps between frames — download, dither and settle, a
/// filter change, an autofocus sweep — so a healthy run is never accused of
/// standing still. It is added to TWICE the average planned frame, so the
/// threshold scales with the subs the operator actually chose: a 15 s sub is
/// called stalled after 90 s of silence, a 10-minute sub after 21 minutes.
const Duration _kStallSlack = Duration(seconds: 60);

/// How long the run has gone without any progress before its finish time stops
/// being a promise. `null` when the run's cadence is unknown (no planned
/// integration), in which case nothing is claimed either way.
Duration? runStallThreshold(SequenceProgress progress) {
  if (progress.totalExposures <= 0 || progress.totalIntegrationSecs <= 0) {
    return null;
  }
  final perFrameSecs = progress.totalIntegrationSecs / progress.totalExposures;
  return Duration(milliseconds: (perFrameSecs * 2 * 1000).round()) +
      _kStallSlack;
}

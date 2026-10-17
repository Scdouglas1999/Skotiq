import 'package:skotiq_core/skotiq_core.dart';

/// Why a flat run ended with nothing on disk, said in numbers the operator can
/// act on.
///
/// Everything here is derived from state the wizard already carries
/// ([FlatWizardState.aduHistory], the per-filter results, the global limits and
/// the solver's own reason on `FlatWizardState.warningMessage`).
/// Nothing is invented: in particular the absolute target ADU is NOT restated,
/// because the ADU/full-scale conversion depends on the camera's bit depth,
/// which the wizard state does not carry. The target is quoted as the histogram
/// percentage the operator actually typed in.
class FlatFailureDiagnosis {
  /// What the measurements say went wrong, with the numbers.
  final String reason;

  /// The thing to change before trying again.
  final String nextStep;

  const FlatFailureDiagnosis({required this.reason, required this.nextStep});
}

/// How much the exposure has to grow before a flat ADU that barely moved counts
/// as evidence that the light source, not the exposure, is the problem.
const double _kStalledExposureGrowth = 4.0;

/// The most an ADU may grow across that exposure ramp and still be called
/// "did not respond". A correctly illuminated panel scales roughly linearly, so
/// a 4x exposure that yields under 1.5x signal is not an exposure problem.
const double _kStalledAduGrowth = 1.5;

/// Read the wizard's terminal state and name the failure.
///
/// Returns null when there is nothing measured to reason about (no calibration
/// exposure ever completed), in which case the caller should render only the
/// wizard's own message rather than guess.
FlatFailureDiagnosis? diagnoseFlatFailure(FlatWizardState state) {
  final history = state.aduHistory;
  if (history.isEmpty) return null;

  final first = history.first;
  final last = history.last;
  final settings = state.globalSettings;
  final failed = state.filterSettings
      .where((f) => f.status == FilterCalibrationStatus.failed)
      .toList(growable: false);
  final filterLabel = failed.length == 1 ? '${failed.single.filterName}: ' : '';
  final targetPercent = _formatPercent(settings.histogramTarget);

  // The light source, not the exposure, is the problem: the solver ramped the
  // exposure hard and the frame barely got brighter. This is the flat-panel-is
  // -off / scope-is-still-capped case, and it is the one worth calling out
  // first because no exposure change will ever fix it.
  final exposureGrowth =
      first.exposure > 0 ? last.exposure / first.exposure : 0.0;
  final aduGrowth = first.adu > 0 ? last.adu / first.adu : double.infinity;
  if (exposureGrowth >= _kStalledExposureGrowth &&
      aduGrowth < _kStalledAduGrowth) {
    return FlatFailureDiagnosis(
      reason: '${filterLabel}brightness barely changed while the exposure grew '
          '${_formatRatio(exposureGrowth)} '
          '(${_formatSeconds(first.exposure)} to '
          '${_formatSeconds(last.exposure)}, '
          '${last.adu.round()} ADU against ${first.adu.round()}).',
      nextStep: 'The sensor is not being illuminated. Check the flat panel is '
          'switched on and bright enough, and that the scope is uncapped.',
    );
  }

  // Hit the exposure ceiling still short of the target.
  if (last.exposure >= settings.maxExposure * 0.999) {
    return FlatFailureDiagnosis(
      reason: '${filterLabel}at the ${_formatSeconds(settings.maxExposure)} '
          'maximum exposure the frame only reached ${last.adu.round()} ADU, '
          'short of the $targetPercent target.',
      nextStep: 'Raise the panel brightness or the camera gain, lower the '
          'target level, or raise the maximum exposure.',
    );
  }

  // Hit the exposure floor still over the target: too much light.
  if (last.exposure <= settings.minExposure * 1.001) {
    return FlatFailureDiagnosis(
      reason: '${filterLabel}even at the '
          '${_formatSeconds(settings.minExposure)} minimum exposure the frame '
          'reached ${last.adu.round()} ADU, over the $targetPercent target.',
      nextStep: 'Dim the panel or lower the camera gain, or raise the target '
          'level.',
    );
  }

  return FlatFailureDiagnosis(
    reason: '${filterLabel}the exposure search stopped after '
        '${history.length} attempt${history.length == 1 ? '' : 's'} at '
        '${_formatSeconds(last.exposure)} / '
        '${last.adu.round()} ADU without settling on the $targetPercent '
        'target.',
    nextStep:
        'Widen the tolerance, allow more solver iterations, or steady the '
        'light source — a changing sky will not converge.',
  );
}

String _formatSeconds(double seconds) {
  if (seconds >= 10) return '${seconds.toStringAsFixed(1)} s';
  if (seconds >= 0.1) return '${seconds.toStringAsFixed(2)} s';
  return '${seconds.toStringAsFixed(3)} s';
}

String _formatRatio(double ratio) {
  if (ratio >= 10) return '${ratio.round()}x';
  return '${ratio.toStringAsFixed(1)}x';
}

String _formatPercent(double percent) {
  final rounded = percent.roundToDouble();
  return (percent - rounded).abs() < 0.05
      ? '${rounded.toInt()}%'
      : '${percent.toStringAsFixed(1)}%';
}

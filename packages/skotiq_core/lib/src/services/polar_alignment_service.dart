import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/polar_alignment_config.dart';
import '../providers/polar_alignment_provider.dart';

/// Service entry points for polar alignment routines.
///
/// This is a thin façade over the single guarded state machine in
/// `polar_alignment_provider.dart` (`PolarAlignmentStateNotifier`). It exposes
/// algorithm-specific entry points (`threePoint`, `allSky`) so callers don't
/// have to thread mode flags through the rest of the codebase.
///
/// Crucially, it now routes through the notifier rather than driving the
/// backend directly: that keeps *one* serialized/idempotent admission path
/// (validation, run-ownership, no-overlap guards, history persistence) so the
/// service cannot start a run that overlaps one already owning the hardware.
class PolarAlignmentService {
  final Ref _ref;

  PolarAlignmentService(this._ref);

  PolarAlignmentStateNotifier get _notifier =>
      _ref.read(polarAlignmentStateProvider.notifier);

  /// Start the legacy Three-Point Polar Alignment routine. Requires a clear
  /// view of the celestial pole region. Throws
  /// [PolarAlignmentValidationException] on invalid config and
  /// [PolarAlignmentBusyException] if a run is already active.
  Future<void> threePoint(PolarAlignmentConfig config) =>
      _notifier.startAlignment(config);

  /// Start the all-sky (Sharpcap-style) polar alignment routine. Works from
  /// any direction in the sky — does **not** require the pole region to be
  /// visible. Requires an external plate solver (ASTAP); the backend throws
  /// if one is not installed.
  ///
  /// The `acceptanceThresholdArcsec` argument controls when the alignment
  /// auto-completes; when supplied it overrides the config's
  /// `autoCompleteThreshold`. The default corresponds to ~3-minute unguided
  /// imaging precision.
  Future<void> allSky({
    required PolarAlignmentConfig config,
    double? acceptanceThresholdArcsec,
  }) {
    final effective = acceptanceThresholdArcsec != null
        ? config.copyWith(autoCompleteThreshold: acceptanceThresholdArcsec)
        : config;
    return _notifier.startAllSkyAlignment(effective);
  }

  /// Stop any currently-running polar alignment (TPPA or all-sky).
  Future<void> stop() => _notifier.stopAlignment();
}

/// Riverpod provider for the polar alignment service.
final polarAlignmentServiceProvider = Provider<PolarAlignmentService>((ref) {
  return PolarAlignmentService(ref);
});

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

/// The plate solver the operator picked, and whether it is installed.
@immutable
class NightSolverStatus {
  const NightSolverStatus({required this.ready, this.name});

  final bool ready;

  /// "ASTAP" or "Astrometry.net"; null when none is installed.
  final String? name;
}

/// Null while detection runs: a solver still being looked for is not a
/// missing solver.
final nightSolverStatusProvider = Provider<NightSolverStatus?>((ref) {
  final detection = ref.watch(plateSolverDetectionProvider).valueOrNull;
  final preference = ref.watch(plateSolverPreferenceProvider).valueOrNull;
  if (detection == null || preference == null) return null;
  final ready = detection.supports(preference.choice);
  final name = switch (preference.choice) {
    PlateSolverChoice.astap => 'ASTAP',
    PlateSolverChoice.astrometry => 'Astrometry.net',
    PlateSolverChoice.auto => detection.astapReady
        ? 'ASTAP'
        : detection.astrometryPath != null
            ? 'Astrometry.net'
            : null,
  };
  return NightSolverStatus(ready: ready, name: ready ? name : null);
});

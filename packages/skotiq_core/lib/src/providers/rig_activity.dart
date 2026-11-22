import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/rig_activity.dart';
import '../models/sequence/sequence_models.dart';
import 'flat_wizard_provider.dart';
import 'imaging_service_providers.dart';
import 'meridian_flip_provider.dart' show isFlipInProgressProvider;
import 'sequence/sequence_progress.dart'
    show sequenceExecutionStateProvider, sequenceLaunchInFlightProvider;
import 'session_provider.dart' show sessionStateProvider;

/// Reads one provider, as `Ref.read` does.
typedef RigRead = T Function<T>(ProviderListenable<T> provider);

/// The first activity other than [starting] that holds the camera or the
/// mount now, or null when the rig is free for it.
///
/// Each activity is read from its own live state, never from a claim it took:
/// an activity that died without cleaning up holds nothing once its own state
/// says it ended, so a restart or a resume is never blocked by it.
///
/// A paused run holds the rig for every start but a manual capture: Tonight
/// takes its frames (solve, center) while it holds the run paused.
RigActivity? rigHeldBy(RigRead read, {required RigActivity starting}) {
  for (final activity in RigActivity.values) {
    if (activity == starting) continue;
    final holds = switch (activity) {
      RigActivity.flats => read(flatWizardProvider.notifier).isBusy,
      RigActivity.flip => read(isFlipInProgressProvider),
      RigActivity.sequence => _runHolds(read, starting),
      RigActivity.manualCapture =>
        read(imagingServiceProvider).isCapturing ||
            read(sessionStateProvider).isCapturing ||
            read(rawCameraExposureInFlightProvider),
    };
    if (holds) return activity;
  }
  return null;
}

bool _runHolds(RigRead read, RigActivity starting) {
  if (read(sequenceLaunchInFlightProvider)) return true;
  final run = read(sequenceExecutionStateProvider);
  if (starting == RigActivity.manualCapture &&
      run == SequenceExecutionState.paused) {
    return false;
  }
  return run.ownsHardware;
}

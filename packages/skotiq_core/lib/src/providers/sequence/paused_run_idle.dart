import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/imaging_models.dart';
import '../../models/sequence/sequence_models.dart';
import '../../services/imaging_service.dart' show exposureProgressProvider;
import '../equipment/camera_state_provider.dart';
import '../equipment/focuser_state_provider.dart';
import '../equipment/mount_state_provider.dart';
import 'sequence_progress.dart';

/// Whether the step a paused run was in is still finishing: an exposure or
/// its download, a slew or a focuser move. Native pause lets that step
/// finish, so a paused run is safe to act around only once this is false.
bool pausedStepInFlight({
  required ExposureProgress exposure,
  required bool cameraExposing,
  required bool mountSlewing,
  required bool focuserMoving,
}) =>
    exposure.remaining > 0 ||
    exposure.isDownloading ||
    cameraExposing ||
    mountSlewing ||
    focuserMoving;

/// While the run is paused: true once the step it was in has finished, false
/// while it is still finishing. Null when the run is not paused. A linked
/// client reads it from the device and exposure state the host mirrors to
/// it; the host's own answer is `pausedIdle` in GET /api/sequencer/status.
final pausedRunIdleProvider = Provider<bool?>((ref) {
  if (ref.watch(sequenceExecutionStateProvider) !=
      SequenceExecutionState.paused) {
    return null;
  }
  return !pausedStepInFlight(
    exposure: ref.watch(exposureProgressProvider),
    cameraExposing: ref.watch(cameraStateProvider.select((c) => c.isExposing)),
    mountSlewing: ref.watch(mountStateProvider.select((m) => m.isSlewing)),
    focuserMoving: ref.watch(focuserStateProvider.select((f) => f.isMoving)),
  );
});

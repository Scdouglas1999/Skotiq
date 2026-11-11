import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        DeviceConnectionState,
        SequenceExecutionState,
        appVersionProvider,
        cameraStateProvider,
        mountStateProvider,
        resolveSkotiqDataDirectory,
        sequenceExecutionStateProvider,
        sequencerBackendProvider;
import 'package:skotiq_updater/skotiq_updater.dart';

// The updater package knows nothing about the rig. This file is where the app
// gives it the three things it needs from the host: the running version, the
// data directory, and the rules for when an update may be offered or applied.

typedef UpdateApplySafetyReader = T Function<T>(ProviderListenable<T> provider);

/// Provider for the update state.
///
/// Reads the running app's version from [appVersionProvider], and lets that
/// provider's error bubble when it has not been overridden at startup: the
/// update server decides whether to advertise a newer build from this string,
/// so a substituted default breaks update polling with nothing on screen to
/// say so.
final updateProvider = StateNotifierProvider<UpdateNotifier, UpdateState>((
  ref,
) {
  final versionInfo = ref.watch(appVersionProvider);
  return UpdateNotifier(
    currentVersion: versionInfo.version,
    currentBuildNumber: versionInfo.buildNumber,
    dataDirectory: resolveSkotiqDataDirectory,
    applySafetyCheck: () => defaultUpdateApplySafetyCheck(ref),
  );
});

/// A sequence that an update prompt or apply must not cut across.
bool isSequenceActiveForUpdate(SequenceExecutionState state) {
  return state == SequenceExecutionState.running ||
      state == SequenceExecutionState.paused ||
      state == SequenceExecutionState.stopping ||
      state == SequenceExecutionState.recovering;
}

Future<void> _checkpointIfSessionLoaded(UpdateApplySafetyReader read) async {
  final sequenceState = read(sequenceExecutionStateProvider);
  if (sequenceState == SequenceExecutionState.idle) {
    return;
  }

  await read(sequencerBackendProvider).saveCheckpoint();
}

/// Run the update-apply safety gate against any Riverpod reader.
///
/// Accepting the reader rather than only a widget/provider [Ref] lets the
/// headless OTA controller use the exact same checks through its root
/// [ProviderContainer]. This keeps GUI and remotely-triggered updates from
/// drifting into different hardware-safety behavior.
Future<void> defaultUpdateApplySafetyCheckWithReader(
  UpdateApplySafetyReader read,
) async {
  final sequenceState = read(sequenceExecutionStateProvider);
  if (isSequenceActiveForUpdate(sequenceState)) {
    try {
      await read(sequencerBackendProvider).saveCheckpoint();
    } catch (e, stackTrace) {
      developer.log(
        'Failed to save checkpoint before refusing update apply: $e',
        name: 'UpdateNotifier',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
    }
    throw UpdateException(
      'Cannot apply an update while a sequence is ${sequenceState.name}. '
      'Stop the sequence before applying the update.',
    );
  }

  final cameraState = read(cameraStateProvider);
  if (cameraState.connectionState == DeviceConnectionState.connected) {
    if (cameraState.isExposing) {
      throw UpdateException(
        'Cannot apply an update while the camera is exposing.',
      );
    }
    final coolerPower = cameraState.coolerPower ?? 0;
    if (cameraState.isCooling || cameraState.isWarming || coolerPower > 2) {
      throw UpdateException(
        'Cannot apply an update while the camera cooler is active. '
        'Warm the camera and wait for cooler power to reach 0% first.',
      );
    }
  }

  final mountState = read(mountStateProvider);
  if (mountState.connectionState == DeviceConnectionState.connected) {
    if (mountState.isSlewing) {
      throw UpdateException(
        'Cannot apply an update while the mount is slewing.',
      );
    }
    if (!mountState.isParked) {
      throw UpdateException(
        'Cannot apply an update until the mount is parked.',
      );
    }
  }

  try {
    await _checkpointIfSessionLoaded(read);
  } catch (e) {
    throw UpdateException(
      'Cannot apply update because the current session checkpoint '
      'could not be saved: $e',
    );
  }
}

Future<void> defaultUpdateApplySafetyCheck(Ref ref) {
  return defaultUpdateApplySafetyCheckWithReader(ref.read);
}

/// Live view of [updatePromptHeldBackReason], so the UI can re-offer an
/// update the moment the rig goes idle.
///
/// Without this, a release found at the start of an imaging run is held back
/// and then not mentioned again until the next scheduled check — up to twelve
/// hours later, quite possibly while nobody is looking. Watching the hold
/// lets the offer arrive when the run ends, which is exactly when an operator
/// can act on it.
final updatePromptHoldProvider = Provider<String?>((ref) {
  // Watched, not read, so this recomputes as the rig's state changes.
  ref.watch(sequenceExecutionStateProvider);
  ref.watch(cameraStateProvider);
  ref.watch(mountStateProvider);
  return updatePromptHeldBackReason(ref.read);
});

/// Why an update prompt is being held back right now, or null when it may be
/// shown.
///
/// Deliberately weaker than the apply gate. Applying swaps the running binary
/// and so demands a parked mount and a cold camera; merely telling someone a
/// release exists demands only that the app not talk over the top of an
/// observing run. Requiring the apply conditions here would mean the prompt
/// never appeared on a rig that is doing its job.
///
/// Suppressing the prompt never suppresses the check: the update is found and
/// held in state, so it is waiting in Settings the moment the operator looks.
String? updatePromptHeldBackReason(UpdateApplySafetyReader read) {
  final sequenceState = read(sequenceExecutionStateProvider);
  if (isSequenceActiveForUpdate(sequenceState)) {
    return 'a sequence is ${sequenceState.name}';
  }

  final cameraState = read(cameraStateProvider);
  if (cameraState.connectionState == DeviceConnectionState.connected &&
      cameraState.isExposing) {
    return 'the camera is exposing';
  }

  final mountState = read(mountStateProvider);
  if (mountState.connectionState == DeviceConnectionState.connected &&
      mountState.isSlewing) {
    return 'the mount is slewing';
  }

  return null;
}

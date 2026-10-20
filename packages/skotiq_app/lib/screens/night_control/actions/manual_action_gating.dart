// Which action-bar buttons Tonight shows, and why each one is disabled.
//
// One pure function over a snapshot of the rig, so the button list
// (`nightManualActionsProvider`) and the controller's own refusal check
// can never disagree about whether an action may run.
import 'package:flutter/foundation.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../night_control_contracts.dart';

/// The rig facts the action bar depends on.
@immutable
class NightActionInputs {
  const NightActionInputs({
    required this.canCommand,
    required this.runState,
    required this.action,
    this.loopActive = false,
    this.cameraConnected = false,
    this.mountConnected = false,
    this.focuserConnected = false,
    this.guiderConnected = false,
    this.isGuiding = false,
    this.mountParked = false,
    this.mountTracking = false,
    this.cameraCooling = false,
    this.coolerSetpoint,
    this.targetName,
    this.hasTarget = false,
    this.hasFrame = false,
    this.exposureSeconds,
    this.filterName,
  });

  /// `backendCanCommandProvider`: false for a disconnected backend or a
  /// remote viewer whose host is unreachable.
  final bool canCommand;
  final SequenceExecutionState runState;
  final ManualActionState action;

  /// A manual loop runs (held by this controller).
  final bool loopActive;

  final bool cameraConnected;
  final bool mountConnected;
  final bool focuserConnected;
  final bool guiderConnected;
  final bool isGuiding;
  final bool mountParked;
  final bool mountTracking;
  final bool cameraCooling;

  /// The profile's (or plan's) cooler setpoint; null when neither has one.
  final double? coolerSetpoint;

  final String? targetName;
  final bool hasTarget;

  /// A saved frame is on screen, so there is a file to solve.
  final bool hasFrame;

  /// Manual exposure length, for the Snapshot sub-label.
  final double? exposureSeconds;

  /// The filter in the light path, for the Autofocus sub-label.
  final String? filterName;

  /// A run is loaded into the executor (anything but a settled state).
  bool get runActive => runState.isBusy;

  /// A run whose pause or resume this screen can drive.
  bool get runPausable =>
      runState == SequenceExecutionState.running ||
      runState == SequenceExecutionState.paused;
}

/// The buttons shown for [inputs], in board order.
///
/// Tracking and Cooler belong to the Ready board; Dither and Flip appear only
/// while a run is loaded.
List<ManualActionId> visibleManualActions(NightActionInputs inputs) =>
    inputs.runActive
        ? const [
            ManualActionId.snapshot,
            ManualActionId.loop,
            ManualActionId.autofocus,
            ManualActionId.solveSync,
            ManualActionId.center,
            ManualActionId.dither,
            ManualActionId.flip,
          ]
        : const [
            ManualActionId.snapshot,
            ManualActionId.loop,
            ManualActionId.autofocus,
            ManualActionId.solveSync,
            ManualActionId.center,
            ManualActionId.tracking,
            ManualActionId.cooler,
          ];

/// Why [id] cannot run now, or null when it can.
///
/// The action in flight is never disabled: pressing it again joins it (or,
/// for Loop, stops the loop).
NightText? manualActionDisabledReason(
  NightActionInputs inputs,
  ManualActionId id,
) {
  if (!inputs.canCommand) return const NightText('nightActWhyNoHost');

  final action = inputs.action;
  if (action.isBusy) {
    if (action.active == id) return null;
    final active = action.active;
    return active == null
        ? const NightText('nightActWhyBusy')
        : NightText(manualActionKey('nightActBusy', active));
  }

  // A solve reads a file and pauses nothing, so the run's state is no
  // reason to refuse it.
  if (id == ManualActionId.solve) {
    return inputs.hasFrame ? null : const NightText('nightScopeWhyNoFrame');
  }

  if (inputs.runActive && !inputs.runPausable) {
    return const NightText('nightActWhyRunSettling');
  }

  const noCamera = NightText('nightActWhyNoCamera');
  const noMount = NightText('nightActWhyNoMount');
  const parked = NightText('nightActWhyParked');

  switch (id) {
    case ManualActionId.snapshot:
    case ManualActionId.loop:
      return inputs.cameraConnected ? null : noCamera;
    case ManualActionId.autofocus:
      if (!inputs.cameraConnected) return noCamera;
      if (!inputs.focuserConnected) {
        return const NightText('nightActWhyNoFocuser');
      }
      return null;
    case ManualActionId.solve:
      return null;
    case ManualActionId.solveSync:
      if (!inputs.cameraConnected) return noCamera;
      if (!inputs.mountConnected) return noMount;
      if (inputs.mountParked) return parked;
      return null;
    case ManualActionId.center:
      if (!inputs.cameraConnected) return noCamera;
      if (!inputs.mountConnected) return noMount;
      if (inputs.mountParked) return parked;
      if (!inputs.hasTarget) return const NightText('nightActWhyNoTarget');
      return null;
    case ManualActionId.dither:
      if (!inputs.guiderConnected) {
        return const NightText('nightActWhyNoGuider');
      }
      if (!inputs.isGuiding) return const NightText('nightActWhyNotGuiding');
      return null;
    case ManualActionId.flip:
      // Native refuses a standalone flip while the executor runs or is
      // paused; the run's meridian trigger owns flips (plan finding 5).
      if (inputs.runActive) return const NightText('nightActWhyFlipRun');
      if (!inputs.mountConnected) return noMount;
      if (inputs.mountParked) return parked;
      if (!inputs.mountTracking) {
        return const NightText('nightActWhyNotTracking');
      }
      return null;
    case ManualActionId.tracking:
      if (inputs.runActive) return const NightText('nightActWhyRunOwns');
      if (!inputs.mountConnected) return noMount;
      if (inputs.mountParked) return parked;
      return null;
    case ManualActionId.cooler:
      if (inputs.runActive) return const NightText('nightActWhyRunOwns');
      if (!inputs.cameraConnected) return noCamera;
      if (!inputs.cameraCooling && inputs.coolerSetpoint == null) {
        return const NightText('nightActWhyNoSetpoint');
      }
      return null;
  }
}

/// The view model for one button.
ManualActionVm manualActionVm(NightActionInputs inputs, ManualActionId id) {
  final reason = manualActionDisabledReason(inputs, id);
  final action = inputs.action;
  final inFlight = action.isBusy && action.active == id;
  return ManualActionVm(
    id: id,
    label: _label(inputs, id),
    sub: inFlight ? _inFlightSub(action) : _sub(inputs, id),
    enabled: reason == null,
    disabledReason: reason,
    running: inFlight,
  );
}

NightText _label(NightActionInputs inputs, ManualActionId id) => switch (id) {
      ManualActionId.snapshot => const NightText('nightActSnapshot'),
      ManualActionId.loop => inputs.loopActive
          ? const NightText('nightActStopLoop')
          : const NightText('nightActLoop'),
      ManualActionId.autofocus => const NightText('nightActAutofocus'),
      ManualActionId.solve => const NightText('nightScopeSolveSolve'),
      ManualActionId.solveSync => const NightText('nightActSolveSync'),
      ManualActionId.center => const NightText('nightActCenter'),
      ManualActionId.dither => const NightText('nightActDither'),
      ManualActionId.flip => const NightText('nightActFlip'),
      ManualActionId.tracking => inputs.mountTracking
          ? const NightText('nightActTrackOff')
          : const NightText('nightActTrack'),
      ManualActionId.cooler => inputs.cameraCooling
          ? const NightText('nightActCoolerOff')
          : const NightText('nightActCooler'),
    };

NightText _inFlightSub(ManualActionState action) => switch (action.phase) {
      ManualActionPhase.pausingRun ||
      ManualActionPhase.waitingForFrame =>
        const NightText('nightActSubWaiting'),
      ManualActionPhase.resuming => const NightText('nightActSubResuming'),
      ManualActionPhase.running ||
      ManualActionPhase.idle =>
        const NightText('nightActSubRunning'),
    };

NightText? _sub(NightActionInputs inputs, ManualActionId id) {
  switch (id) {
    case ManualActionId.snapshot:
      final seconds = inputs.exposureSeconds;
      if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
      return NightText.literal(formatExposureSeconds(seconds));
    case ManualActionId.autofocus:
      final filter = inputs.filterName;
      return filter == null || filter.isEmpty
          ? null
          : NightText.literal(filter);
    case ManualActionId.center:
      final name = inputs.targetName;
      return name == null || name.isEmpty ? null : NightText.literal(name);
    case ManualActionId.tracking:
      return inputs.mountTracking
          ? const NightText('nightActSubTracking')
          : const NightText('nightActSubSidereal');
    case ManualActionId.cooler:
      final setpoint = inputs.coolerSetpoint;
      return setpoint == null
          ? null
          : NightText.literal(formatCelsius(setpoint, decimals: 0));
    case ManualActionId.loop:
    case ManualActionId.solve:
    case ManualActionId.solveSync:
    case ManualActionId.dither:
    case ManualActionId.flip:
      return null;
  }
}

/// `nightActBusyAutofocus` from `nightActBusy` and [ManualActionId.autofocus].
String manualActionKey(String prefix, ManualActionId id) =>
    '$prefix${id.name[0].toUpperCase()}${id.name.substring(1)}';

/// `5 s`, `0.5 s`, `180 s`.
String formatExposureSeconds(double seconds) {
  final whole = seconds == seconds.roundToDouble();
  return whole ? '${seconds.toInt()} s' : '${seconds.toStringAsFixed(1)} s';
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/equipment/equipment_models.dart';
import '../../models/sequence/sequence_models.dart';
import '../autofocus_progress_provider.dart';
import '../sequence/sequence_progress.dart';
import '../settings_provider.dart';
import 'focus_compensation_rule.dart';
import 'focuser_state_provider.dart';
import 'focuser_temperature_poller.dart';
import '../../settings/app_settings_state.g.dart';
import '../device_service_providers.dart';
import '../logging_service_provider.dart';

/// Applies the operator's temperature coefficient (steps per °C, set in
/// Equipment → Settings → Focuser) continuously while the focuser is
/// connected and no sequence is running.
///
/// During a run the executor compensates instead, before each light frame,
/// with these same settings (the plan carries them, see
/// `SequenceSerializer`), and from its own reference. This provider stands
/// down whenever the sequencer is executing (running / paused / stopping /
/// recovering): two controllers would move the focuser off the same drift,
/// and only the executor knows when no frame is exposing.
///
/// What a reading calls for is [FocusCompensationRule], the mirror of the
/// executor's rule; this class only decides when a reading may be acted on
/// and makes the move.
final focuserTempCompensationProvider = Provider<FocuserTempCompensator>((ref) {
  // Compensation follows the focuser's temperature, which only the poller
  // keeps current on the machine that owns the rig.
  ref.watch(focuserTemperaturePollerProvider);
  final compensator = FocuserTempCompensator(ref);
  ref.onDispose(compensator.dispose);
  return compensator;
});

/// The rule's state while the app compensates out of a run, shared with the
/// filter change that applies a focus offset (see
/// `DeviceService._applyFilterFocusOffset`).
final idleFocusCompensationProvider = Provider<IdleFocusCompensation>(
  (_) => IdleFocusCompensation(),
);

class IdleFocusCompensation {
  final FocusCompensationRule rule = FocusCompensationRule();

  /// A filter's focus offset is moving the focuser. Readings taken meanwhile
  /// are part of that move and are not judged.
  bool get offsetMoveInFlight => _offsetMoveInFlight;
  bool _offsetMoveInFlight = false;

  void beginOffsetMove() {
    _offsetMoveInFlight = true;
  }

  /// The offset move ended having moved the focuser [appliedSteps] (0 when
  /// it failed). An applied offset is not a new focus to hold: the reference
  /// moves with it and the correction owed so far is kept.
  void endOffsetMove({required int appliedSteps}) {
    if (appliedSteps != 0) rule.shiftedBy(appliedSteps);
    _offsetMoveInFlight = false;
  }
}

/// The reference compensation measures from, for display: the temperature
/// and position when it started, or when something else last moved the
/// focuser.
final focuserTempCompensationBaselineProvider =
    StateProvider<FocuserTempCompensationBaseline?>((_) => null);

class FocuserTempCompensationBaseline {
  final double temperature;
  final int position;
  final DateTime capturedAt;

  const FocuserTempCompensationBaseline({
    required this.temperature,
    required this.position,
    required this.capturedAt,
  });
}

class FocuserTempCompensator {
  final Ref _ref;
  ProviderSubscription<FocuserState>? _focuserSub;
  ProviderSubscription<AsyncValue<AppSettingsState>>? _settingsSub;
  bool _moveInFlight = false;

  FocuserTempCompensator(this._ref) {
    _focuserSub = _ref.listen<FocuserState>(
      focuserStateProvider,
      _onFocuserChanged,
      fireImmediately: false,
    );
    _settingsSub = _ref.listen<AsyncValue<AppSettingsState>>(
      appSettingsProvider,
      _onSettingsChanged,
      fireImmediately: false,
    );
  }

  void dispose() {
    _focuserSub?.close();
    _settingsSub?.close();
  }

  void _onSettingsChanged(
    AsyncValue<AppSettingsState>? previous,
    AsyncValue<AppSettingsState> next,
  ) {
    // When the user disables compensation, drop the baseline so a re-enable
    // captures a fresh reference instead of acting on stale data.
    final settings = next.valueOrNull;
    if (settings == null || !settings.tempCompensation) {
      _clearBaseline();
    }
  }

  IdleFocusCompensation get _idle => _ref.read(idleFocusCompensationProvider);
  FocusCompensationRule get _rule => _idle.rule;

  void _clearBaseline() {
    _rule.forgetReference();
    _publishReference();
  }

  /// Show the rule's reference where the focus panel reads it.
  void _publishReference() {
    final reference = _rule.reference;
    final shown = _ref.read(focuserTempCompensationBaselineProvider);
    if (reference == null) {
      if (shown != null) {
        _ref.read(focuserTempCompensationBaselineProvider.notifier).state =
            null;
      }
      return;
    }
    if (shown != null &&
        shown.temperature == reference.temperature &&
        shown.position == reference.position) {
      return;
    }
    _ref
        .read(focuserTempCompensationBaselineProvider.notifier)
        .state = FocuserTempCompensationBaseline(
      temperature: reference.temperature,
      position: reference.position,
      capturedAt: reference.takenAt,
    );
  }

  /// Whether the sequencer is actively executing. While it is, the executor
  /// owns focuser drift correction; this continuous provider must not also
  /// issue moves (double-compensation).
  bool get _sequenceActive {
    switch (_ref.read(sequenceExecutionStateProvider)) {
      case SequenceExecutionState.running:
      case SequenceExecutionState.paused:
      case SequenceExecutionState.stopping:
      case SequenceExecutionState.recovering:
        return true;
      case SequenceExecutionState.idle:
      case SequenceExecutionState.completed:
      case SequenceExecutionState.failed:
        return false;
      // A failed native stop means the hardware was NOT confirmed stopped, so
      // the executor may still be compensating — treat it as active. A
      // pending persistence cleanup
      // (cleanupFailed) or in-flight finalization both mean the hardware IS
      // stopped, so Dart-side compensation may resume.
      case SequenceExecutionState.stopFailed:
        return true;
      case SequenceExecutionState.cleanupFailed:
      case SequenceExecutionState.finalizing:
        return false;
    }
  }

  void _onFocuserChanged(FocuserState? previous, FocuserState next) {
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    if (settings == null || !settings.tempCompensation) {
      return;
    }
    if (_sequenceActive) {
      // The executor compensates while a sequence runs. The reference is
      // kept: if the run moved the focuser, the first reading after it reads
      // as a move this compensator did not make and becomes the new
      // reference.
      return;
    }
    if (next.connectionState != DeviceConnectionState.connected) {
      _clearBaseline();
      return;
    }
    if (_moveInFlight ||
        next.isMoving ||
        _idle.offsetMoveInFlight ||
        _ref.read(deviceServiceProvider).isAutofocusRunning ||
        // A sweep started elsewhere (the REST API, a linked client) does not
        // go through this window's device service; its progress events do
        // reach the panel. Moving the focuser mid-sweep puts a point's frame
        // at the wrong position.
        _ref.read(autofocusOverlayProvider).isRunning) {
      // Re-evaluate when the focuser reports idle; moving is not a fault.
      return;
    }
    final temperature = next.temperature;
    final position = next.position;
    if (temperature == null || position == null) {
      return;
    }

    final step = _rule.step(
      stepsPerDegree: settings.tempCoefficient,
      minSteps: settings.tempCompensationMinSteps,
      temperature: temperature,
      position: position,
    );
    _publishReference();
    switch (step) {
      case TakeReference(movedFrom: final movedFrom):
        if (movedFrom != null) {
          // Something else moved the focuser: an autofocus or a jog. That is
          // the new focus to hold, not drift to undo.
          _ref
              .read(loggingServiceProvider)
              .info(
                'Temp compensation took a new reference at $position '
                '(${temperature.toStringAsFixed(2)}C): the focuser was moved '
                'from $movedFrom',
                source: 'FocuserTempCompensator',
              );
        }
      case Hold():
        break;
      case Refuse(target: final target):
        // Refuse impossible commands rather than silently clamping.
        _ref
            .read(loggingServiceProvider)
            .warning(
              'Temp compensation computed negative target position '
              '($target); skipping move.',
              source: 'FocuserTempCompensator',
            );
      case Move(target: final target):
        unawaited(_applyMove(target, temperature));
    }
  }

  Future<void> _applyMove(int targetPosition, double temperature) async {
    _moveInFlight = true;
    final logger = _ref.read(loggingServiceProvider);
    try {
      final deviceService = _ref.read(deviceServiceProvider);
      if (deviceService.isAutofocusRunning) {
        logger.info(
          'Temp compensation skipped while autofocus is running.',
          source: 'FocuserTempCompensator',
        );
        return;
      }
      await deviceService.moveFocuserTo(targetPosition);
      _rule.movedTo(targetPosition);
      logger.info(
        'Temp compensation moved focuser to $targetPosition '
        '(${temperature.toStringAsFixed(2)}C)',
        source: 'FocuserTempCompensator',
      );
    } catch (e, st) {
      // Fail loud — silent fallbacks here would hide a focuser issue from
      // the operator. Errors propagate via the logging service and the
      // reference is left untouched so the next temperature update can
      // retry.
      logger.error(
        'Temp compensation move failed: $e',
        source: 'FocuserTempCompensator',
        fields: {'stack': st.toString()},
      );
    } finally {
      _moveInFlight = false;
    }
  }
}

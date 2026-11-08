import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/equipment/equipment_models.dart';
import '../../models/sequence/sequence_models.dart';
import '../../services/device_service.dart';
import '../../services/logging_service.dart';
import '../autofocus_progress_provider.dart';
import '../sequence/sequence_progress.dart';
import '../settings_provider.dart';
import 'focuser_state_provider.dart';
import 'focuser_temperature_poller.dart';

/// Applies the operator's temperature coefficient (steps per °C, set in
/// Equipment → Settings → Focuser) continuously while the focuser is
/// connected and no sequence is running.
///
/// Sign convention MUST match the executor-authoritative Rust
/// `execute_temperature_compensation` in
/// `native/skotiq_native/sequencer/src/temperature_compensation.rs`,
/// which computes
/// `new_position = current_position + (temp_now - baseline) * coefficient`.
/// This provider uses that identical formula
/// (`target = baseline_position + delta`); a sign flip here makes the two
/// compensators drive the focuser in opposite directions.
///
/// The Rust `temperature_compensation` instruction is the in-sequence
/// authority, so this provider stands down whenever the sequencer is
/// executing (running / paused / stopping / recovering). Otherwise two
/// controllers would issue focuser moves off the same drift.
///
/// The reference (temperature, position) stays fixed while compensation
/// works, and a move happens only once the correction owed reaches the
/// operator's smallest move (`tempCompensationMinSteps`, default 5). It
/// used to re-take the reference after every move and act on any rounded
/// step: with a 0.1 °C probe and -12 steps/°C that stepped the focuser by one
/// every reading, and each rounding was thrown away, so 0.05 °C readings
/// drove 20 steps/°C instead of 12. A move this compensator did not make
/// (a jog, an autofocus) re-takes the reference instead of being undone.
final focuserTempCompensationProvider = Provider<FocuserTempCompensator>((ref) {
  // Compensation follows the focuser's temperature, which only the poller
  // keeps current on the machine that owns the rig.
  ref.watch(focuserTemperaturePollerProvider);
  final compensator = FocuserTempCompensator(ref);
  ref.onDispose(compensator.dispose);
  return compensator;
});

/// The reference compensation measures from: the temperature and position
/// when it started, or when something else last moved the focuser.
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

  /// Where this compensator last put the focuser, or the reference position.
  /// The focuser reading anywhere else means something else moved it.
  int? _expectedPosition;

  /// A focuser may report a step or two off a commanded target.
  static const int _arrivalTolerance = 2;

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

  void _clearBaseline() {
    _ref.read(focuserTempCompensationBaselineProvider.notifier).state = null;
    _expectedPosition = null;
  }

  void _takeBaseline(double temperature, int position) {
    _ref
        .read(focuserTempCompensationBaselineProvider.notifier)
        .state = FocuserTempCompensationBaseline(
      temperature: temperature,
      position: position,
      capturedAt: DateTime.now(),
    );
    _expectedPosition = position;
  }

  /// Whether the sequencer is actively executing. While it is, the Rust
  /// `temperature_compensation` instruction owns focuser drift correction;
  /// this continuous provider must not also issue moves (double-compensation).
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
      // the Rust temperature-compensation instruction may still own the
      // focuser — treat it as active. A pending persistence cleanup
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
      // The Rust temperature_compensation instruction is authoritative while
      // a sequence runs. Skip Dart-side compensation to avoid two controllers
      // fighting over the focuser. We deliberately keep the baseline so that
      // when the sequence ends, the next temperature tick resumes from the
      // correct reference rather than re-capturing mid-drift.
      return;
    }
    if (next.connectionState != DeviceConnectionState.connected) {
      _clearBaseline();
      return;
    }
    if (_moveInFlight ||
        next.isMoving ||
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

    final baselineHolder = _ref.read(
      focuserTempCompensationBaselineProvider.notifier,
    );
    final baseline = baselineHolder.state;
    if (baseline == null) {
      _takeBaseline(temperature, position);
      return;
    }
    final expected = _expectedPosition ?? baseline.position;
    if ((position - expected).abs() > _arrivalTolerance) {
      // Something else moved the focuser: an autofocus, a jog, a filter
      // offset. That is the new focus to hold, not drift to undo.
      _ref
          .read(loggingServiceProvider)
          .info(
            'Temp compensation took a new reference at $position '
            '(${temperature.toStringAsFixed(2)}C): the focuser was moved '
            'from $expected',
            source: 'FocuserTempCompensator',
          );
      _takeBaseline(temperature, position);
      return;
    }

    final coefficient = settings.tempCoefficient;
    if (coefficient == 0) {
      // Why: a zero coefficient is a valid "track temperature but do not
      // act" state. The user gets the temperature display without any
      // movement.
      return;
    }

    final deltaTemp = temperature - baseline.temperature;
    final deltaSteps = (deltaTemp * coefficient).round();
    // The correction owed is measured against where the focuser is, so the
    // fractions this skips are not lost: they add up until they are worth a
    // move.
    final owed = baseline.position + deltaSteps - position;
    if (owed.abs() < settings.tempCompensationMinSteps.clamp(1, 10000)) {
      return;
    }
    // Sign convention matches the Rust executor exactly:
    // `new = baseline + (temp_now - baseline_temp) * coefficient`. With the
    // default negative coefficient, a temperature drop yields a positive
    // delta and moves the focuser outward. Do NOT flip this sign — the Rust
    // `temperature_compensation` instruction adds the same delta, and any
    // disagreement makes the two compensators drive the focuser in opposite
    // directions.
    final targetPosition = baseline.position + deltaSteps;
    if (targetPosition < 0) {
      // Refuse impossible commands rather than silently clamping.
      _ref
          .read(loggingServiceProvider)
          .warning(
            'Temp compensation computed negative target position '
            '($targetPosition); skipping move.',
            source: 'FocuserTempCompensator',
          );
      return;
    }

    unawaited(_applyMove(targetPosition, temperature));
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
      // The reference stays where it is; only where the focuser should be
      // now changes.
      _expectedPosition = targetPosition;
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

// What the Focus tab shows, gathered in one provider so a widget test pins
// it with a plain value.
//
// The V-curve is the autofocus overlay's, so a run the sequencer started
// draws here as well as one the operator started. The fit quality and the
// fitted minimum exist only once a run finishes. Recent runs are this
// session's: nothing older survives an app restart.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../actions/night_action_controller.dart';
import '../../data/plan/night_run_phase_provider.dart';
import '../../data/session/session_events_provider.dart';
import '../../night_control_contracts.dart';

enum NightAutofocusStatus { idle, running, done, failed }

/// The temperature compensation the operator turned on (Equipment →
/// Settings → Focuser): steps per °C and what moved since its reference.
@immutable
class NightTempCompVm {
  const NightTempCompVm({
    required this.coefficient,
    this.referenceTemp,
    this.movedSince,
  });

  /// Steps per °C.
  final double coefficient;

  /// The temperature the compensation measures from; null until it took
  /// one.
  final double? referenceTemp;

  /// Steps the focuser moved since that reference.
  final int? movedSince;
}

@immutable
class NightFocusPanelVm {
  const NightFocusPanelVm({
    required this.canCommand,
    required this.runLive,
    required this.status,
    required this.focuserConnected,
    this.point,
    this.totalPoints,
    this.points = const <VCurvePoint>[],
    this.starCounts,
    this.bestPosition,
    this.bestHfr,
    this.fitQuality,
    this.focusRange,
    this.startedHere = false,
    this.focuserName,
    this.position,
    this.maxPosition,
    this.focuserTemp,
    this.focuserMoving = false,
    this.tempComp,
    this.recentRuns = const <NightAutofocusRun>[],
  });

  final bool canCommand;
  final bool runLive;
  final NightAutofocusStatus status;

  /// "point 6 of 9" while running.
  final int? point;
  final int? totalPoints;

  /// The current or last run's samples, in the order measured.
  final List<VCurvePoint> points;

  /// Stars per point, index for index with [points]; null while the
  /// progress events carry only the current point's count.
  // P9: per-point star counts (native item N3) fill this; the table's stars
  // column appears as soon as it is non-null.
  final List<int?>? starCounts;

  /// The finished run's result.
  final int? bestPosition;
  final double? bestHfr;

  /// The finished run's curve fit, 0 to 1.
  final double? fitQuality;
  final FocusRange? focusRange;

  /// The action bar started the running autofocus, so Cancel goes through
  /// the action controller, which resumes the run it paused.
  final bool startedHere;

  final bool focuserConnected;
  final String? focuserName;
  final int? position;
  final int? maxPosition;
  final double? focuserTemp;
  final bool focuserMoving;

  /// Null hides the block: compensation is off.
  final NightTempCompVm? tempComp;

  /// Newest first.
  final List<NightAutofocusRun> recentRuns;
}

final nightFocusPanelProvider = Provider<NightFocusPanelVm>((ref) {
  final overlay = ref.watch(autofocusOverlayProvider);
  final focuser = ref.watch(focuserStateProvider);
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  final baseline = ref.watch(focuserTempCompensationBaselineProvider);
  final action = ref.watch(nightActionStateProvider);
  final runs = ref.watch(
    nightSessionEventsProvider.select((events) => events.autofocusRuns),
  );
  final connected = focuser.connectionState == DeviceConnectionState.connected;
  final result = overlay.result;

  final status = overlay.isRunning
      ? NightAutofocusStatus.running
      : overlay.hasError
          ? NightAutofocusStatus.failed
          : result != null
              ? NightAutofocusStatus.done
              : NightAutofocusStatus.idle;

  final position = connected ? focuser.position : null;
  final tempComp = settings != null && settings.tempCompensation
      ? NightTempCompVm(
          coefficient: settings.tempCoefficient,
          referenceTemp: baseline?.temperature,
          movedSince: baseline != null && position != null
              ? position - baseline.position
              : null,
        )
      : null;

  return NightFocusPanelVm(
    canCommand: ref.watch(backendCanCommandProvider),
    runLive: ref.watch(nightRunPhaseProvider).isRunLive,
    status: status,
    point: overlay.isRunning && overlay.currentPoint > 0
        ? overlay.currentPoint
        : null,
    totalPoints: overlay.isRunning && overlay.totalPoints > 0
        ? overlay.totalPoints
        : null,
    points: overlay.vcurvePoints,
    bestPosition:
        status == NightAutofocusStatus.done ? result?.bestPosition : null,
    bestHfr: status == NightAutofocusStatus.done ? result?.bestHfr : null,
    fitQuality: status == NightAutofocusStatus.done &&
            result != null &&
            result.curveFitQuality > 0
        ? result.curveFitQuality
        : null,
    focusRange: overlay.focusRange,
    startedHere: overlay.isRunning && action.active == ManualActionId.autofocus,
    focuserConnected: connected,
    focuserName: focuser.deviceName,
    position: position,
    maxPosition: connected ? focuser.maxPosition : null,
    focuserTemp:
        connected && focuser.hasTemperature ? focuser.temperature : null,
    focuserMoving: connected && focuser.isMoving,
    tempComp: tempComp,
    recentRuns: runs.reversed.toList(growable: false),
  );
});

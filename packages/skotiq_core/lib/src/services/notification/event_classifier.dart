// Single source of truth: backend event -> NotificationCategory.
//
// Before this file existed, the same "which NotificationCategory does this
// raw event belong to" logic was hand-written THREE times with subtly
// different coverage:
//
//   * NotificationRouter._categoryForEvent / _classify*Event
//   * PushNotificationService._eventToNotification / _handle*Event
//   * (bridge-typed) run_dashboard isCriticalEvent / _toDashboardEvent
//
// The first two operated on the core [SkotiqEvent] (string `eventType`
// + `data` map). They are unified here as the ONE classifier.
//
// Architecture-unification, Subsystem 3 (collapsed): the mobile-push feed no
// longer classifies at all — [PushNotificationService] is now a pure
// broadcaster and the [NotificationRouter] is the single producer of every
// transport (in-app, mobile push, and the external ones). The router is the
// sole caller of this classifier; the per-category mobile-push toggle now
// lives in [SystemPushTransport] keyed off the SAME category this classifier
// assigns, so a routing rule and a push toggle can never disagree about what
// an event *is*.
//
// The dashboard bridge runs on the freezed bridge-union event (a different
// representation that carries richer typed payloads) and stays in its own
// file; it forwards only the criticals this classifier does NOT route (e.g.
// generic system errors) into the router, and derives criticality from
// [NotificationCategory.isCritical] via the shared matrix so the two never
// drift on *which* events are critical.
//
// This classifier is intentionally pure and side-effect free.

import 'dart:developer' as developer;

import '../../backend/bridge_event_codec.dart';
import '../../backend/bridge_events.dart' as typed;
import '../../models/backend/event_types.dart';
import '../../errors/error_text.dart';
import '../../models/notification/notification_categories.dart';
import '../../models/sequence/run_stop_classification.dart';
import '../../utils/device_id.dart';
import 'notification_template.dart';

/// The devices the native side has said it is connecting and has not yet
/// reported connected.
///
/// The native side publishes the same `Error` event for a device that was
/// lost and for a connect that did not succeed; only the events before it
/// tell them apart (`Connecting`, then `Error`, is a failed connect). A
/// device never seen connecting is treated as one that was connected, so a
/// real loss is never taken for a failed connect.
class ConnectingDevices {
  final Set<String> _ids = <String>{};

  /// Record [event], and answer whether it is the `Error` of a connect that
  /// did not succeed (a first connect or a reconnect attempt).
  bool isFailedConnect(SkotiqEvent event) {
    final payload = typedEventFromWire(event)?.payload;
    if (payload is! typed.EventPayload_Equipment) return false;
    switch (payload.field0) {
      case typed.EquipmentEvent_Connecting(:final deviceId):
        if (deviceId.isNotEmpty) _ids.add(deviceId);
      case typed.EquipmentEvent_Connected(:final deviceId) ||
          typed.EquipmentEvent_Disconnected(:final deviceId):
        _ids.remove(deviceId);
      case typed.EquipmentEvent_Error(:final deviceId):
        return _ids.contains(deviceId);
      default:
    }
    return false;
  }
}

/// What a step problem's notice names as its source: the event carries the
/// problem as one sentence and no step name.
const String kStepProblemSource = 'Sequence';

/// The result of classifying a single backend event: the semantic
/// [NotificationCategory], the context key/value pairs the templates need,
/// and the event's [EventSeverity] (carried through unchanged, except for a
/// decision row that stands for a warning; see [classify]).
class ClassifiedNotification {
  final NotificationCategory category;

  /// Extra, classifier-derived context values (e.g. `target.name`). These
  /// win over the raw scalar fields the router folds in from `event.data`.
  final Map<String, String> context;

  /// The severity of the originating event, carried through verbatim so
  /// the router's min-severity gate and the push priority both see the
  /// same value the backend assigned.
  final EventSeverity severity;

  const ClassifiedNotification({
    required this.category,
    required this.context,
    required this.severity,
  });
}

/// Maps a core [SkotiqEvent] to its [NotificationCategory] (+ context),
/// or `null` when the event is not one the cross-platform notification
/// system surfaces (those events are consumed by dedicated UI surfaces).
///
/// This is the ONE classifier both [NotificationRouter] and
/// [PushNotificationService] call.
class NotificationEventClassifier {
  const NotificationEventClassifier._();

  /// The stop-authorship decision [event] carries, or `null` when it carries
  /// none. The executor's decision rows raise no notification of their own —
  /// they are the only thing on the wire that says WHOSE stop this was, which
  /// is what the router needs before it may tell the phone anything about it.
  static SequenceStopDecision? stopDecisionOf(SkotiqEvent event) {
    final payload = typedEventFromWire(event)?.payload;
    if (payload is! typed.EventPayload_Sequencer) return null;
    final decision = payload.field0;
    if (decision is! typed.SequencerEvent_DecisionLogged) return null;
    return sequenceStopDecision(
      category: decision.category,
      summary: decision.summary,
      detailsJson: decision.detailsJson,
    );
  }

  /// Classify [event]. Returns `null` for events that do not map to a
  /// routed category: the ones other surfaces show, and the job, session and
  /// catalog envelopes, which have no typed form.
  static ClassifiedNotification? classify(SkotiqEvent event) {
    final payload = typedEventFromWire(event)?.payload;
    if (payload == null) return null;
    final mapped = _categoryAndContext(payload);
    if (mapped == null) return null;
    // Decision rows are published at info whatever they record. The
    // reject-streak and problem-noticed rows stand for a warning, so they are
    // routed at their category's own level and clear its warning floor.
    final severity =
        mapped.$1 == NotificationCategory.problemNoticed ||
            (_isDecisionRow(payload) &&
                mapped.$1 == NotificationCategory.frameRejected)
        ? mapped.$1.defaultSeverity
        : event.severity;
    return ClassifiedNotification(
      category: mapped.$1,
      context: mapped.$2,
      severity: severity,
    );
  }

  static bool _isDecisionRow(typed.EventPayload payload) =>
      payload is typed.EventPayload_Sequencer &&
      payload.field0 is typed.SequencerEvent_DecisionLogged;

  static const Map<String, String> _none = <String, String>{};

  static (NotificationCategory, Map<String, String>)? _categoryAndContext(
    typed.EventPayload payload,
  ) => switch (payload) {
    typed.EventPayload_Sequencer(:final field0) => _classifySequencer(field0),
    typed.EventPayload_Imaging(:final field0) => _classifyImaging(field0),
    typed.EventPayload_Guiding(:final field0) => _classifyGuiding(field0),
    typed.EventPayload_Safety(:final field0) => _classifySafety(field0),
    typed.EventPayload_Equipment(:final field0) => _classifyEquipment(field0),
    typed.EventPayload_System(:final field0) => _classifySystem(field0),
    // Shown by their own surfaces (the polar alignment screen, the Smart
    // Exposure goal card).
    typed.EventPayload_PolarAlignment() ||
    typed.EventPayload_PolarAlignmentStatus() ||
    typed.EventPayload_PolarAlignmentImage() ||
    typed.EventPayload_DepthLock() => null,
  };

  /// Context for a failure notification: why the run failed, as a sentence.
  static Map<String, String> _failureContext(String reason) {
    if (isUnexplainedRunFailure(reason)) {
      return const {kFailureReasonContextKey: kUnexplainedFailureReason};
    }
    final text = userFacingError(reason.trim());
    return {
      kFailureReasonContextKey: RegExp(r'[.!?]$').hasMatch(text)
          ? text
          : '$text.',
    };
  }

  /// Context for a stop notification: the run it ended, when the event
  /// carries it. Run identity is what keeps two runs' stops from folding into
  /// one episode (and one run's stop from splitting into two) in
  /// [StopPushArbiter], however long the safing teardown stretched them.
  static Map<String, String> _stopContext(int? runId) =>
      runId == null ? <String, String>{} : {kStopRunIdContextKey: '$runId'};

  static (NotificationCategory, Map<String, String>)? _classifySequencer(
    typed.SequencerEvent event,
  ) {
    switch (event) {
      case typed.SequencerEvent_Started():
        return (NotificationCategory.sequenceStarted, _none);
      case typed.SequencerEvent_Completed():
        return (NotificationCategory.sequenceCompleted, _none);
      case typed.SequencerEvent_Stopped(:final sequenceRunId):
        return (
          NotificationCategory.sequenceStopped,
          _stopContext(sequenceRunId),
        );
      case typed.SequencerEvent_Error(:final message, :final kind):
        // A cancelled run reaches Dart as a sequencer Error carrying the
        // notice "Sequence cancelled" (the `Stopped` lifecycle event arrives
        // separately). Only the exact notice is reclassified; see
        // [isSequenceCancelledNotice] for why the match is not a substring.
        if (isSequenceCancelledNotice(message)) {
          developer.log(
            '[$kStopClassificationLogTag] event_classifier: sequencer Error '
            'carrying the cancellation notice -> sequenceStopped',
            name: 'NotificationEventClassifier',
          );
          return (NotificationCategory.sequenceStopped, _stopContext(null));
        }
        // The host says what the error means for the run. Only a problem the
        // run carried on through is a notice of its own: a note belongs to
        // the run's warnings, a pause is told by `Paused`, and a failed step
        // is told by the run's end below, once, if the run does end.
        if (kind != typed.SequencerErrorKind.stepProblem) return null;
        return (
          NotificationCategory.problemNoticed,
          <String, String>{
            'problem.source': kStepProblemSource,
            'problem.message': message,
          },
        );
      // The run's end, and the only event that says a run failed. Its reason
      // is the first fault the run did not survive.
      case typed.SequencerEvent_Failed(:final error):
        return (NotificationCategory.sequenceFailed, _failureContext(error));
      // A happening the run carried on through, told once from its decision
      // row; the run never stops for these. Stop-authorship decisions are
      // consumed by [stopDecisionOf], not classified here.
      case typed.SequencerEvent_DecisionLogged(:final notice):
        return switch (notice) {
          // An autofocus that did not converge: the run continues on the
          // restored focus and the phone gets an INFO, not an alarm.
          typed.SequencerNotice_AutofocusContinued() => (
            NotificationCategory.autofocusContinued,
            _none,
          ),
          // A streak of rejected frames reached the operator's limit; told
          // once per streak.
          typed.SequencerNotice_RejectStreak(
            :final consecutiveRejects,
            :final reason,
          ) =>
            (
              NotificationCategory.frameRejected,
              <String, String>{
                'frame.streak': consecutiveRejects > 0
                    ? '$consecutiveRejects'
                    : '',
                'frame.reason': reason,
              },
            ),
          // A quality problem the operator has not asked to stop the run for.
          typed.SequencerNotice_ProblemNoticed(:final source, :final problem) =>
            (
              NotificationCategory.problemNoticed,
              <String, String>{
                'problem.source': source,
                'problem.message': problem,
              },
            ),
          null => null,
        };
      case typed.SequencerEvent_Paused():
        return (NotificationCategory.sequencePaused, _none);
      case typed.SequencerEvent_Resumed():
        return (NotificationCategory.sequenceResumed, _none);
      case typed.SequencerEvent_TargetCompleted(:final targetName):
        return (
          NotificationCategory.targetCompleted,
          <String, String>{'target.name': targetName, 'target.id': ''},
        );
      case typed.SequencerEvent_InstructionProgress(:final instruction):
        if (instruction.toLowerCase().contains('meridian')) {
          return (NotificationCategory.meridianFlipPerformed, _none);
        }
        return null;
      case typed.SequencerEvent_TriggerFired(
        :final action,
        :final triggerName,
      ):
        // A trigger whose action is to carry on (a filter change in a rotating
        // Smart Exposure fires one every frame) changed nothing; notifying it
        // buried the real alerts on a linked client.
        if (action.trim().toLowerCase() == 'continue') return null;
        return (
          NotificationCategory.triggerFired,
          <String, String>{'trigger.name': triggerName},
        );
      case typed.SequencerEvent_RecoveryStarted():
        return (NotificationCategory.recoveryStarted, _none);
      case typed.SequencerEvent_RecoveryGaveUp():
        return (NotificationCategory.recoveryGaveUp, _none);
      // One rejected frame is not news: the run dashboard and the reject
      // folder carry every one. The operator hears about a streak, once, from
      // the reject-streak decision row above.
      case typed.SequencerEvent_FrameRejected():
      // Shown by the run's own surfaces (progress, plan, scheduler, science).
      case typed.SequencerEvent_NodeStarted() ||
          typed.SequencerEvent_NodeCompleted() ||
          typed.SequencerEvent_Progress() ||
          typed.SequencerEvent_TargetChanged() ||
          typed.SequencerEvent_ExposureStarted() ||
          typed.SequencerEvent_ExposureCompleted() ||
          typed.SequencerEvent_MeridianFlipOutcome() ||
          typed.SequencerEvent_InstructionProgressStructured() ||
          typed.SequencerEvent_DepthGoalCompleted() ||
          typed.SequencerEvent_FrameAccepted() ||
          typed.SequencerEvent_SchedulerDecision() ||
          typed.SequencerEvent_IntegrationBudget() ||
          typed.SequencerEvent_ExposureAdjusted() ||
          typed.SequencerEvent_PhotometryFrame() ||
          typed.SequencerEvent_PhotometryCadenceBroken() ||
          typed.SequencerEvent_PhotometrySummary() ||
          typed.SequencerEvent_RecoveryProgress() ||
          typed.SequencerEvent_RecoveryCompleted() ||
          typed.SequencerEvent_PluginNodeRequested() ||
          typed.SequencerEvent_PluginNodeProgress():
        return null;
    }
  }

  static (NotificationCategory, Map<String, String>)? _classifyImaging(
    typed.ImagingEvent event,
  ) => switch (event) {
    typed.ImagingEvent_ExposureCompleted() => (
      NotificationCategory.frameCaptured,
      <String, String>{'frame': '', 'exposure.duration': ''},
    ),
    typed.ImagingEvent_ExposureCompletedWithFrame(:final frameNumber) => (
      NotificationCategory.frameCaptured,
      <String, String>{'frame': '$frameNumber', 'exposure.duration': ''},
    ),
    typed.ImagingEvent_ExposureFailed(:final error) => (
      NotificationCategory.exposureFailed,
      <String, String>{'frame.reason': error},
    ),
    typed.ImagingEvent_ExposureFailedOld(:final reason) => (
      NotificationCategory.exposureFailed,
      <String, String>{'frame.reason': reason},
    ),
    typed.ImagingEvent_ExposureStarted() ||
    typed.ImagingEvent_ExposureStartedWithFrame() ||
    typed.ImagingEvent_ExposureProgress() ||
    typed.ImagingEvent_ExposureCancelled() ||
    typed.ImagingEvent_DownloadStarted() ||
    typed.ImagingEvent_DownloadCompleted() ||
    typed.ImagingEvent_ImageReady() ||
    typed.ImagingEvent_ImageSaved() ||
    typed.ImagingEvent_TemperatureChanged() ||
    typed.ImagingEvent_ExposureComplete() ||
    typed.ImagingEvent_IntegrationProgress() ||
    typed.ImagingEvent_IntegrationTelemetry() => null,
  };

  static (NotificationCategory, Map<String, String>)? _classifyGuiding(
    typed.GuidingEvent event,
  ) => switch (event) {
    typed.GuidingEvent_LostStar() ||
    typed.GuidingEvent_Disconnected() => (NotificationCategory.guidingLost, _none),
    typed.GuidingEvent_Connected() ||
    typed.GuidingEvent_GuidingStarted() ||
    typed.GuidingEvent_GuidingStopped() ||
    typed.GuidingEvent_Paused() ||
    typed.GuidingEvent_Resumed() ||
    typed.GuidingEvent_Settled() ||
    typed.GuidingEvent_SettleTimedOut() ||
    typed.GuidingEvent_StopReason() ||
    typed.GuidingEvent_DitherStarted() ||
    typed.GuidingEvent_DitherCompleted() ||
    typed.GuidingEvent_Correction() ||
    typed.GuidingEvent_Looping() ||
    typed.GuidingEvent_Settling() ||
    typed.GuidingEvent_Calibrating() ||
    typed.GuidingEvent_CalibrationComplete() ||
    typed.GuidingEvent_StarSelected() ||
    typed.GuidingEvent_AppState() ||
    typed.GuidingEvent_GuideStats() => null,
  };

  static (NotificationCategory, Map<String, String>)? _classifySafety(
    typed.SafetyEvent event,
  ) => switch (event) {
    typed.SafetyEvent_MountMotionFault(:final deviceId, :final message) ||
    typed.SafetyEvent_MountPositionUnknown(:final deviceId, :final message) => (
      NotificationCategory.mountFault,
      <String, String>{'mount.device': deviceId, 'mount.message': message},
    ),
    // The operator did this; nothing to tell them.
    typed.SafetyEvent_MountGuardCleared() => null,
    typed.SafetyEvent_WeatherSafe() => (
      NotificationCategory.weatherSafeAgain,
      _none,
    ),
    typed.SafetyEvent_WeatherUnsafe() ||
    typed.SafetyEvent_EmergencyStop() ||
    typed.SafetyEvent_ParkInitiated() ||
    typed.SafetyEvent_ParkCompleted() => (
      NotificationCategory.weatherUnsafe,
      _none,
    ),
  };

  static (NotificationCategory, Map<String, String>)? _classifyEquipment(
    typed.EquipmentEvent event,
  ) {
    final (deviceType, deviceId) = switch (event) {
      typed.EquipmentEvent_Disconnected(:final deviceType, :final deviceId) ||
      typed.EquipmentEvent_Error(:final deviceType, :final deviceId) => (
        deviceType,
        deviceId,
      ),
      _ => (null, null),
    };
    if (deviceType == null || deviceId == null) return null;
    return (
      NotificationCategory.equipmentDisconnected,
      <String, String>{
        'equipment.device_type': deviceType,
        'equipment.device_id': deviceId,
        // The operator-facing template renders this, never the raw id.
        // `friendlyNameFromDeviceId` is the same resolver the run dashboard's
        // feed uses, so a disconnect toast and the event feed cannot name one
        // device two ways.
        'equipment.device_name': _disconnectedDeviceName(deviceId, deviceType),
      },
    );
  }

  /// The name a disconnect notification calls the device.
  ///
  /// Falls back down a chain rather than ever emitting an empty fragment:
  /// friendly name -> the device id we could not humanize -> the device type
  /// -> a generic noun. The empty-string case is real: some backend
  /// disconnect events carry no `device_id` at all (see
  /// `UsbDisconnectLog.recordDisconnect`, which synthesises `<unknown>` for
  /// the same reason), and "` disconnected.`" was the resulting sentence.
  static String _disconnectedDeviceName(String deviceId, String deviceType) {
    if (deviceId.isNotEmpty) {
      final friendly = friendlyNameFromDeviceId(deviceId);
      if (friendly.isNotEmpty && friendly != deviceId) return friendly;
      // Unhumanizable id: prefer the type over dumping a wire identifier.
      if (deviceType.isNotEmpty) return deviceType;
      return friendly;
    }
    if (deviceType.isNotEmpty) return deviceType;
    return 'A device';
  }

  static (NotificationCategory, Map<String, String>)? _classifySystem(
    typed.SystemEvent event,
  ) => switch (event) {
    typed.SystemEvent_DiskSpaceLow() => (
      NotificationCategory.diskSpaceLow,
      _none,
    ),
    typed.SystemEvent_Initialized() ||
    typed.SystemEvent_ShuttingDown() ||
    typed.SystemEvent_Error() ||
    typed.SystemEvent_Notification() ||
    typed.SystemEvent_EventsDropped() => null,
  };
}

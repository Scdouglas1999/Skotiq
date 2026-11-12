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

import 'dart:convert';
import 'dart:developer' as developer;

import '../../backend/sequencer_error_kind.dart';
import '../../backend/sequencer_notice.dart';
import '../../backend/bridge_events.dart'
    show SequencerErrorKind, SequencerNotice;
import '../../models/backend/event_types.dart';
import '../../errors/error_text.dart';
import '../../models/notification/notification_categories.dart';
import '../../providers/sequence/run_stop_classification.dart';
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
    if (event.category != EventCategory.equipment) return false;
    final deviceId = event.data['device_id'];
    if (deviceId is! String || deviceId.isEmpty) return false;
    switch (event.eventType) {
      case 'Connecting':
        _ids.add(deviceId);
      case 'Connected':
      case 'Disconnected':
        _ids.remove(deviceId);
      case 'Error':
        return _ids.contains(deviceId);
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
    if (event.category != EventCategory.sequencer) return null;
    if (event.eventType != 'DecisionLogged') return null;
    return sequenceStopDecision(
      category: (event.data['category'] as String?) ?? '',
      summary: (event.data['summary'] as String?) ?? '',
      detailsJson: event.data['details_json'] as String?,
    );
  }

  /// Classify [event]. Returns `null` for events that do not map to a
  /// routed category.
  static ClassifiedNotification? classify(SkotiqEvent event) {
    final mapped = _categoryAndContext(event);
    if (mapped == null) return null;
    // Decision rows are published at info whatever they record. The
    // reject-streak and problem-noticed rows stand for a warning, so they are
    // routed at their category's own level and clear its warning floor.
    final severity =
        mapped.$1 == NotificationCategory.problemNoticed ||
            (event.eventType == 'DecisionLogged' &&
                mapped.$1 == NotificationCategory.frameRejected)
        ? mapped.$1.defaultSeverity
        : event.severity;
    return ClassifiedNotification(
      category: mapped.$1,
      context: mapped.$2,
      severity: severity,
    );
  }

  /// The `details_json` of a decision row as a map, or empty when it is
  /// absent or not an object.
  static Map<String, dynamic> _decisionDetails(SkotiqEvent event) {
    final raw = event.data['details_json'];
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  static (NotificationCategory, Map<String, String>)? _categoryAndContext(
    SkotiqEvent event,
  ) {
    switch (event.category) {
      case EventCategory.sequencer:
        return _classifySequencer(event);
      case EventCategory.imaging:
        return _classifyImaging(event);
      case EventCategory.guiding:
        return _classifyGuiding(event);
      case EventCategory.safety:
        switch (event.eventType) {
          case 'MountMotionFault':
          case 'MountPositionUnknown':
            return (
              NotificationCategory.mountFault,
              <String, String>{
                'mount.device': event.data['device_id']?.toString() ?? '',
                'mount.message': event.data['message']?.toString() ?? '',
              },
            );
          case 'MountGuardCleared':
            // The operator did this; nothing to tell them.
            return null;
        }
        return (
          event.eventType.toLowerCase().contains('safe') &&
                  !event.eventType.toLowerCase().contains('unsafe')
              ? NotificationCategory.weatherSafeAgain
              : NotificationCategory.weatherUnsafe,
          <String, String>{},
        );
      case EventCategory.equipment:
        return _classifyEquipment(event);
      case EventCategory.system:
        return _classifySystem(event);
      case EventCategory.polarAlignment:
      case EventCategory.job:
      case EventCategory.session:
      case EventCategory.catalog:
        // Consumed via dedicated UI surfaces (job progress toast,
        // session-ownership banner, Catalog management panel); not routed
        // through the cross-platform notification system.
        return null;
    }
  }

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

  /// Context for a stop notification: the run it ended, when the wire carries
  /// it. Run identity is what keeps two runs' stops from folding into one
  /// episode (and one run's stop from splitting into two) in
  /// [StopPushArbiter], however long the safing teardown stretched them.
  static Map<String, String> _stopContext(SkotiqEvent event) {
    final runId = event.data['sequence_run_id'];
    if (runId is! int) return <String, String>{};
    return <String, String>{kStopRunIdContextKey: '$runId'};
  }

  /// The text a sequencer `Error` carries. The FFI mapper writes `message`;
  /// the remote/WebSocket envelope has been seen using `error` for the same
  /// field, so both are read before giving up.
  static String _sequencerErrorMessage(SkotiqEvent event) =>
      (event.data['message'] as String?) ??
      (event.data['error'] as String?) ??
      '';

  static (NotificationCategory, Map<String, String>)? _classifySequencer(
    SkotiqEvent event,
  ) {
    switch (event.eventType) {
      case 'Started':
        return (NotificationCategory.sequenceStarted, <String, String>{});
      case 'Completed':
        return (NotificationCategory.sequenceCompleted, <String, String>{});
      case 'Stopped':
        return (NotificationCategory.sequenceStopped, _stopContext(event));
      case 'Error':
        // A cancelled run reaches Dart as a sequencer Error carrying the
        // notice "Sequence cancelled" (the `Stopped` lifecycle event arrives
        // separately). Only the exact notice is reclassified; see
        // [isSequenceCancelledNotice] for why the match is not a substring.
        if (isSequenceCancelledNotice(_sequencerErrorMessage(event))) {
          developer.log(
            '[$kStopClassificationLogTag] event_classifier: sequencer Error '
            'carrying the cancellation notice -> sequenceStopped',
            name: 'NotificationEventClassifier',
          );
          return (NotificationCategory.sequenceStopped, _stopContext(event));
        }
        // The host says what the error means for the run. Only a problem the
        // run carried on through is a notice of its own: a note belongs to
        // the run's warnings, a pause is told by `Paused`, and a failed step
        // is told by the run's end below, once, if the run does end.
        if (sequencerErrorKindOf(event) != SequencerErrorKind.stepProblem) {
          return null;
        }
        return (
          NotificationCategory.problemNoticed,
          <String, String>{
            'problem.source': kStepProblemSource,
            'problem.message': _sequencerErrorMessage(event),
          },
        );
      // The run's end, and the only event that says a run failed. Its reason
      // is the first fault the run did not survive.
      case 'SequenceFailed':
        return (
          NotificationCategory.sequenceFailed,
          _failureContext((event.data['error'] as String?) ?? ''),
        );
      case 'DecisionLogged':
        // A happening the run carried on through, told once from its decision
        // row; the run never stops for these (owner decision 2026-10-06).
        // Stop-authorship decisions are consumed by [stopDecisionOf], not
        // classified here.
        switch (sequencerNoticeOf(event)) {
          // An autofocus that did not converge: the run continues on the
          // restored focus and the phone gets an INFO, not an alarm.
          case SequencerNotice.autofocusContinued:
            return (
              NotificationCategory.autofocusContinued,
              <String, String>{},
            );
          // A streak of rejected frames reached the operator's limit; told
          // once per streak.
          case SequencerNotice.rejectStreak:
            final details = _decisionDetails(event);
            return (
              NotificationCategory.frameRejected,
              <String, String>{
                'frame.streak': '${details['consecutive_rejects'] ?? ''}',
                'frame.reason': (details['reason'] as String?) ?? '',
              },
            );
          // A quality problem the operator has not asked to stop the run for.
          case SequencerNotice.problemNoticed:
            final details = _decisionDetails(event);
            return (
              NotificationCategory.problemNoticed,
              <String, String>{
                'problem.source': (details['source'] as String?) ?? '',
                'problem.message': (details['problem'] as String?) ?? '',
              },
            );
          case null:
            return null;
        }
      case 'Paused':
        return (NotificationCategory.sequencePaused, <String, String>{});
      case 'Resumed':
        return (NotificationCategory.sequenceResumed, <String, String>{});
      case 'TargetStarted':
        return (
          NotificationCategory.targetStarted,
          <String, String>{
            'target.name': (event.data['target_name'] as String?) ?? '',
            'target.id': (event.data['target_id'] as String?) ?? '',
          },
        );
      case 'TargetCompleted':
        return (
          NotificationCategory.targetCompleted,
          <String, String>{
            'target.name': (event.data['target_name'] as String?) ?? '',
            'target.id': (event.data['target_id'] as String?) ?? '',
          },
        );
      case 'NodeCompleted':
        // The verdict is `status` — a string ('success' / 'failed' /
        // 'cancelled' / 'skipped'), see `SequencerEvent.nodeCompleted`. This
        // read a `success` BOOL that no producer emits and defaulted it to
        // TRUE, so had this branch ever fired for a failed autofocus it would
        // have pushed "Autofocus Completed" to the operator's phone — the worst
        // possible direction for an alert you are asleep for. Anything that is
        // not an explicit success is treated as a failure here; an absent
        // status is not evidence of success.
        final nodeType = (event.data['node_type'] as String? ?? '')
            .toLowerCase();
        if (nodeType.isEmpty) {
          // `NodeCompleted` carries only `node_id` + `status` on the wire (see
          // `ffi_backend/event_mapping.dart`), so this branch is inert today
          // and no autofocus-specific notification is raised from it. A failed
          // autofocus still reaches the operator: the instruction failure is
          // emitted separately as a sequencer `Error`, which classifies
          // critical below. Populating `node_type` on the event (producer-side)
          // is all that is needed to light this up.
          return null;
        }
        final status = event.data['status'] as String?;
        final succeeded =
            status == 'success' ||
            // Legacy bool from an older producer.
            (status == null && event.data['success'] == true);
        if (nodeType.contains('autofocus')) {
          return (
            succeeded
                ? NotificationCategory.autofocusCompleted
                : NotificationCategory.autofocusFailed,
            <String, String>{},
          );
        }
        return null;
      case 'InstructionProgress':
        final instr = (event.data['instruction'] as String? ?? '')
            .toLowerCase();
        if (instr.contains('meridian')) {
          return (
            NotificationCategory.meridianFlipPerformed,
            <String, String>{},
          );
        }
        return null;
      case 'TriggerFired':
        // A trigger whose action is to carry on (a filter change in a rotating
        // Smart Exposure fires one every frame) changed nothing; notifying it
        // buried the real alerts on a linked client.
        final action = (event.data['action'] as String? ?? '').trim();
        if (action.toLowerCase() == 'continue') return null;
        return (
          NotificationCategory.triggerFired,
          <String, String>{
            'trigger.name': (event.data['trigger_name'] as String?) ?? '',
          },
        );
      case 'RecoveryStarted':
        return (NotificationCategory.recoveryStarted, <String, String>{});
      case 'RecoveryRecovered':
        return (NotificationCategory.recoveryRecovered, <String, String>{});
      case 'RecoveryGaveUp':
        return (NotificationCategory.recoveryGaveUp, <String, String>{});
      case 'FrameRejected':
        // One rejected frame is not news: the run dashboard and the reject
        // folder carry every one. The operator hears about a STREAK, once,
        // from the engine's reject-streak decision row above; notifying per
        // frame turned a cloudy hour into a notification a minute.
        return null;
    }
    return null;
  }

  static (NotificationCategory, Map<String, String>)? _classifyImaging(
    SkotiqEvent event,
  ) {
    switch (event.eventType) {
      case 'ExposureCompleted':
        return (
          NotificationCategory.frameCaptured,
          <String, String>{
            'frame': '${event.data['frame_number'] ?? ''}',
            'exposure.duration': '${event.data['duration_secs'] ?? ''}',
          },
        );
      case 'ExposureFailed':
        return (
          NotificationCategory.exposureFailed,
          <String, String>{
            'frame.reason':
                (event.data['error'] as String?) ??
                (event.data['reason'] as String?) ??
                '',
          },
        );
    }
    return null;
  }

  static (NotificationCategory, Map<String, String>)? _classifyGuiding(
    SkotiqEvent event,
  ) {
    switch (event.eventType) {
      case 'StarLost':
      case 'Disconnected':
        return (NotificationCategory.guidingLost, <String, String>{});
      case 'StarRecovered':
      case 'Reconnected':
        return (NotificationCategory.guidingRecovered, <String, String>{});
    }
    return null;
  }

  static (NotificationCategory, Map<String, String>)? _classifyEquipment(
    SkotiqEvent event,
  ) {
    if (event.eventType == 'Disconnected' || event.eventType == 'Error') {
      final deviceType = (event.data['device_type'] as String?) ?? '';
      final deviceId = (event.data['device_id'] as String?) ?? '';
      return (
        NotificationCategory.equipmentDisconnected,
        <String, String>{
          'equipment.device_type': deviceType,
          'equipment.device_id': deviceId,
          // The operator-facing template renders this, never the
          // raw id. `friendlyNameFromDeviceId` is the same resolver the run
          // dashboard's feed uses, so a disconnect toast and the event feed
          // cannot name one device two ways.
          'equipment.device_name': _disconnectedDeviceName(
            deviceId,
            deviceType,
          ),
        },
      );
    }
    return null;
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
    SkotiqEvent event,
  ) {
    if (event.eventType.toLowerCase().contains('disk')) {
      return (NotificationCategory.diskSpaceLow, <String, String>{});
    }
    return null;
  }
}

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
// The first two operated on the core [NightshadeEvent] (string `eventType`
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

import '../../models/backend/event_types.dart';
import '../../models/notification/notification_categories.dart';
import '../../providers/sequence/run_stop_classification.dart';
import '../../utils/device_id.dart';
import 'notification_template.dart';

/// Summary of the decision row the engine writes when a streak of rejected
/// frames reaches the operator's limit (`IMAGE_GRADING_REJECT_STREAK_SUMMARY`
/// in the native grading module).
const String kImageGradingRejectStreakSummary =
    'Frames rejected in a row — the run continues';

/// Summary of the decision row the engine writes when it judged a quality
/// problem — a Center that could not solve, guiding RMS over a limit, a dither
/// that did not settle, a post-flip check — and the run carried on
/// (`QUALITY_PROBLEM_CONTINUED_SUMMARY` in the native executor).
const String kQualityProblemContinuedSummary =
    'Problem noticed — the run continues';

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

/// Maps a core [NightshadeEvent] to its [NotificationCategory] (+ context),
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
  static SequenceStopDecision? stopDecisionOf(NightshadeEvent event) {
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
  static ClassifiedNotification? classify(NightshadeEvent event) {
    final mapped = _categoryAndContext(event);
    if (mapped == null) return null;
    // Decision rows are published at info whatever they record. The
    // reject-streak and problem-noticed rows stand for a warning, so they are
    // routed at their category's own level and clear its warning floor.
    final severity =
        event.eventType == 'DecisionLogged' &&
            (mapped.$1 == NotificationCategory.frameRejected ||
                mapped.$1 == NotificationCategory.problemNoticed)
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
  static Map<String, dynamic> _decisionDetails(NightshadeEvent event) {
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
    NightshadeEvent event,
  ) {
    switch (event.category) {
      case EventCategory.sequencer:
        return _classifySequencer(event);
      case EventCategory.imaging:
        return _classifyImaging(event);
      case EventCategory.guiding:
        return _classifyGuiding(event);
      case EventCategory.safety:
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

  /// Context for a stop notification: the run it ended, when the wire carries
  /// it. Run identity is what keeps two runs' stops from folding into one
  /// episode (and one run's stop from splitting into two) in
  /// [StopPushArbiter], however long the safing teardown stretched them.
  static Map<String, String> _stopContext(NightshadeEvent event) {
    final runId = event.data['sequence_run_id'];
    if (runId is! int) return <String, String>{};
    return <String, String>{kStopRunIdContextKey: '$runId'};
  }

  /// The text a sequencer `Error` carries. The FFI mapper writes `message`;
  /// the remote/WebSocket envelope has been seen using `error` for the same
  /// field, so both are read before giving up.
  static String _sequencerErrorMessage(NightshadeEvent event) =>
      (event.data['message'] as String?) ??
      (event.data['error'] as String?) ??
      '';

  static (NotificationCategory, Map<String, String>)? _classifySequencer(
    NightshadeEvent event,
  ) {
    switch (event.eventType) {
      case 'Started':
        return (NotificationCategory.sequenceStarted, <String, String>{});
      case 'Completed':
        return (NotificationCategory.sequenceCompleted, <String, String>{});
      case 'Stopped':
        return (NotificationCategory.sequenceStopped, _stopContext(event));
      case 'Error':
        // An advisory rides the same payload with `EventSeverity.warning` (see
        // `ExecutorEvent::Warning`). It is not a run outcome, so it raises no
        // notification at all: the run dashboard and the Session Report's
        // Warnings section are where it belongs. Classified by payload type
        // alone, the solverless meridian-flip notice fired this producer and
        // told the operator — by toast AND by phone push — that a run which
        // went on to finish 3/3 had FAILED and been ABORTED.
        if (event.severity == EventSeverity.warning) return null;
        // PRODUCER 1 of the stop pipeline (toast "Sequence failed / Sequence
        // aborted at …", and the phone push behind it).
        //
        // A cancelled run reaches Dart as a sequencer ERROR carrying the notice
        // "Sequence cancelled" — the `Stopped` lifecycle event arrives
        // separately — so classifying the payload type alone told the operator
        // their own Stop was a failure. Only the exact notice is reclassified;
        // see [isSequenceCancelledNotice] for why the match is not a substring.
        if (isSequenceCancelledNotice(_sequencerErrorMessage(event))) {
          developer.log(
            '[$kStopClassificationLogTag] event_classifier: sequencer Error '
            'carrying the cancellation notice -> sequenceStopped',
            name: 'NotificationEventClassifier',
          );
          return (NotificationCategory.sequenceStopped, _stopContext(event));
        }
        return (NotificationCategory.sequenceFailed, <String, String>{});
      case 'DecisionLogged':
        // The AF-trigger continuation row is the only decision that maps to
        // its own push: the run continues on restored focus and the phone
        // gets an INFO, not an alarm (owner decision 10). Stop-authorship
        // decisions are consumed by [stopDecisionOf], not classified here.
        if ((event.data['category'] as String?) == 'system_event' &&
            (event.data['summary'] as String?) ==
                'Autofocus failed — continuing with last-good focus') {
          return (NotificationCategory.autofocusContinued, <String, String>{});
        }
        // A streak of rejected frames reached the operator's limit. Told once
        // per streak, and the run keeps imaging (owner decision 2026-10-06:
        // the limit never stops a sequence or ends a night).
        if ((event.data['category'] as String?) == 'system_event' &&
            (event.data['summary'] as String?) ==
                kImageGradingRejectStreakSummary) {
          final details = _decisionDetails(event);
          return (
            NotificationCategory.frameRejected,
            <String, String>{
              'frame.streak': '${details['consecutive_rejects'] ?? ''}',
              'frame.reason': (details['reason'] as String?) ?? '',
            },
          );
        }
        // A quality problem the run carried on through, because the operator
        // has not asked for such problems to stop it (owner decision
        // 2026-10-06). Told once per episode by the engine.
        if ((event.data['category'] as String?) == 'system_event' &&
            (event.data['summary'] as String?) ==
                kQualityProblemContinuedSummary) {
          final details = _decisionDetails(event);
          return (
            NotificationCategory.problemNoticed,
            <String, String>{
              'problem.source': (details['source'] as String?) ?? '',
              'problem.message': (details['problem'] as String?) ?? '',
            },
          );
        }
        return null;
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
    NightshadeEvent event,
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
    NightshadeEvent event,
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
    NightshadeEvent event,
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
    NightshadeEvent event,
  ) {
    if (event.eventType.toLowerCase().contains('disk')) {
      return (NotificationCategory.diskSpaceLow, <String, String>{});
    }
    return null;
  }
}

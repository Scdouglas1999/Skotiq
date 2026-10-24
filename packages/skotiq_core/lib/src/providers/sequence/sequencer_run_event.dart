/// Typed sequencer events, normalized once at the Dart boundary.
///
/// Native sequencer events reach Dart as a [SkotiqEvent] whose payload is an
/// untyped `data` map, by two transports: the FFI backend flattens the typed
/// bridge payload into the map (`ffi_backend/event_mapping.dart`), and a
/// `--remote-host` client receives the same map after a JSON round-trip
/// ([SkotiqEvent.fromWireJson]). [SequencerRunEvent.fromSkotiqEvent] is the one
/// place that reads that map. Every transport difference is absorbed here:
///
///  * numbers arrive as `int` or `double` depending on the transport, so every
///    numeric field accepts any `num`;
///  * a few events have older spellings (`Sequence`-prefixed lifecycle names,
///    `TargetStarted`, the `nodeId` / `nodeName` / `name` keys, a boolean
///    `success` on `NodeCompleted`), accepted as aliases of the current ones;
///  * `detail_json` is a JSON string on the wire and a decoded value in tests,
///    and is decoded once ([decodeStructuredProgressJson]);
///  * a field of the wrong type reads as absent instead of throwing inside an
///    event listener.
///
/// Consumers switch over the sealed hierarchy and never read `data` keys. The
/// wire format is unchanged.
library;

import '../../backend/frame_capture_metadata.dart';
import '../../models/backend/event_types.dart';
import '../../models/sequence/instruction_progress_detail.dart';
import '../../models/sequence/sequence_models.dart' show NodeStatus;
import 'run_dither_event.dart' show ditherPerformedDetailKind;
import 'run_frame_assessment.dart'
    show frameAssessedDetailKind, horizonObstructionDetailKind;
import 'structured_progress_json.dart';

/// One sequencer event, typed. See the library comment for the normalization
/// rules.
sealed class SequencerRunEvent {
  const SequencerRunEvent({
    required this.eventType,
    required this.timestamp,
    required this.severity,
  });

  /// The wire event name this was decoded from, for logs and traces only.
  final String eventType;

  /// Milliseconds since the epoch, as stamped by the producer.
  final int timestamp;

  final EventSeverity severity;

  /// Decode [event], or null when it is not a sequencer event.
  static SequencerRunEvent? fromSkotiqEvent(SkotiqEvent event) {
    if (event.category != EventCategory.sequencer) return null;
    return _decode(event);
  }
}

/// Run lifecycle events reported by the native executor.
sealed class RunLifecycleEvent extends SequencerRunEvent {
  const RunLifecycleEvent({
    required super.eventType,
    required super.timestamp,
    required super.severity,
  });
}

final class RunStarted extends RunLifecycleEvent {
  const RunStarted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.sequenceName,
  });

  final String? sequenceName;
}

final class RunPaused extends RunLifecycleEvent {
  const RunPaused({
    required super.eventType,
    required super.timestamp,
    required super.severity,
  });
}

final class RunResumed extends RunLifecycleEvent {
  const RunResumed({
    required super.eventType,
    required super.timestamp,
    required super.severity,
  });
}

/// A terminal event: the native run is over. [RunStopped], [RunCompleted],
/// [RunFailed] and [RunCancelled].
sealed class RunTerminalEvent extends RunLifecycleEvent {
  const RunTerminalEvent({
    required super.eventType,
    required super.timestamp,
    required super.severity,
  });
}

final class RunStopped extends RunTerminalEvent {
  const RunStopped({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.sequenceRunId,
  });

  final int? sequenceRunId;
}

final class RunCompleted extends RunTerminalEvent {
  const RunCompleted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
  });
}

final class RunFailed extends RunTerminalEvent {
  const RunFailed({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.error,
  });

  final String? error;
}

/// A cancellation lifecycle name some hosts send. No current producer emits it;
/// it only resets the camera card's exposing flag.
final class RunCancelled extends RunTerminalEvent {
  const RunCancelled({
    required super.eventType,
    required super.timestamp,
    required super.severity,
  });
}

final class NodeStarted extends SequencerRunEvent {
  const NodeStarted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.nodeId,
    this.nodeType,
  });

  final String? nodeId;

  /// The node's type name, which the progress surfaces show as its name.
  final String? nodeType;
}

final class NodeCompleted extends SequencerRunEvent {
  const NodeCompleted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.nodeId,
    this.status,
  });

  /// The status strings the native executor sends.
  static const knownStatuses = {
    'success',
    'skipped',
    'cancelled',
    'failed',
    'failure',
  };

  final String? nodeId;

  /// The wire status (`success` / `skipped` / `cancelled` / `failed`), or null
  /// when the event carried none.
  final String? status;

  /// [status] as a [NodeStatus]; null when there is no status. Any status other
  /// than success / skipped / cancelled reads as a failure.
  NodeStatus? get nodeStatus => switch (status) {
    null => null,
    'success' => NodeStatus.success,
    'skipped' || 'cancelled' => NodeStatus.skipped,
    _ => NodeStatus.failure,
  };
}

final class ExposureStarted extends SequencerRunEvent {
  const ExposureStarted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.frame,
    this.total,
    this.filter,
    this.durationSecs,
  });

  final int? frame;
  final int? total;
  final String? filter;
  final double? durationSecs;
}

final class ExposureCompleted extends SequencerRunEvent {
  const ExposureCompleted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.frame,
    this.total,
    this.durationSecs,
    this.filter,
  });

  /// 1-based frame index within the producing node.
  final int? frame;
  final int? total;
  final double? durationSecs;
  final String? filter;
}

/// The native `Progress` event: frames completed out of frames planned.
final class ExposureCountProgress extends SequencerRunEvent {
  const ExposureCountProgress({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.current,
    this.total,
  });

  final int? current;
  final int? total;
}

final class TargetChanged extends SequencerRunEvent {
  const TargetChanged({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.targetName,
    this.ra,
    this.dec,
  });

  final String? targetName;

  /// Right ascension in hours.
  final double? ra;

  /// Declination in degrees.
  final double? dec;
}

final class TargetCompleted extends SequencerRunEvent {
  const TargetCompleted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.targetName,
  });

  final String? targetName;
}

/// The native `Error` event. The executor uses one payload for faults and
/// advisories and tells them apart by severity, so [isAdvisory] is what
/// decides whether this is a fault.
final class SequencerError extends SequencerRunEvent {
  const SequencerError({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.message,
  });

  final String? message;

  bool get isAdvisory => severity == EventSeverity.warning;
}

final class InstructionProgress extends SequencerRunEvent {
  const InstructionProgress({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.nodeId,
    this.instruction,
    this.progressPercent,
    this.detail,
  });

  final String? nodeId;
  final String? instruction;
  final double? progressPercent;
  final String? detail;
}

final class StructuredInstructionProgress extends SequencerRunEvent {
  const StructuredInstructionProgress({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    required this.detailKind,
    required this.detailJson,
    this.nodeId,
    this.instruction,
    this.progressPercent,
  });

  final String? nodeId;
  final String? instruction;
  final double? progressPercent;

  /// The `ProgressDetail` variant name; `'Unknown'` when the event named none.
  final String detailKind;

  /// The decoded `detail_json` payload.
  final Object? detailJson;

  InstructionProgressDetail get detail =>
      InstructionProgressDetail.fromStructuredData(
        detailKind: detailKind,
        detailJson: detailJson,
      );

  /// The running filter's name, which only a Change Filter instruction puts on
  /// the wire; null for every other detail kind.
  String? get changedFilterName {
    if (detailKind != 'Filter') return null;
    final json = detailJson;
    if (json is! Map) return null;
    final name = json['name'];
    return name is String && name.isNotEmpty ? name : null;
  }
}

/// One dither the run performed, whoever asked for it. Carried on the wire as
/// an `InstructionProgressStructured` with its own detail kind (see
/// `run_dither_event.dart`).
final class DitherPerformed extends SequencerRunEvent {
  const DitherPerformed({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.nodeId,
  });

  final String? nodeId;
}

/// The native frame watch's verdict on one saved frame: where it solved, how
/// far from the target, the guide RMS during the exposure, the sky level, and
/// whether it must stop counting. Carried on the wire as an
/// `InstructionProgressStructured` with its own detail kind (see
/// `run_frame_assessment.dart`).
final class FrameAssessed extends SequencerRunEvent {
  const FrameAssessed({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    required this.wasAccepted,
    required this.solveAttempted,
    required this.plateSolved,
    required this.offTarget,
    required this.obstructed,
    this.nodeId,
    this.savePath,
    this.filter,
    this.exposureSecs,
    this.solvedRaDeg,
    this.solvedDecDeg,
    this.solvedRotationDeg,
    this.solvedPixelScale,
    this.offsetArcmin,
    this.guideRmsTotal,
    this.guideRmsSamples,
    this.backgroundAdu,
    this.starCount,
    this.altitudeDeg,
    this.azimuthDeg,
    this.pierSide,
    this.exclusionReason,
  });

  final String? nodeId;

  /// The path the frame's `captured_images` row was written with: the save
  /// path when accepted, the reject path when the grader rejected it.
  final String? savePath;
  final String? filter;
  final double? exposureSecs;

  /// The grader's verdict, before any exclusion below.
  final bool wasAccepted;
  final bool solveAttempted;
  final bool plateSolved;

  /// Solved center in degrees (RA too), rotation in degrees, scale in
  /// arcsec per pixel.
  final double? solvedRaDeg;
  final double? solvedDecDeg;
  final double? solvedRotationDeg;
  final double? solvedPixelScale;

  /// Distance of the solved center from the target.
  final double? offsetArcmin;

  /// RMS of the guider's total-RMS samples over the exposure, in the
  /// guider's units.
  final double? guideRmsTotal;
  final int? guideRmsSamples;
  final double? backgroundAdu;
  final int? starCount;
  final double? altitudeDeg;
  final double? azimuthDeg;
  final String? pierSide;
  final bool offTarget;
  final bool obstructed;

  /// Non-null when the frame must no longer count; starts with
  /// `frameExclusionOffTargetPrefix` or `frameExclusionObstructedPrefix`.
  final String? exclusionReason;

  bool get isExcluded => exclusionReason != null && exclusionReason!.isNotEmpty;
}

/// A confirmed obstruction (trees, a roof) the run met while imaging, where
/// it began on the sky and what the run did about it.
final class HorizonObstructionDetected extends SequencerRunEvent {
  const HorizonObstructionDetected({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    required this.altitudeDeg,
    required this.azimuthDeg,
    this.nodeId,
    this.targetName,
    this.latitude,
    this.longitude,
    this.verdict,
    this.action,
    this.message,
  });

  final String? nodeId;
  final double altitudeDeg;
  final double azimuthDeg;
  final String? targetName;

  /// The run's site; null when the executor did not know it.
  final double? latitude;
  final double? longitude;
  final String? verdict;

  /// `next_target` or `end_of_night`.
  final String? action;

  /// The operator-facing sentence.
  final String? message;
}

final class MeridianFlipOutcome extends SequencerRunEvent {
  const MeridianFlipOutcome({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    required this.failedSteps,
    this.outcome,
    this.targetName,
    this.newPierSide,
    this.attempts,
    this.durationSecs,
    this.error,
    this.actionTaken,
  });

  /// `success` / `aborted` / `failed`.
  final String? outcome;
  final String? targetName;
  final String? newPierSide;
  final int? attempts;
  final double? durationSecs;
  final String? error;
  final String? actionTaken;
  final List<String> failedSteps;
}

final class TriggerFired extends SequencerRunEvent {
  const TriggerFired({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.triggerId,
    this.triggerName,
    this.action,
  });

  final String? triggerId;
  final String? triggerName;
  final String? action;
}

/// A frame the grader ruled on: [FrameAccepted] or [FrameRejected].
sealed class FrameGraded extends SequencerRunEvent {
  const FrameGraded({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    required this.capture,
    this.nodeId,
    this.frame,
    this.total,
    this.hfr,
    this.eccentricity,
    this.starCount,
    this.filter,
    this.durationSecs,
  });

  bool get accepted;

  /// The file on disk: the save path when accepted, the reject path when not.
  String? get filePath;

  final String? nodeId;
  final int? frame;
  final int? total;
  final double? hfr;
  final double? eccentricity;
  final int? starCount;
  final String? filter;

  /// `duration_secs`, which only some producers send; [capture] carries the
  /// exposure the camera reported.
  final double? durationSecs;

  /// The capture truth the FITS header was written from.
  final FrameCapture capture;
}

final class FrameAccepted extends FrameGraded {
  const FrameAccepted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    required super.capture,
    super.nodeId,
    super.frame,
    super.total,
    super.hfr,
    super.eccentricity,
    super.starCount,
    super.filter,
    super.durationSecs,
    this.savePath,
  });

  final String? savePath;

  @override
  bool get accepted => true;

  @override
  String? get filePath => savePath;
}

final class FrameRejected extends FrameGraded {
  const FrameRejected({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    required super.capture,
    super.nodeId,
    super.frame,
    super.total,
    super.hfr,
    super.eccentricity,
    super.starCount,
    super.filter,
    super.durationSecs,
    this.rejectPath,
    this.reason,
    this.consecutiveRejects,
  });

  final String? rejectPath;
  final String? reason;
  final int? consecutiveRejects;

  @override
  bool get accepted => false;

  @override
  String? get filePath => rejectPath;
}

final class PluginNodeRequested extends SequencerRunEvent {
  const PluginNodeRequested({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.nodeId,
    this.pluginId,
    this.nodeTypeId,
    this.configJson,
    this.displayName,
    this.timeoutSecs,
  });

  final String? nodeId;
  final String? pluginId;
  final String? nodeTypeId;
  final String? configJson;
  final String? displayName;
  final int? timeoutSecs;
}

final class PluginNodeProgress extends SequencerRunEvent {
  const PluginNodeProgress({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.nodeId,
    this.pluginId,
    this.nodeTypeId,
    this.detailJson,
  });

  final String? nodeId;
  final String? pluginId;
  final String? nodeTypeId;
  final String? detailJson;
}

final class DepthGoalCompleted extends SequencerRunEvent {
  const DepthGoalCompleted({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.nodeId,
    this.goalId,
    this.revision,
    this.filterName,
    this.score,
    this.threshold,
    this.evidenceFrames,
    this.confirmationFrames,
  });

  final String? nodeId;
  final String? goalId;
  final int? revision;
  final String? filterName;
  final double? score;
  final double? threshold;
  final int? evidenceFrames;
  final int? confirmationFrames;
}

/// A replay-debug decision row the native executor logged.
final class DecisionLogged extends SequencerRunEvent {
  const DecisionLogged({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    this.timestampIso,
    this.category,
    this.summary,
    this.detailsJson,
    this.nodeId,
    this.sequenceRunId,
  });

  final String? timestampIso;
  final String? category;
  final String? summary;
  final String? detailsJson;
  final String? nodeId;
  final int? sequenceRunId;
}

/// A sequencer event no consumer here reads (scheduler decisions, photometry,
/// recovery, ...). Kept so a trace can still name it.
final class UnrecognizedSequencerEvent extends SequencerRunEvent {
  const UnrecognizedSequencerEvent({
    required super.eventType,
    required super.timestamp,
    required super.severity,
    required this.data,
  });

  final Map<String, dynamic> data;
}

SequencerRunEvent _decode(SkotiqEvent event) {
  final d = _Fields(event.data);
  final type = event.eventType;
  final ts = event.timestamp;
  final sev = event.severity;

  switch (type) {
    case 'Started':
    case 'SequenceStarted':
      return RunStarted(
        eventType: type,
        timestamp: ts,
        severity: sev,
        sequenceName: d.string('sequence_name'),
      );
    case 'Paused':
    case 'SequencePaused':
      return RunPaused(eventType: type, timestamp: ts, severity: sev);
    case 'Resumed':
    case 'SequenceResumed':
      return RunResumed(eventType: type, timestamp: ts, severity: sev);
    case 'Stopped':
    case 'SequenceStopped':
      return RunStopped(
        eventType: type,
        timestamp: ts,
        severity: sev,
        sequenceRunId: d.integer('sequence_run_id'),
      );
    case 'Completed':
    case 'SequenceCompleted':
      return RunCompleted(eventType: type, timestamp: ts, severity: sev);
    case 'SequenceFailed':
      return RunFailed(
        eventType: type,
        timestamp: ts,
        severity: sev,
        error: d.string('error'),
      );
    case 'Cancelled':
    case 'SequenceCancelled':
      return RunCancelled(eventType: type, timestamp: ts, severity: sev);

    case 'NodeStarted':
      return NodeStarted(
        eventType: type,
        timestamp: ts,
        severity: sev,
        nodeId: d.string('node_id') ?? d.string('nodeId'),
        nodeType: d.string('node_type') ?? d.string('nodeName'),
      );
    case 'NodeCompleted':
      final legacySuccess = d.boolean('success');
      return NodeCompleted(
        eventType: type,
        timestamp: ts,
        severity: sev,
        nodeId: d.string('node_id') ?? d.string('nodeId'),
        status:
            d.string('status') ??
            (legacySuccess == null
                ? null
                : (legacySuccess ? 'success' : 'failed')),
      );

    case 'ExposureStarted':
      return ExposureStarted(
        eventType: type,
        timestamp: ts,
        severity: sev,
        frame: d.integer('frame'),
        total: d.integer('total'),
        filter: d.string('filter'),
        durationSecs: d.real('duration_secs'),
      );
    case 'ExposureCompleted':
      return ExposureCompleted(
        eventType: type,
        timestamp: ts,
        severity: sev,
        frame: d.integer('frame'),
        total: d.integer('total'),
        durationSecs: d.real('duration_secs'),
        filter: d.string('filter'),
      );
    case 'Progress':
      return ExposureCountProgress(
        eventType: type,
        timestamp: ts,
        severity: sev,
        current: d.integer('current'),
        total: d.integer('total'),
      );

    case 'TargetStarted':
    case 'TargetChanged':
      return TargetChanged(
        eventType: type,
        timestamp: ts,
        severity: sev,
        targetName: d.string('target_name') ?? d.string('name'),
        ra: d.real('ra'),
        dec: d.real('dec'),
      );
    case 'TargetCompleted':
      return TargetCompleted(
        eventType: type,
        timestamp: ts,
        severity: sev,
        targetName: d.string('target_name') ?? d.string('name'),
      );

    case 'Error':
      return SequencerError(
        eventType: type,
        timestamp: ts,
        severity: sev,
        message: d.string('message'),
      );

    case 'InstructionProgress':
      return InstructionProgress(
        eventType: type,
        timestamp: ts,
        severity: sev,
        nodeId: d.string('node_id'),
        instruction: d.string('instruction'),
        progressPercent: d.real('progress_percent'),
        detail: d.string('detail'),
      );
    case 'InstructionProgressStructured':
      final detailKind = d.string('detail_kind') ?? 'Unknown';
      if (detailKind == frameAssessedDetailKind ||
          detailKind == horizonObstructionDetailKind) {
        final detail = decodeStructuredProgressJson(event.data['detail_json']);
        final decoded = detail is Map
            ? _decodeFrameWatchDetail(
                detailKind,
                Map<String, dynamic>.from(detail),
                type: type,
                timestamp: ts,
                severity: sev,
                nodeId: d.string('node_id'),
              )
            : null;
        if (decoded != null) return decoded;
      }
      if (detailKind == ditherPerformedDetailKind) {
        return DitherPerformed(
          eventType: type,
          timestamp: ts,
          severity: sev,
          nodeId: d.string('node_id'),
        );
      }
      return StructuredInstructionProgress(
        eventType: type,
        timestamp: ts,
        severity: sev,
        nodeId: d.string('node_id'),
        instruction: d.string('instruction'),
        progressPercent: d.real('progress_percent'),
        detailKind: detailKind,
        detailJson: decodeStructuredProgressJson(event.data['detail_json']),
      );

    case 'MeridianFlipOutcome':
      final steps = event.data['failed_steps'];
      return MeridianFlipOutcome(
        eventType: type,
        timestamp: ts,
        severity: sev,
        outcome: d.string('outcome'),
        targetName: d.string('target_name'),
        newPierSide: d.string('new_pier_side'),
        attempts: d.integer('attempts'),
        durationSecs: d.real('duration_secs'),
        error: d.string('error'),
        actionTaken: d.string('action_taken'),
        failedSteps: steps is List
            ? steps.map((e) => e.toString()).toList(growable: false)
            : const <String>[],
      );

    case 'TriggerFired':
      return TriggerFired(
        eventType: type,
        timestamp: ts,
        severity: sev,
        triggerId: d.string('trigger_id'),
        triggerName: d.string('trigger_name'),
        action: d.string('action'),
      );

    case 'FrameAccepted':
      return FrameAccepted(
        eventType: type,
        timestamp: ts,
        severity: sev,
        capture: FrameCapture.fromEventData(event.data),
        nodeId: d.string('node_id'),
        frame: d.integer('frame'),
        total: d.integer('total'),
        hfr: d.real('hfr'),
        eccentricity: d.real('eccentricity'),
        starCount: d.integer('star_count'),
        filter: d.string('filter'),
        durationSecs: d.real('duration_secs'),
        savePath: d.string('save_path'),
      );
    case 'FrameRejected':
      return FrameRejected(
        eventType: type,
        timestamp: ts,
        severity: sev,
        capture: FrameCapture.fromEventData(event.data),
        nodeId: d.string('node_id'),
        frame: d.integer('frame'),
        total: d.integer('total'),
        hfr: d.real('hfr'),
        eccentricity: d.real('eccentricity'),
        starCount: d.integer('star_count'),
        filter: d.string('filter'),
        durationSecs: d.real('duration_secs'),
        rejectPath: d.string('reject_path'),
        reason: d.string('reason'),
        consecutiveRejects: d.integer('consecutive_rejects'),
      );

    case 'PluginNodeRequested':
      return PluginNodeRequested(
        eventType: type,
        timestamp: ts,
        severity: sev,
        nodeId: d.string('node_id'),
        pluginId: d.string('plugin_id'),
        nodeTypeId: d.string('node_type_id'),
        configJson: d.string('config_json'),
        displayName: d.string('display_name'),
        timeoutSecs: d.integer('timeout_secs'),
      );
    case 'PluginNodeProgress':
      return PluginNodeProgress(
        eventType: type,
        timestamp: ts,
        severity: sev,
        nodeId: d.string('node_id'),
        pluginId: d.string('plugin_id'),
        nodeTypeId: d.string('node_type_id'),
        detailJson: d.string('detail_json'),
      );

    case 'DepthGoalCompleted':
      return DepthGoalCompleted(
        eventType: type,
        timestamp: ts,
        severity: sev,
        nodeId: d.string('node_id'),
        goalId: d.string('goal_id'),
        revision: d.integer('revision'),
        filterName: d.string('filter_name'),
        score: d.real('score'),
        threshold: d.real('threshold'),
        evidenceFrames: d.integer('evidence_frames'),
        confirmationFrames: d.integer('confirmation_frames'),
      );

    case 'DecisionLogged':
      return DecisionLogged(
        eventType: type,
        timestamp: ts,
        severity: sev,
        timestampIso: d.string('timestamp_iso'),
        category: d.string('category'),
        summary: d.string('summary'),
        detailsJson: d.string('details_json'),
        nodeId: d.string('node_id'),
        sequenceRunId: d.integer('sequence_run_id'),
      );

    default:
      return UnrecognizedSequencerEvent(
        eventType: type,
        timestamp: ts,
        severity: sev,
        data: event.data,
      );
  }
}

/// Decode a frame-watch payload; null when a field the event cannot do
/// without is missing, so it falls through as plain structured progress.
SequencerRunEvent? _decodeFrameWatchDetail(
  String detailKind,
  Map<String, dynamic> json, {
  required String type,
  required int timestamp,
  required EventSeverity severity,
  required String? nodeId,
}) {
  final f = _Fields(json);
  if (detailKind == frameAssessedDetailKind) {
    return FrameAssessed(
      eventType: type,
      timestamp: timestamp,
      severity: severity,
      nodeId: nodeId,
      savePath: f.string('save_path'),
      filter: f.string('filter'),
      exposureSecs: f.real('exposure_secs'),
      wasAccepted: f.boolean('was_accepted') ?? true,
      solveAttempted: f.boolean('solve_attempted') ?? false,
      plateSolved: f.boolean('plate_solved') ?? false,
      solvedRaDeg: f.real('solved_ra_deg'),
      solvedDecDeg: f.real('solved_dec_deg'),
      solvedRotationDeg: f.real('solved_rotation_deg'),
      solvedPixelScale: f.real('solved_pixel_scale'),
      offsetArcmin: f.real('offset_arcmin'),
      guideRmsTotal: f.real('guide_rms_total'),
      guideRmsSamples: f.integer('guide_rms_samples'),
      backgroundAdu: f.real('background_adu'),
      starCount: f.integer('star_count'),
      altitudeDeg: f.real('altitude_deg'),
      azimuthDeg: f.real('azimuth_deg'),
      pierSide: f.string('pier_side'),
      offTarget: f.boolean('off_target') ?? false,
      obstructed: f.boolean('obstructed') ?? false,
      exclusionReason: f.string('exclusion_reason'),
    );
  }
  final altitude = f.real('altitude_deg');
  final azimuth = f.real('azimuth_deg');
  if (altitude == null || azimuth == null) return null;
  return HorizonObstructionDetected(
    eventType: type,
    timestamp: timestamp,
    severity: severity,
    nodeId: nodeId,
    altitudeDeg: altitude,
    azimuthDeg: azimuth,
    targetName: f.string('target_name'),
    latitude: f.real('latitude'),
    longitude: f.real('longitude'),
    verdict: f.string('verdict'),
    action: f.string('action'),
    message: f.string('message'),
  );
}

/// Lenient typed reads over an event `data` map: a missing key or a value of
/// the wrong type reads as null.
extension type const _Fields(Map<String, dynamic> data) {
  String? string(String key) {
    final v = data[key];
    return v is String ? v : null;
  }

  /// FRB can hand over a 64-bit value as a [BigInt], and the headless wire
  /// encoder sends one beyond 2^53 as a decimal string.
  int? integer(String key) => switch (data[key]) {
    final num v => v.toInt(),
    final BigInt v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };

  double? real(String key) {
    final v = data[key];
    return v is num ? v.toDouble() : null;
  }

  bool? boolean(String key) {
    final v = data[key];
    return v is bool ? v : null;
  }
}

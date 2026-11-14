/// The run's sequencer events as their readers take them, beside the codec
/// that decodes them: the typed event a wire event carries, the events that
/// end a run, a step's verdict, and what a structured step progress reports
/// (one frame's assessment, a confirmed horizon obstruction, a dither, or the
/// step's own progress).
library;

import 'dart:convert';

import '../models/backend/event_types.dart' as wire;
import '../models/sequence/instruction_progress_detail.dart';
import '../models/sequence/run_frame_assessment.dart';
import '../models/sequence/sequence_models.dart' show NodeStatus;
import 'bridge_event_codec.dart';
import 'bridge_events.dart';

/// The sequencer event [event] carries; null for any other event.
SequencerEvent? sequencerEventOf(wire.SkotiqEvent event) {
  if (event.category != wire.EventCategory.sequencer) return null;
  return switch (typedEventFromWire(event)?.payload) {
    EventPayload_Sequencer(:final field0) => field0,
    _ => null,
  };
}

extension SequencerRunEnd on SequencerEvent {
  /// Whether the native run is over after this event: stopped, completed or
  /// failed.
  bool get endsRun => switch (this) {
    SequencerEvent_Stopped() ||
    SequencerEvent_Completed() ||
    SequencerEvent_Failed() => true,
    _ => false,
  };
}

/// The statuses the native executor puts on `NodeCompleted`.
const Set<String> knownNodeStatuses = {
  'success',
  'skipped',
  'cancelled',
  'failed',
  'failure',
};

extension NodeVerdict on SequencerEvent_NodeCompleted {
  /// [status] as a [NodeStatus]. Any status other than success / skipped /
  /// cancelled reads as a failure. A step the operator stopped part way is
  /// cancelled, not skipped: it ran, and may have taken frames.
  NodeStatus get nodeStatus => switch (status) {
    'success' => NodeStatus.success,
    'skipped' => NodeStatus.skipped,
    'cancelled' => NodeStatus.cancelled,
    _ => NodeStatus.failure,
  };
}

/// Decode a `detail_json` payload. The native side sends the step's
/// `ProgressDetail` as a JSON string; an empty string is an empty payload,
/// and one that does not parse is kept as `{'raw': ...}` so a display can
/// still show it and a numeric reader reads no numbers from it.
Object? decodeStructuredProgressJson(String raw) {
  if (raw.trim().isEmpty) return const <String, Object?>{};
  try {
    return jsonDecode(raw);
  } on FormatException {
    return {'raw': raw};
  }
}

extension StepReport on SequencerEvent_InstructionProgressStructured {
  /// The decoded `detail_json`.
  Object? get detailValue => decodeStructuredProgressJson(detailJson);

  /// What the step reports, read by its kind.
  InstructionProgressDetail get detail =>
      InstructionProgressDetail.fromStructuredData(
        detailKind: detailKind,
        detailJson: detailValue,
      );

  /// One dither the run performed, whoever asked for it.
  bool get reportsDither => detailKind == ditherPerformedDetailKind;

  /// The native frame watch's verdict on one saved frame; null for any other
  /// report.
  FrameAssessment? get frameAssessment => detailKind == frameAssessedDetailKind
      ? FrameAssessment.fromJson(detailValue)
      : null;

  /// A confirmed obstruction the run met; null for any other report, or one
  /// that does not say where on the sky it began.
  HorizonObstruction? get horizonObstruction =>
      detailKind == horizonObstructionDetailKind
      ? HorizonObstruction.fromJson(detailValue)
      : null;

  /// The running filter's name, which only a Change Filter instruction puts
  /// on the wire; null for every other report.
  String? get changedFilterName {
    if (detailKind != 'Filter') return null;
    final json = detailValue;
    if (json is! Map) return null;
    final name = json['name'];
    return name is String && name.isNotEmpty ? name : null;
  }
}

/// A frame the grader ruled on: `FrameAccepted` or `FrameRejected`.
extension type const FrameVerdict._(SequencerEvent event) {
  /// [event] as a verdict; null for any other event.
  static FrameVerdict? of(SequencerEvent event) => switch (event) {
    SequencerEvent_FrameAccepted() ||
    SequencerEvent_FrameRejected() => FrameVerdict._(event),
    _ => null,
  };

  bool get accepted => event is SequencerEvent_FrameAccepted;

  /// The file on disk: the save path when accepted, the reject path when not.
  String? get filePath => switch (event) {
    SequencerEvent_FrameAccepted(:final savePath) => savePath,
    SequencerEvent_FrameRejected(:final rejectPath) => rejectPath,
    _ => null,
  };

  /// The grader's reason for a rejection; null for an accepted frame.
  String? get reason => switch (event) {
    SequencerEvent_FrameRejected(:final reason) => reason,
    _ => null,
  };

  String get nodeId => _pick((a) => a.nodeId, (r) => r.nodeId);
  int get frame => _pick((a) => a.frame, (r) => r.frame);
  double? get hfr => _pick((a) => a.hfr, (r) => r.hfr);
  double? get eccentricity =>
      _pick((a) => a.eccentricity, (r) => r.eccentricity);
  int? get starCount => _pick((a) => a.starCount, (r) => r.starCount);

  /// The capture truth the FITS header was written from.
  FrameCaptureMetadata get capture => _pick((a) => a.capture, (r) => r.capture);

  T _pick<T>(
    T Function(SequencerEvent_FrameAccepted) accepted,
    T Function(SequencerEvent_FrameRejected) rejected,
  ) => switch (event) {
    final SequencerEvent_FrameAccepted a => accepted(a),
    final SequencerEvent_FrameRejected r => rejected(r),
    _ => throw StateError('$event is not a frame verdict'),
  };
}

// Sequencer events as a host sends them: the typed event through the
// generated codec, so a test cannot feed a shape production does not send.

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';

/// [event] as a wire event.
SkotiqEvent sequencerWireEvent(
  bridge.SequencerEvent event, {
  EventSeverity severity = EventSeverity.info,
  int? timestamp,
}) {
  final (type, data) = bridge.encodeEventPayload(
    bridge.EventPayload.sequencer(event),
  );
  return SkotiqEvent(
    timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch,
    severity: severity,
    category: EventCategory.sequencer,
    eventType: type,
    data: Map<String, dynamic>.from(data),
  );
}

/// The capture record of a light frame of [exposureSecs], binned [bin], from
/// a camera that reported [gain] and [offset].
bridge.FrameCaptureMetadata testCapture({
  double exposureSecs = 60.0,
  int bin = 1,
  int? gain,
  int? offset,
  String frameType = 'Light',
}) => bridge.FrameCaptureMetadata(
  gain: gain,
  gainIsIso: false,
  offset: offset,
  exposureSecs: exposureSecs,
  binX: bin,
  binY: bin,
  frameType: frameType,
);

/// A grader's verdict on one saved frame, as the wire carries it.
SkotiqEvent frameVerdictEvent({
  required bool accepted,
  required String nodeId,
  String? path,
  int frame = 1,
  int total = 1,
  double? hfr,
  int? starCount,
  String reason = 'rejected by the grader',
  bridge.FrameCaptureMetadata? capture,
}) => sequencerWireEvent(
  accepted
      ? bridge.SequencerEvent.frameAccepted(
          nodeId: nodeId,
          frame: frame,
          total: total,
          hfr: hfr,
          starCount: starCount,
          acceptedTotal: frame,
          rejectedTotal: 0,
          savePath: path,
          capture: capture ?? testCapture(),
        )
      : bridge.SequencerEvent.frameRejected(
          nodeId: nodeId,
          frame: frame,
          total: total,
          reason: reason,
          hfr: hfr,
          starCount: starCount,
          rejectPath: path ?? '',
          consecutiveRejects: 1,
          acceptedTotal: 0,
          rejectedTotal: frame,
          evidence: const [],
          capture: capture ?? testCapture(),
        ),
);

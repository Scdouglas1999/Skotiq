/// How many frames each exposure node has actually captured — the ONE channel
/// that only exposure-shaped progress can write.
///
/// Counting frames by parsing the node's *display string* out of
/// `SequenceProgress.nodeProgressDetail[nodeId]` cannot work. That map is a
/// single slot shared by every instruction that reports against the node, and
/// the native executor writes it several times per node from different
/// producers. A log one millisecond after a four-frame burst finishes shows how
/// the count dies:
///
/// ```
/// 04:10:05.978257  NodeProgress node=7837c026… instruction=Exposure          progress=100%
/// 04:10:05.978300  NodeProgress node=7837c026… instruction=IntegrationBudget progress=0%
/// 04:10:05.978320  NodeProgress node=9617e5f0… instruction=AdaptiveExposure  progress=0%
/// ```
///
/// `emit_budget_progress` (native `node/instructions/expose.rs`) fires once per
/// successful burst, against the SAME node id, and overwrites both the string
/// detail and the structured detail with an `IntegrationBudget` payload that no
/// exposure parser can read, so the card falls back to frame 0 and prints
/// "0 / 4 frames" with four empty boxes — directly above the four thumbnails
/// the node just captured. The next node opens with an `AdaptiveExposure`
/// payload at 0%, which reads back as exactly the same "0 / 4 frames", so the
/// card cannot tell "captured everything" from "captured nothing".
///
/// No fix on the reader side — node status, a retention window, a second string
/// wording — can recover it: the number is gone from the provider before any
/// reader runs. This tally is a separate slot, so an unrelated instruction
/// reporting against the node cannot erase the frames it took.
library;

import '../../models/backend/event_types.dart';
import 'run_record.dart';
import 'sequencer_run_event.dart';

/// Frames captured, and frames planned, for one exposure node's current pass.
class NodeExposureTally {
  /// Frames the executor has reported CAPTURED for this node.
  final int captured;

  /// Frames the node planned for this pass.
  final int planned;

  const NodeExposureTally({required this.captured, required this.planned});

  @override
  bool operator ==(Object other) =>
      other is NodeExposureTally &&
      other.captured == captured &&
      other.planned == planned;

  @override
  int get hashCode => Object.hash(captured, planned);

  @override
  String toString() => 'NodeExposureTally($captured/$planned)';
}

/// Per-node captured-frame tally, keyed by node id.
final nodeExposureTallyProvider = runRecordProvider.select((run) => run.tally);

/// Fold ONE sequencer event into the per-node exposure tally.
///
/// The whole write path: the executor, the DeviceService pump and the widget
/// tests all go through it, so a test cannot pass against an event shape
/// production does not handle.
void applySequencerEventToNodeExposureTally(
  RunRecordNotifier tally,
  SkotiqEvent event,
) {
  final typed = SequencerRunEvent.fromSkotiqEvent(event);
  if (typed != null) applyRunEventToNodeExposureTally(tally, typed);
}

/// [applySequencerEventToNodeExposureTally] for an already-decoded event.
///
/// Only a node-addressed `Exposure` structured progress is counted.
/// `ExposureStarted` / `ExposureCompleted` name no node, and attributing them
/// to the current node credits the next node with the previous node's last
/// frame when `NodeStarted` overtakes it.
void applyRunEventToNodeExposureTally(
  RunRecordNotifier tally,
  SequencerRunEvent event,
) {
  switch (event) {
    case NodeStarted(:final nodeId?):
      tally.startNode(nodeId);
    case StructuredInstructionProgress(
          detailKind: 'Exposure',
          :final nodeId?,
          :final detailJson,
        )
        when nodeId.isNotEmpty:
      if (detailJson is! Map) return;
      final frame =
          _asInt(detailJson['frame']) ?? _asInt(detailJson['current_frame']);
      final total =
          _asInt(detailJson['total']) ?? _asInt(detailJson['total_frames']);
      if (frame == null || total == null) return;
      // The native per-frame callback fires after a frame lands, so `frame` is
      // the number of frames CAPTURED, not the one in flight.
      tally.recordFrames(nodeId, captured: frame, planned: total);
    default:
      return;
  }
}

int? _asInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

import 'package:skotiq_bridge/skotiq_bridge.dart'
    show EventPayload_Sequencer, SequencerErrorKind, SequencerEvent_Error;

import '../models/backend/event_types.dart';
import 'bridge_event_codec.dart';

extension SequencerErrorKindMeaning on SequencerErrorKind {
  /// Whether the run goes on taking frames after this: a note, or a problem
  /// it carried on through.
  bool get runContinues =>
      this == SequencerErrorKind.advisory ||
      this == SequencerErrorKind.stepProblem;
}

/// The sequencer `Error` a wire [event] is, or null when it is another event.
/// The host's sequencer decides what an error means for the run where the
/// problem happens and sends it as the error's kind; nothing works it out
/// from the severity or the text.
SequencerEvent_Error? sequencerErrorOf(SkotiqEvent event) {
  final payload = typedEventFromWire(event)?.payload;
  if (payload is! EventPayload_Sequencer) return null;
  final error = payload.field0;
  return error is SequencerEvent_Error ? error : null;
}

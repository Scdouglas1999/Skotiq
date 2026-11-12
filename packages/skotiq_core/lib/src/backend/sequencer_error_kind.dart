import 'package:skotiq_bridge/skotiq_bridge.dart' show SequencerErrorKind;

import '../models/backend/event_types.dart';

/// Key of the kind in a sequencer `Error` event's data. The host's sequencer
/// decides what an error means for the run where the problem happens and
/// sends it here; nothing works it out from the severity or the text.
const String kSequencerErrorKindKey = 'kind';

extension SequencerErrorKindWire on SequencerErrorKind {
  /// The value of the event's `kind` field.
  String get wireName => switch (this) {
    SequencerErrorKind.advisory => 'advisory',
    SequencerErrorKind.stepProblem => 'step_problem',
    SequencerErrorKind.runHeld => 'run_held',
    SequencerErrorKind.stepFailed => 'step_failed',
    SequencerErrorKind.standalone => 'standalone',
  };

  /// Whether the run goes on taking frames after this: a note, or a problem
  /// it carried on through.
  bool get runContinues =>
      this == SequencerErrorKind.advisory ||
      this == SequencerErrorKind.stepProblem;
}

/// The kind named [wireName]. A host from before the field existed sends
/// none: its warnings were notes and everything else a failing step.
SequencerErrorKind sequencerErrorKindFromWire(
  Object? wireName, {
  required EventSeverity severity,
}) {
  for (final kind in SequencerErrorKind.values) {
    if (kind.wireName == wireName) return kind;
  }
  return severity == EventSeverity.warning
      ? SequencerErrorKind.advisory
      : SequencerErrorKind.stepFailed;
}

/// The kind a sequencer `Error` [event] carries.
SequencerErrorKind sequencerErrorKindOf(SkotiqEvent event) =>
    sequencerErrorKindFromWire(
      event.data[kSequencerErrorKindKey],
      severity: event.severity,
    );

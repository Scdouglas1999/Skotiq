// The operator's Stop arrives on the wire as a sequencer ERROR carrying the
// verbatim notice "Sequence cancelled" (native executor, NodeStatus::Cancelled
// arm). Every surface that reads the raw event stream has to recognise that one
// string — and NOTHING else — or it either cries wolf over a deliberate stop or
// swallows a genuine fault whose text merely contains the word "cancelled".
//
// The counter-inputs below are strings the stack really emits.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/sequence/run_stop_classification.dart';

void main() {
  group('isSequenceCancelledNotice', () {
    test('recognises the notice the executor emits, in either spelling', () {
      expect(isSequenceCancelledNotice(kSequenceCancelledNotice), isTrue);
      expect(isSequenceCancelledNotice('Sequence cancelled'), isTrue);
      expect(isSequenceCancelledNotice('Sequence canceled'), isTrue);
      expect(isSequenceCancelledNotice('  sequence CANCELLED  '), isTrue);
    });

    // A substring test on "cancelled" swallows every one of these, so a night
    // with a real fault reports no errors at all.
    test('a real fault whose text contains "cancelled" is NOT a stop', () {
      const realFaults = <String>[
        // native/.../instructions/temperature_compensation.rs
        'Temperature compensation cancelled',
        // native/.../executor/preflight.rs documents this mid-run failure
        'Cancelled: Target',
        'focuser move was canceled by the driver',
        'slew canceled by the mount (limit switch)',
        'Autofocus cancelled: star lost',
        'Sequence cancelled by the dome roof interlock',
      ];
      for (final fault in realFaults) {
        expect(
          isSequenceCancelledNotice(fault),
          isFalse,
          reason: 'a fault must survive: $fault',
        );
      }
    });

    test('an unrelated failure is not a stop', () {
      expect(isSequenceCancelledNotice('Camera disconnected'), isFalse);
      expect(isSequenceCancelledNotice(''), isFalse);
    });
  });

  // WHO ended the run. The notice above is emitted by every cancellation path,
  // so only these rows can name a cause — and a surface that reads the notice
  // alone told an operator asleep at home that the dawn trigger's ParkAndAbort
  // was "Stopped by request".
  group('sequenceStopDecision on a fired-trigger row', () {
    String triggerDetails(String id, String name, String action) =>
        '{"trigger_id":"$id","trigger_name":"$name","action":"$action"}';

    test('a ParkAndAbort fire is authorship, named by its trigger', () {
      final decision = sequenceStopDecision(
        category: kTriggerFiredDecisionCategory,
        summary: 'Trigger Dawn Approaching fired → ParkAndAbort',
        detailsJson: triggerDetails(
          'dawn_approaching',
          'Dawn Approaching',
          kParkAndAbortTriggerAction,
        ),
      );

      expect(decision, isNotNull);
      expect(decision!.author, SequenceStopAuthor.system);
      expect(decision.origin, 'dawn_approaching');
      expect(decision.parked, isTrue);
      expect(
        sequenceStopCauseClause(decision),
        'by the Dawn Approaching trigger',
      );
      expect(
        sequenceStoppedMessage(decision),
        'Parked by the Dawn Approaching trigger',
      );
    });

    // A dither/autofocus/pause trigger fires mid-run and the run keeps going;
    // reading it as authorship would blame it for whatever ended the run an
    // hour later.
    test('a fire whose action leaves the run running names nobody', () {
      for (final action in const [
        'Continue',
        'Pause',
        'Autofocus',
        'NextTarget',
        'Dither(DitherConfig { pixels: 3.0 })',
        'Recenter',
      ]) {
        expect(
          sequenceStopDecision(
            category: kTriggerFiredDecisionCategory,
            summary: 'Trigger Focus Drift fired → $action',
            detailsJson: triggerDetails('focus_drift', 'Focus Drift', action),
          ),
          isNull,
          reason: '$action does not end the run',
        );
      }
    });

    test('a fired-trigger row with no details names nobody', () {
      expect(
        sequenceStopDecision(
          category: kTriggerFiredDecisionCategory,
          summary: 'Trigger fired',
          detailsJson: 'not json',
        ),
        isNull,
      );
    });
  });

  group('sequenceStoppedMessage', () {
    test('the operator keeps the sentence that names the operator', () {
      expect(
        sequenceStoppedMessage(
          const SequenceStopDecision(SequenceStopAuthor.operatorPress),
        ),
        kSequenceStoppedByRequestMessage,
      );
    });

    test('the autopilot says autopilot', () {
      expect(
        sequenceStoppedMessage(
          const SequenceStopDecision(SequenceStopAuthor.autopilot),
        ),
        kSequenceStoppedByAutopilotMessage,
      );
    });

    test('a subsystem stop names the subsystem', () {
      expect(
        sequenceStoppedMessage(
          const SequenceStopDecision(
            SequenceStopAuthor.system,
            origin: 'disk-watchdog',
          ),
        ),
        'Stopped by the disk-space watchdog',
      );
    });

    // The whole point: no evidence means no claim. "Stopped" is the truth a
    // bare cancel notice carries; "Stopped by request" is an invented human.
    test('no evidence claims no cause', () {
      expect(sequenceStoppedMessage(null), kSequenceStoppedMessage);
      expect(
        sequenceStoppedMessage(null),
        isNot(kSequenceStoppedByRequestMessage),
      );
    });
  });
}

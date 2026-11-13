// A run's stored error text can carry the cancellation notice. Only that exact
// notice is a stop; a genuine fault whose text merely contains the word
// "cancelled" stays an error. The counter-inputs below are strings the stack
// really emits.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show SequencerStop;
import 'package:skotiq_core/src/models/sequence/run_stop_classification.dart';

void main() {
  group('isSequenceCancelledNotice', () {
    test('recognises the notice, in either spelling', () {
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

  // WHO ended the run. Every stop sends the same cancellation, so only the
  // stop rows can name a cause.
  group('sequenceStopDecisionOf', () {
    test('a parking trigger is authorship, named by its trigger', () {
      final decision = sequenceStopDecisionOf(
        const SequencerStop.trigger(
          triggerId: 'dawn_approaching',
          triggerName: 'Dawn Approaching',
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

    test('a trigger with neither id nor name names nobody', () {
      expect(
        sequenceStopDecisionOf(
          const SequencerStop.trigger(triggerId: ' ', triggerName: ''),
        ),
        isNull,
      );
    });

    test('the operator, the autopilot and a subsystem are told apart', () {
      expect(
        sequenceStopDecisionOf(const SequencerStop.operator_())?.author,
        SequenceStopAuthor.operatorPress,
      );
      expect(
        sequenceStopDecisionOf(const SequencerStop.autopilot())?.author,
        SequenceStopAuthor.autopilot,
      );
      final system = sequenceStopDecisionOf(
        const SequencerStop.system(origin: 'rollback'),
      );
      expect(system?.author, SequenceStopAuthor.system);
      expect(system?.origin, 'rollback');
      expect(
        sequenceStopDecisionOf(const SequencerStop.system(origin: ''))?.origin,
        isNull,
      );
    });

    test('the cancellation row and a row with no stop name nobody', () {
      expect(sequenceStopDecisionOf(const SequencerStop.cancelled()), isNull);
      expect(sequenceStopDecisionOf(null), isNull);
    });
  });

  group('sequenceStopTriggerDecision on a TriggerFired event', () {
    test('a ParkAndAbort fire names its trigger', () {
      expect(
        sequenceStopTriggerDecision(
          triggerId: 'weather_unsafe',
          triggerName: 'Weather Unsafe',
          action: kParkAndAbortTriggerAction,
        )?.originLabel,
        'the Weather Unsafe trigger',
      );
    });

    // A dither/autofocus/pause trigger fires mid-run and the run keeps going;
    // reading it as authorship would blame it for whatever ended the run an
    // hour later. "Abort" ends the run without parking and names nobody.
    test('a fire whose action does not park and end the run names nobody', () {
      for (final action in const [
        'Continue',
        'Pause',
        'Autofocus',
        'NextTarget',
        'Dither',
        'Recenter',
        'Abort',
        'Notify',
      ]) {
        expect(
          sequenceStopTriggerDecision(
            triggerId: 'focus_drift',
            triggerName: 'Focus Drift',
            action: action,
          ),
          isNull,
          reason: '$action does not park and end the run',
        );
      }
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

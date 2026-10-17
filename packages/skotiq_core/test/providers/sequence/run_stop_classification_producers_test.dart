// The two-implementations trap, on the stop path.
//
// An operator Stop reaches Dart as a sequencer `Error` carrying "Sequence
// cancelled". FIVE producers can turn that into an error message:
//
//   1. NotificationEventClassifier          -> "Sequence failed" toast + push
//   2. SequenceExecutor._handleSequencerEvent -> rollup "Error: …", red node
//   2b. applySequencerEventToSequenceProviders -> the SAME rollup message,
//       from a second live subscriber on the same desktop host
//   3. runDashboardCriticalEventsBridge      -> "Critical · Sequencer" toast,
//       Dashboard banner, RECENT EVENTS row
//
// Producers 2 and 2b are the pair that hides a partial fix: correcting the
// executor's handler alone leaves the DeviceService-driven pump — subscribed
// from app start, handling the identical event — writing "Error: Sequence
// cancelled" into the same provider the target rollup reads.
//
// This file pins the behaviour of 2b directly and, for the handlers that need a
// whole executor to exercise, asserts structurally that every `case 'Error'` in
// the sequence providers consults the ONE shared predicate. If someone adds a
// third handler, or deletes the guard from one, this fails.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

SkotiqEvent _sequencerEvent(
  String eventType,
  Map<String, dynamic> data, {
  EventSeverity severity = EventSeverity.info,
}) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: severity,
  category: EventCategory.sequencer,
  eventType: eventType,
  data: data,
);

SkotiqEvent _sequencerError(String message) => _sequencerEvent('Error', {
  'message': message,
}, severity: EventSeverity.error);

/// The row the trigger monitor writes when a trigger ends the run, exactly as
/// it reached the release bundle's own DB on a dawn abort:
/// `trigger_fired | Trigger Dawn Approaching fired → ParkAndAbort`.
SkotiqEvent _triggerFired(String name, String action) =>
    _sequencerEvent('TriggerFired', {
      'trigger_id': name.toLowerCase().replaceAll(' ', '_'),
      'trigger_name': name,
      'action': action,
    }, severity: EventSeverity.warning);

SkotiqEvent _operatorStopDecision() => _sequencerEvent('DecisionLogged', {
  'category': kManualInterventionDecisionCategory,
  'summary': 'Operator: stop requested',
  'details_json': '{}',
});

void main() {
  group('the DeviceService-driven pump (producer 2b)', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

    test('an operator stop does not become "Error: Sequence cancelled"', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _operatorStopDecision(),
      );
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerError(kSequenceCancelledNotice),
      );

      final message = container.read(sequenceProgressProvider).message;
      expect(message, kSequenceStoppedByRequestMessage);
      expect(message, isNot(contains('Error')));
    });

    // The defect: the pump answered the cancel notice with the operator's
    // sentence whatever ended the run, so a weather/dawn ParkAndAbort with
    // nobody at the keyboard read "Stopped by request" on run-watch.
    test('a trigger-driven park names its trigger, not a human', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _triggerFired('Dawn Approaching', kParkAndAbortTriggerAction),
      );
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerError(kSequenceCancelledNotice),
      );

      final message = container.read(sequenceProgressProvider).message;
      expect(message, 'Parked by the Dawn Approaching trigger');
      expect(message, isNot(kSequenceStoppedByRequestMessage));
    });

    // The cancel-notice lifecycle decision lands AFTER the row that named the
    // cause and names nobody itself. It must not erase the cause.
    test('the cause survives the cause-neutral rows that follow it', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _triggerFired('Weather Unsafe', kParkAndAbortTriggerAction),
      );
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerEvent('DecisionLogged', {
          'category': kSystemEventDecisionCategory,
          'summary': kSequenceCancelledNotice,
          'details_json': '{"phase":"cancelled"}',
        }),
      );
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerError(kSequenceCancelledNotice),
      );

      expect(
        container.read(sequenceProgressProvider).message,
        'Parked by the Weather Unsafe trigger',
      );
    });

    test('a cancel nothing on the wire explains claims no cause', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerError(kSequenceCancelledNotice),
      );

      final message = container.read(sequenceProgressProvider).message;
      expect(message, kSequenceStoppedMessage);
      expect(message, isNot(kSequenceStoppedByRequestMessage));
      expect(message, isNot(contains('Error')));
    });

    // One night's cause may never be attached to the next night's stop.
    test('a new run clears the previous run\'s cause', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _triggerFired('Dawn Approaching', kParkAndAbortTriggerAction),
      );
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerEvent('Started', {'sequence_name': 'Night two'}),
      );
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerError(kSequenceCancelledNotice),
      );

      expect(
        container.read(sequenceProgressProvider).message,
        kSequenceStoppedMessage,
      );
    });

    test('a real fault is still reported as an error', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerError('Temperature compensation cancelled'),
      );

      expect(
        container.read(sequenceProgressProvider).message,
        'Error: Temperature compensation cancelled',
      );
    });
  });

  // Structural guard for the implementations a unit test cannot reach cheaply.
  // Both files below own a `case 'Error':` for the SAME wire event.
  test('every sequencer-Error handler consults the shared predicate', () {
    const handlers = <String>[
      'lib/src/providers/sequence/sequence_progress.dart',
      'lib/src/providers/sequence/sequence_executor/event_operations.dart',
    ];
    for (final path in handlers) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        contains("case 'Error':"),
        reason:
            '$path no longer handles the sequencer Error event — if the '
            'handler moved, move this pin with it.',
      );
      expect(
        source,
        contains('isSequenceCancelledNotice('),
        reason:
            '$path handles a sequencer Error without asking whether it is '
            'the operator\'s Stop. That is the defect this file keeps '
            'reopening: one producer fixed, the other still crying wolf.',
      );
      expect(
        source,
        contains('sequenceStoppedMessage('),
        reason:
            '$path answers the cancel notice without asking WHO ended the '
            'run. The notice is identical for an operator Stop and for a '
            'dawn/weather ParkAndAbort, so the constant is a guess.',
      );
      expect(
        source,
        isNot(contains('message: kSequenceStoppedByRequestMessage')),
        reason:
            '$path writes the operator\'s sentence as a constant again. The '
            'cause has to come from the run\'s own authorship rows.',
      );
    }
  });
}

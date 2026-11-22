// The two-implementations trap, on the stop path.
//
// Every stop reaches Dart as a sequencer `Error` of kind `cancelled`. FIVE
// producers can turn that into an error message:
//
//   1. NotificationEventClassifier          -> "Sequence failed" toast + push
//   2. RunEventHandler.handle (the executor) -> rollup "Error: …", red node
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
// This file drives 2b and 2 with the same wire rows, so a fix to one producer
// that misses the other fails here.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

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
  'kind': 'step_failed',
}, severity: EventSeverity.error);

/// A stopped run's cancellation, as the host sends it.
SkotiqEvent _cancellation() => _sequencerEvent('Error', {
  'message': kSequenceCancelledNotice,
  'kind': 'cancelled',
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
  'category': 'manual_intervention',
  'summary': 'Operator: stop',
  'details_json': '{"action":"stop"}',
  'stop': {'by': 'operator'},
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
      applySequencerEventToSequenceProviders(container.read, _cancellation());

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
        _triggerFired('Dawn Approaching', 'ParkAndAbort'),
      );
      applySequencerEventToSequenceProviders(container.read, _cancellation());

      final message = container.read(sequenceProgressProvider).message;
      expect(message, 'Parked by the Dawn Approaching trigger');
      expect(message, isNot(kSequenceStoppedByRequestMessage));
    });

    // The cancel-notice lifecycle decision lands AFTER the row that named the
    // cause and names nobody itself. It must not erase the cause.
    test('the cause survives the cause-neutral rows that follow it', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _triggerFired('Weather Unsafe', 'ParkAndAbort'),
      );
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerEvent('DecisionLogged', {
          'category': 'system_event',
          'summary': kSequenceCancelledNotice,
          'details_json': '{"phase":"cancelled"}',
          'stop': {'by': 'cancelled'},
        }),
      );
      applySequencerEventToSequenceProviders(container.read, _cancellation());

      expect(
        container.read(sequenceProgressProvider).message,
        'Parked by the Weather Unsafe trigger',
      );
    });

    test('a cancel nothing on the wire explains claims no cause', () {
      applySequencerEventToSequenceProviders(container.read, _cancellation());

      final message = container.read(sequenceProgressProvider).message;
      expect(message, kSequenceStoppedMessage);
      expect(message, isNot(kSequenceStoppedByRequestMessage));
      expect(message, isNot(contains('Error')));
    });

    // One night's cause may never be attached to the next night's stop.
    test('a new run clears the previous run\'s cause', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _triggerFired('Dawn Approaching', 'ParkAndAbort'),
      );
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerEvent('Started', {'sequence_name': 'Night two'}),
      );
      applySequencerEventToSequenceProviders(container.read, _cancellation());

      expect(
        container.read(sequenceProgressProvider).message,
        kSequenceStoppedMessage,
      );
    });

    test('a system stop names the part of the system that stopped it', () {
      applySequencerEventToSequenceProviders(
        container.read,
        _sequencerEvent('DecisionLogged', {
          'category': 'system_event',
          'summary': 'System: stop',
          'details_json': '{"origin":"disk-watchdog","action":"stop"}',
          'stop': {'by': 'system', 'origin': 'disk-watchdog'},
        }),
      );
      applySequencerEventToSequenceProviders(container.read, _cancellation());

      expect(
        container.read(sequenceProgressProvider).message,
        'Stopped by the disk-space watchdog',
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

  // Producer 2: the executor's own subscriber handles the identical event.
  // Fixing one producer and not the other is the defect this file keeps
  // reopening, so the executor is driven with the same wire rows.
  group('the executor\'s event handler (producer 2)', () {
    late MockBackend backend;
    late StreamController<SkotiqEvent> events;
    late SkotiqDatabase db;
    late ProviderContainer container;
    late SequenceExecutor executor;

    setUp(() {
      backend = MockBackend();
      events = StreamController<SkotiqEvent>.broadcast();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      container.read(runRecordProvider.notifier).setStats(SequenceRunStats());
      container
          .read(runRecordProvider.notifier)
          .setLifecycle(SequenceExecutionState.running);
      executor = container.read(sequenceExecutorProvider);
    });

    tearDown(() async {
      container.dispose();
      await events.close();
      await db.close();
    });

    test('an operator stop does not become "Error: Sequence cancelled"', () {
      executor.handleSequencerEventForTest(_operatorStopDecision());
      executor.handleSequencerEventForTest(_cancellation());

      final message = container.read(sequenceProgressProvider).message;
      expect(message, kSequenceStoppedByRequestMessage);
      expect(message, isNot(contains('Error')));
      expect(container.read(liveSequenceStatsProvider)!.errorMessages, isEmpty);
    });

    test('a trigger-driven park names its trigger, not a human', () {
      executor.handleSequencerEventForTest(
        _triggerFired('Dawn Approaching', 'ParkAndAbort'),
      );
      executor.handleSequencerEventForTest(_cancellation());

      expect(
        container.read(sequenceProgressProvider).message,
        'Parked by the Dawn Approaching trigger',
      );
    });

    test('a real fault is still reported as an error', () {
      executor.handleSequencerEventForTest(
        _sequencerError('Temperature compensation cancelled'),
      );

      expect(
        container.read(sequenceProgressProvider).message,
        'Error: Temperature compensation cancelled',
      );
    });
  });
}

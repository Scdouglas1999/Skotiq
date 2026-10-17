// One press of Stop is one row in RECENT EVENTS.
//
// A Stop puts FOUR events on the wire, and a feed writer that renders each one
// as its own row triplicates it: three 'Sequence stopped' rows at the same
// second plus 'Decision logged - system_event #15: Sequence cancelled'. The
// four, in the order the native side emits them:
//
//   1. `ExecutorEvent::Error { message: "Sequence cancelled" }`
//      — sequencer/src/executor/start.rs, the `NodeStatus::Cancelled` arm.
//   2. the lifecycle decision, summary "Sequence cancelled"
//      — executor/trigger_context.rs:724-729 via `emit_lifecycle_decision`.
//   3. `SequencerEvent::Stopped`, translated from
//      `StateChanged(ExecutorState::Cancelled)`
//      — bridge/src/api/sequencer/event_bridge.rs:196.
//   4. `SequencerEvent::Stopped` again, published by the stop API itself
//      — bridge/src/api/sequencer/lifecycle.rs:175.
//
// A collapse that folds only ADJACENT rows with byte-identical content cannot
// catch them: the four render three different messages ('Stopped by request',
// '', 'system_event #15: Sequence cancelled') with the decision row sitting
// between them.
//
// The feed is how an operator reconstructs their night. One press of Stop is
// one thing that happened.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;
import 'package:skotiq_core/skotiq_core.dart';

final _stopAt = DateTime(2026, 8, 13, 1, 54, 26);

bridge_event.SkotiqEvent _error(int id, String message, DateTime at) =>
    bridge_event.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: bridge_event.EventSeverity.error,
      category: bridge_event.EventCategory.sequencer,
      payload: bridge_event.EventPayload.sequencer(
        bridge_event.SequencerEvent.error(message: message),
      ),
    );

bridge_event.SkotiqEvent _lifecycleDecision(
  int id,
  String summary,
  DateTime at,
) =>
    bridge_event.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: bridge_event.EventSeverity.info,
      category: bridge_event.EventCategory.sequencer,
      payload: bridge_event.EventPayload.sequencer(
        bridge_event.SequencerEvent.decisionLogged(
          timestampIso: at.toUtc().toIso8601String(),
          category: 'system_event',
          summary: summary,
          detailsJson: '{"phase":"cancelled"}',
          sequenceRunId: 15,
        ),
      ),
    );

bridge_event.SkotiqEvent _stopped(int id, DateTime at) =>
    bridge_event.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: bridge_event.EventSeverity.info,
      category: bridge_event.EventCategory.sequencer,
      payload: const bridge_event.EventPayload.sequencer(
        bridge_event.SequencerEvent.stopped(),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async => db.close());

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The press's producers in emission order (the notifier prepends, so the
  /// feed ends up newest-first exactly as it does live). The
  /// manual-intervention decision is what distinguishes an operator press
  /// from a safety abort — every cancellation path emits the other four.
  void pressStop(ProviderContainer container, {required int base}) {
    final history = container.read(eventHistoryProvider.notifier);
    history.addEvent(_error(base, kSequenceCancelledNotice, _stopAt));
    history.addEvent(
      _lifecycleDecision(base + 1, kSequenceCancelledNotice, _stopAt),
    );
    history.addEvent(
      bridge_event.SkotiqEvent(
        eventId: BigInt.from(base + 4),
        timestamp: _stopAt.millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.info,
        category: bridge_event.EventCategory.sequencer,
        payload: bridge_event.EventPayload.sequencer(
          bridge_event.SequencerEvent.decisionLogged(
            timestampIso: _stopAt.toUtc().toIso8601String(),
            category: 'manual_intervention',
            summary: 'Operator: stop requested',
            detailsJson: '{}',
            sequenceRunId: 15,
          ),
        ),
      ),
    );
    history.addEvent(_stopped(base + 2, _stopAt));
    history.addEvent(_stopped(base + 3, _stopAt));
  }

  test('one operator Stop is one row in RECENT EVENTS', () {
    final container = makeContainer();
    pressStop(container, base: 1);

    final recent = container.read(runDashboardRecentEventsProvider(5));

    expect(
      recent,
      hasLength(1),
      reason: 'four producers of one press of Stop; the operator pressed it '
          'once. Got: ${recent.map((e) => '${e.title} / ${e.message}').toList()}',
    );
    final row = recent.single;
    expect(row.title, 'Sequence stopped');
    expect(row.message, kSequenceStoppedByRequestMessage);
    expect(row.severity, RunDashboardEventSeverity.info);
    expect(row.isCritical, isFalse);
    expect(
      row.repeatCount,
      1,
      reason: 'a "x4" badge would say it happened four times, which is the '
          'same lie in smaller type',
    );
  });

  test('the stop does not evict the rest of the night', () {
    final container = makeContainer();
    final history = container.read(eventHistoryProvider.notifier);
    // Four distinct earlier events that the triplication used to push off a
    // five-row panel.
    for (var i = 0; i < 4; i++) {
      history.addEvent(
        _error(100 + i, 'Focuser fault $i',
            _stopAt.subtract(Duration(minutes: 5 - i))),
      );
    }
    pressStop(container, base: 1);

    final recent = container.read(runDashboardRecentEventsProvider(5));
    expect(recent.first.title, 'Sequence stopped');
    expect(recent.length, 5);
    expect(
      recent.skip(1).map((e) => e.message).toList(),
      [
        'Focuser fault 3',
        'Focuser fault 2',
        'Focuser fault 1',
        'Focuser fault 0'
      ],
    );
  });

  test('a stop of an earlier run is still its own row', () {
    final container = makeContainer();
    final history = container.read(eventHistoryProvider.notifier);
    final earlier = _stopAt.subtract(const Duration(minutes: 20));
    history.addEvent(_error(1, kSequenceCancelledNotice, earlier));
    history.addEvent(_stopped(2, earlier));
    pressStop(container, base: 10);

    final recent = container.read(runDashboardRecentEventsProvider(5));
    expect(recent, hasLength(2));
    expect(recent.every((e) => e.title == 'Sequence stopped'), isTrue);
    expect(recent.first.time, _stopAt);
    expect(recent.last.time, earlier);
  });

  test('a real fault whose text contains "cancelled" keeps its own row', () {
    final container = makeContainer();
    final history = container.read(eventHistoryProvider.notifier);
    history.addEvent(
      _error(1, 'Temperature compensation cancelled', _stopAt),
    );
    pressStop(container, base: 10);

    final recent = container.read(runDashboardRecentEventsProvider(5));
    expect(recent, hasLength(2));
    expect(recent.first.title, 'Sequence stopped');
    expect(recent.last.message, 'Temperature compensation cancelled');
    expect(recent.last.severity, isNot(RunDashboardEventSeverity.info));
  });
}

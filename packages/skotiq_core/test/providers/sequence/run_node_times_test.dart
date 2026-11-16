// The one record of when a run's nodes started and finished, and the
// lifetime its readers depend on: it outlives the screens that read it, and
// only the next run clears it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

final DateTime _t0 = DateTime.utc(2026, 9, 14, 2, 0);

bridge.SkotiqEvent _event(bridge.SequencerEvent payload, DateTime at) =>
    bridge.SkotiqEvent(
      eventId: BigInt.from(at.millisecondsSinceEpoch),
      timestamp: at.millisecondsSinceEpoch,
      severity: bridge.EventSeverity.info,
      category: bridge.EventCategory.sequencer,
      payload: bridge.EventPayload.sequencer(payload),
    );

bridge.SkotiqEvent _runStarted(DateTime at) =>
    _event(const bridge.SequencerEvent.started(sequenceName: 'Night'), at);

bridge.SkotiqEvent _nodeStarted(String nodeId, DateTime at) => _event(
  bridge.SequencerEvent.nodeStarted(nodeId: nodeId, nodeType: 'Delay'),
  at,
);

bridge.SkotiqEvent _nodeCompleted(String nodeId, DateTime at) => _event(
  bridge.SequencerEvent.nodeCompleted(nodeId: nodeId, status: 'success'),
  at,
);

/// Let Riverpod's auto-dispose pass, and the stream cancellation it triggers.
Future<void> _settle() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// No widget binding: with one, auto-disposal waits for frames a plain `test`
// never pumps, and the lifetime checks below would pass vacuously.
void main() {
  late StreamController<bridge.SkotiqEvent> events;
  late ProviderContainer container;

  setUp(() {
    events = StreamController<bridge.SkotiqEvent>.broadcast();
    container = ProviderContainer(
      overrides: [skotiqEventsProvider.overrideWith((ref) => events.stream)],
    );
  });

  tearDown(() {
    container.dispose();
    events.close();
  });

  test('records starts and successful completions', () async {
    container.listen(runNodeTimesProvider, (_, __) {});
    final started = _t0.add(const Duration(minutes: 7));
    final done = _t0.add(const Duration(minutes: 12));
    events
      ..add(_nodeStarted('b', started))
      ..add(_nodeCompleted('b', done));
    await _settle();

    final times = container.read(runNodeTimesProvider);
    expect(times.started['b'], started);
    expect(times.succeededAt('b'), done);
  });

  test(
    'takes the starts already in the event history when first read',
    () async {
      // The history keeps the events from before the record was first read
      // (a screen opened mid-run).
      container.listen(eventHistoryProvider, (_, __) {});
      events
        ..add(_runStarted(_t0))
        ..add(_nodeStarted('a', _t0.add(const Duration(minutes: 1))));
      await _settle();

      container.listen(runNodeTimesProvider, (_, __) {});
      expect(
        container.read(runNodeTimesProvider).started['a'],
        _t0.add(const Duration(minutes: 1)),
      );
    },
  );

  test('survives its readers closing while a run is still going', () async {
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);
    final subscription = container.listen(runNodeTimesProvider, (_, __) {});

    final at = _t0.add(const Duration(minutes: 7));
    events.add(_nodeStarted('b', at));
    await _settle();
    subscription.close();
    await _settle();

    expect(
      container.read(runNodeTimesProvider).started['b'],
      at,
      reason: 'the run has not ended, so its observed starts have not either',
    );
  });

  test('keeps a finished run\'s times after its readers are gone', () async {
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);
    final subscription = container.listen(runNodeTimesProvider, (_, __) {});
    final at = _t0.add(const Duration(minutes: 7));
    events.add(_nodeStarted('b', at));
    await _settle();

    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.completed);
    subscription.close();
    await _settle();

    expect(container.read(runNodeTimesProvider).started['b'], at);
  });

  test('a new run is what clears the record', () async {
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);
    final subscription = container.listen(runNodeTimesProvider, (_, __) {});
    events.add(_nodeStarted('b', _t0));
    await _settle();
    expect(container.read(runNodeTimesProvider).started, isNotEmpty);

    subscription.close();
    await _settle();
    events.add(_runStarted(_t0.add(const Duration(days: 1))));
    await _settle();
    expect(container.read(runNodeTimesProvider).started, isEmpty);
  });
}

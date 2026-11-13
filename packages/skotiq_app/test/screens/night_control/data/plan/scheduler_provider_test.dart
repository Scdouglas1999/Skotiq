// The Target Scheduler's newest pick for Tonight. It must outlive the event
// history: a run opens with an autofocus whose events push the first pick out
// of the history's hundred entries within a minute.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/scheduler_provider.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

var _id = 0;

bridge_event.SkotiqEvent _event(
  bridge_event.SequencerEvent payload, {
  DateTime? at,
}) =>
    bridge_event.SkotiqEvent(
      eventId: BigInt.from(++_id),
      timestamp: (at ?? DateTime.now()).millisecondsSinceEpoch,
      severity: bridge_event.EventSeverity.info,
      category: bridge_event.EventCategory.sequencer,
      payload: bridge_event.EventPayload.sequencer(payload),
    );

bridge_event.SkotiqEvent _pick(int n, String target, {DateTime? at}) => _event(
      bridge_event.SequencerEvent.schedulerDecision(
        nodeId: 'sched',
        decisionCounter: n,
        pickedTargetId: target,
        pickedTargetName: target,
        pickedScore: 90,
        scores: const <bridge_event.SchedulerScoreEntry>[],
      ),
      at: at,
    );

bridge_event.SkotiqEvent _noise() =>
    _event(const bridge_event.SequencerEvent.paused());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(const SystemClock()),
      ],
    );
    addTearDown(container.dispose);
    container.listen(latestSchedulerDecisionProvider, (_, __) {});
  });

  void add(bridge_event.SkotiqEvent event) =>
      container.read(eventHistoryProvider.notifier).addEvent(event);

  test('no pick yet reads as none', () {
    add(_noise());
    expect(container.read(latestSchedulerDecisionProvider), isNull);
  });

  test('the newest pick is kept after the history moves past it', () {
    add(_pick(1, 'M 33'));
    add(_pick(2, 'NGC 891'));
    for (var i = 0; i < EventHistoryNotifier.maxHistorySize + 20; i++) {
      add(_noise());
    }
    final pick = container.read(latestSchedulerDecisionProvider);
    expect(pick?.decisionCounter, 2);
    expect(pick?.pickedTargetName, 'NGC 891');
  });
}

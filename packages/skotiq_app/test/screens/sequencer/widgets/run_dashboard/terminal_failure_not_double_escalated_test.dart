// One failed node raised TWO identical "Critical · Sequencer" toasts and left
// two identical rows in the run-dashboard critical banner.
//
// The native executor publishes the reason twice by construction: the
// instruction emits `InstructionFailed`, which the bridge maps to
// `SequencerEvent.error("<node>: <message>")`, and then the terminal handler
// drains the broadcast buffer for that same `InstructionFailed` and re-formats
// it byte-for-byte as `SequenceFailed.error` (executor/mod.rs
// `last_instruction_failure`). Both payload variants are on the
// `isCriticalEvent` allow-list, so both were escalated.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;
import 'package:skotiq_core/skotiq_core.dart';

const _reason = 'Open Cover: No cover calibrator (flat panel) connected';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

bridge_event.SkotiqEvent _sequencerEvent(
  int id,
  bridge_event.SequencerEvent payload,
) {
  return bridge_event.SkotiqEvent(
    eventId: BigInt.from(id),
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: bridge_event.EventSeverity.error,
    category: bridge_event.EventCategory.sequencer,
    payload: bridge_event.EventPayload.sequencer(payload),
  );
}

bridge_event.SkotiqEvent _midRunError(int id, {String message = _reason}) =>
    _sequencerEvent(id, bridge_event.SequencerEvent.error(message: message));

bridge_event.SkotiqEvent _terminalFailure(int id,
        {String error = _reason}) =>
    _sequencerEvent(id, bridge_event.SequencerEvent.failed(error: error));

bridge_event.SkotiqEvent _runStarted(int id) =>
    bridge_event.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: DateTime.now().millisecondsSinceEpoch,
      // A run start is informational, exactly as the bridge emits it.
      severity: bridge_event.EventSeverity.info,
      category: bridge_event.EventCategory.sequencer,
      payload: const bridge_event.EventPayload.sequencer(
        bridge_event.SequencerEvent.started(sequenceName: 'Run'),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<ProviderContainer> wiredContainer() async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            const AppSettingsState(
              audibleAlertsOnCritical: false,
              pushCriticalAlerts: false,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    container.read(runDashboardCriticalEventsBridgeProvider);
    return container;
  }

  Future<void> emit(
    ProviderContainer container,
    bridge_event.SkotiqEvent event,
  ) async {
    container.read(eventHistoryProvider.notifier).addEvent(event);
    await Future<void>.delayed(Duration.zero);
  }

  test('the terminal event restating a mid-run reason escalates once',
      () async {
    final container = await wiredContainer();

    await emit(container, _midRunError(1));
    await emit(container, _terminalFailure(2));

    final banner = container.read(runDashboardCriticalEventsProvider);
    expect(banner, hasLength(1), reason: 'one failed node, one banner row');
    expect(banner.single.message, _reason);

    final toasts = container.read(uiNotificationProvider);
    expect(
      toasts.where((t) => t.message == _reason),
      hasLength(1),
      reason: 'one failed node, one toast',
    );
  });

  test('a terminal reason the run never announced is still escalated',
      () async {
    final container = await wiredContainer();

    await emit(container, _midRunError(1));
    await emit(
      container,
      _terminalFailure(2, error: 'Sequence aborted by weather safety'),
    );

    expect(container.read(runDashboardCriticalEventsProvider), hasLength(2));
  });

  test('a terminal failure with no preceding mid-run error is escalated',
      () async {
    final container = await wiredContainer();

    await emit(container, _terminalFailure(1));

    expect(container.read(runDashboardCriticalEventsProvider), hasLength(1));
  });

  test('the ledger is per-run, so the next run reports the same reason again',
      () async {
    final container = await wiredContainer();

    await emit(container, _midRunError(1));
    await emit(container, _terminalFailure(2));
    expect(container.read(runDashboardCriticalEventsProvider), hasLength(1));

    await emit(container, _runStarted(3));
    await emit(container, _terminalFailure(4));

    expect(
      container.read(runDashboardCriticalEventsProvider),
      hasLength(2),
      reason: 'the second run failing the same way is news again',
    );
  });
}

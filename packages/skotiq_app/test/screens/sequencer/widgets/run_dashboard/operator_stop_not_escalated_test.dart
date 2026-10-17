// The run-dashboard critical-event bridge must not escalate an operator Stop.
//
// The native executor ends a cancelled run with
// `SequencerEvent.Error(message: "Sequence cancelled")`, and that payload
// variant is on the `isCriticalEvent` allow-list — so one press of Stop produces
// a red "Critical · Sequencer / Sequence cancelled" toast, a full-width red
// Dashboard banner "Sequencer — Sequencer error" and a RECENT EVENTS row
// "Sequencer error — Sequence cancelled", while the Session Report opened next
// is titled "New Sequence — Stopped (resumable)" and lists no errors at all.
// This bridge produces all three surfaces, so it is where the classification
// belongs.
//
// The counter-case is pinned too: a fault whose text merely CONTAINS
// "cancelled" must still page the operator.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;
import 'package:skotiq_core/skotiq_core.dart';

class _FakeCriticalAlertPlayer implements CriticalAlertPlayer {
  final List<String> playCalls = [];

  @override
  Future<void> play({required String sound}) async => playCalls.add(sound);
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

bridge_event.SkotiqEvent _sequencerError(int id, String message) =>
    bridge_event.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: bridge_event.EventSeverity.error,
      category: bridge_event.EventCategory.sequencer,
      payload: bridge_event.EventPayload.sequencer(
        bridge_event.SequencerEvent.error(message: message),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCriticalAlertPlayer player;
  late SkotiqDatabase db;

  setUp(() {
    player = _FakeCriticalAlertPlayer();
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            const AppSettingsState(
              audibleAlertsOnCritical: true,
              pushCriticalAlerts: true,
              criticalAlertSound: 'systemBell',
            ),
          ),
        ),
        criticalAlertPlayerProvider.overrideWithValue(player),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('an operator Stop raises no banner, no toast and no alarm', () async {
    final container = makeContainer();
    await container.read(appSettingsProvider.future);
    container.read(runDashboardCriticalEventsBridgeProvider);

    container
        .read(eventHistoryProvider.notifier)
        .addEvent(_sequencerError(1, kSequenceCancelledNotice));
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(runDashboardCriticalEventsProvider),
      isEmpty,
      reason: 'the red Dashboard banner fired for a button the operator '
          'pressed on purpose',
    );
    expect(container.read(uiNotificationProvider), isEmpty);
    expect(player.playCalls, isEmpty);
  });

  test('the stop still appears in RECENT EVENTS, as an info row', () async {
    final container = makeContainer();
    await container.read(appSettingsProvider.future);

    container
        .read(eventHistoryProvider.notifier)
        .addEvent(_sequencerError(1, kSequenceCancelledNotice));

    final recent = container.read(runDashboardRecentEventsProvider(5));
    expect(recent, hasLength(1));
    expect(recent.first.title, 'Sequence stopped');
    expect(recent.first.title, isNot(contains('error')));
    expect(recent.first.isCritical, isFalse);
    expect(recent.first.severity, RunDashboardEventSeverity.info);
  });

  test('a real fault containing the word "cancelled" still escalates',
      () async {
    final container = makeContainer();
    await container.read(appSettingsProvider.future);
    container.read(runDashboardCriticalEventsBridgeProvider);

    container.read(eventHistoryProvider.notifier).addEvent(
          _sequencerError(1, 'Temperature compensation cancelled'),
        );
    await Future<void>.delayed(Duration.zero);

    final banner = container.read(runDashboardCriticalEventsProvider);
    expect(banner, hasLength(1));
    expect(banner.first.isCritical, isTrue);
    expect(player.playCalls, ['systemBell']);
  });
}

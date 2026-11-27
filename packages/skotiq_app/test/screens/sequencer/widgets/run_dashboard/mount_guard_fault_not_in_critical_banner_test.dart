// A mount motion-guard fault has its own banner on Tonight, with the
// operator's actions; listed in the critical-events banner too it read twice.
// It must still sound the alarm, and any other fault
// still reaches the critical-events banner.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/run_dashboard_providers.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';

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
        bridge_event.SequencerEvent.error(
          message: message,
          kind: bridge_event.SequencerErrorKind.stepFailed,
        ),
      ),
    );

bridge_event.SkotiqEvent _safety(int id, bridge_event.SafetyEvent event) =>
    bridge_event.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: bridge_event.EventSeverity.critical,
      category: bridge_event.EventCategory.safety,
      payload: bridge_event.EventPayload.safety(event),
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

  for (final (name, event) in [
    (
      'a runaway',
      const bridge_event.SafetyEvent.mountMotionFault(
        deviceId: 'sim_mount_1',
        kind: 'runaway',
        message: 'The mount moved at 4.7 degrees per second',
      ),
    ),
    (
      'a lost position',
      const bridge_event.SafetyEvent.mountPositionUnknown(
        deviceId: 'sim_mount_1',
        reason: 'runaway',
        message: 'The mount no longer knows where it points',
      ),
    ),
  ]) {
    test('$name sounds but stays off the critical-events banner', () async {
      final container = makeContainer();
      await container.read(appSettingsProvider.future);
      final alerts = <RunCriticalAlert>[];
      final subscription =
          container.read(runCriticalAlertsProvider).listen(alerts.add);
      addTearDown(subscription.cancel);
      container.read(runCriticalAlertSoundProvider);

      container.read(eventHistoryProvider.notifier).addEvent(_safety(1, event));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(runDashboardCriticalEventsProvider), isEmpty);
      expect(alerts, hasLength(1));
      expect(player.playCalls, ['systemBell']);
    });
  }

  test('any other fault still reaches the critical-events banner', () async {
    final container = makeContainer();
    await container.read(appSettingsProvider.future);
    container.read(runCriticalAlertSoundProvider);

    container
        .read(eventHistoryProvider.notifier)
        .addEvent(_sequencerError(1, 'Camera stopped responding'));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(runDashboardCriticalEventsProvider), hasLength(1));
    expect(player.playCalls, ['systemBell']);
  });
}

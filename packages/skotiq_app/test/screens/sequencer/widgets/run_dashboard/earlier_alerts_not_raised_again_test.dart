// A window that links to a host mid-night fills its event log with the host's
// night so far. An alert the host raised before the link is part of that
// history: it shows in the banner as it does on the host, and it does not
// sound or page a second time here. One raised after the link does.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
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
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
    audibleAlertsOnCritical: true,
    pushCriticalAlerts: true,
    criticalAlertSound: 'systemBell',
  );
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('alerts from before the link show in the banner without sounding; '
      'one raised after it sounds', () async {
    final player = _FakeCriticalAlertPlayer();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
        criticalAlertPlayerProvider.overrideWithValue(player),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final alerts = <RunCriticalAlert>[];
    final subscription =
        container.read(runCriticalAlertsProvider).listen(alerts.add);
    addTearDown(subscription.cancel);
    container.read(runCriticalAlertSoundProvider);

    container.read(eventHistoryProvider.notifier).seedEarlier([
      _sequencerError(2, 'Filter wheel stopped answering'),
      _sequencerError(1, 'Camera download timed out'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(runDashboardCriticalEventsProvider), isNotEmpty);
    expect(alerts, isEmpty);
    expect(player.playCalls, isEmpty);

    final live = _sequencerError(3, 'Mount stopped tracking');
    container.read(eventHistoryProvider.notifier).addEvent(live);
    await Future<void>.delayed(Duration.zero);

    expect(alerts, hasLength(1));
    expect(identical(alerts.single.event, live), isTrue);
    expect(player.playCalls, ['systemBell']);
  });
}

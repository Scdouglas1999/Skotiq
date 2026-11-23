import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_app/services/night_session/night_guide_samples.dart';
import 'package:skotiq_app/screens/night_control/data/session/night_log_provider.dart';
import 'package:skotiq_app/services/night_session/night_session_events.dart';

import '../../../../harness/mock_backend.dart';
import '../../../../harness/mock_database.dart';
import '../../../../harness/pump_app_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a new host process clears the log and the session marks', () {
    final database = mockDatabase();
    final backend = mockBackend();
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, backend),
        ),
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(database.close);

    container.read(runtimeHostSessionProvider.notifier).state = 'A';
    container.read(eventHistoryProvider.notifier).addEvent(
          bridge.SkotiqEvent(
            eventId: BigInt.one,
            timestamp: 1,
            severity: bridge.EventSeverity.info,
            category: bridge.EventCategory.system,
            payload: const bridge.EventPayload.system(
              bridge.SystemEvent.initialized(),
            ),
          ),
        );
    final when = DateTime.utc(2026, 10, 31, 22);
    // ignore: invalid_use_of_protected_member
    container.read(nightSessionEventsProvider.notifier).state =
        NightSessionEvents(flips: [when]);
    expect(container.read(nightLogFeedEventsProvider), hasLength(1));
    expect(container.read(nightSessionEventsProvider).flips, [when]);
    expect(container.read(eventHistoryProvider), hasLength(1));
    container.read(nightGuideSamplesProvider.notifier).add(
          NightGuideSample(when, 0.2, -0.3),
        );
    expect(container.read(nightGuideSamplesProvider), hasLength(1));

    applyHostRuntimeUpdate(
      container,
      const HostRuntimeUpdate(
        channel: 'hostSession',
        revision: 1,
        value: {'id': 'A'},
      ),
      networkBackend: backend,
    );
    expect(container.read(eventHistoryProvider), hasLength(1));
    expect(container.read(nightLogFeedEventsProvider), hasLength(1));
    expect(container.read(nightSessionEventsProvider).flips, [when]);

    applyHostRuntimeUpdate(
      container,
      const HostRuntimeUpdate(
        channel: 'hostSession',
        revision: 2,
        value: {'id': 'B'},
      ),
      networkBackend: backend,
    );
    expect(container.read(eventHistoryProvider), isEmpty);
    expect(container.read(nightLogFeedEventsProvider), isEmpty);
    expect(container.read(nightSessionEventsProvider).flips, isEmpty);
    expect(container.read(nightGuideSamplesProvider), isEmpty);
  });
}

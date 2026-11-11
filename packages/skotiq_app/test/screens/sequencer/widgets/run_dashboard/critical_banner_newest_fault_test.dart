// SY-32 / SY-26 (sync night 2026-11-03): a linked client's red banner kept
// the FIRST meridian flip failure ("Pier side did not change ... still West")
// after the second one (a plate solve, with the mount already on pier east),
// and kept it after the resume while the run was Running.
//
// The events below are built the way a linked client gets them: the host's
// wire envelope rebuilt by `bridgeEventFromCoreEvent`, whose `eventId` is the
// envelope's timestamp. That id is neither unique (two events of one
// millisecond share it) nor in arrival order (the client stamps its own
// connection events with its own clock), so it cannot tell new events from
// old ones.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;
import 'package:skotiq_core/src/backend/bridge_event_mapper.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

final _t0 = DateTime.utc(2026, 11, 4, 2, 37, 14).millisecondsSinceEpoch;

sk_events.SkotiqEvent _wire(
  int timestamp,
  String eventType,
  Map<String, dynamic> data, {
  EventSeverity severity = EventSeverity.info,
  EventCategory category = EventCategory.sequencer,
}) =>
    bridgeEventFromCoreEvent(
      SkotiqEvent(
        timestamp: timestamp,
        severity: severity,
        category: category,
        eventType: eventType,
        data: data,
      ),
    );

sk_events.SkotiqEvent _flipFailed(int timestamp, String error) => _wire(
      timestamp,
      'MeridianFlipOutcome',
      {
        'outcome': 'failed',
        'target_name': 'NGC 7814',
        'new_pier_side': 'East',
        'duration_secs': 600.0,
        'attempts': 4,
        'failed_steps': <String>['step'],
        'error': error,
        'action_taken': 'PauseAndAlert',
      },
      severity: EventSeverity.critical,
    );

const _pierError = 'Verifying pier side: Pier side did not change after flip '
    '(still West). The mount may not have flipped correctly.';
const _solveError = 'Plate solving and centering: Plate solve failed: no '
    'solution; target centering is unverified (three frames tried)';

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
    container.read(runCriticalAlertsProvider);
    return container;
  }

  Future<void> emit(
    ProviderContainer container,
    sk_events.SkotiqEvent event,
  ) async {
    container.read(eventHistoryProvider.notifier).addEvent(event);
    await Future<void>.delayed(Duration.zero);
  }

  List<String> bannerMessages(ProviderContainer container) => [
        for (final e in container.read(runDashboardCriticalEventsProvider))
          e.message,
      ];

  test('a newer flip failure replaces the older one in the banner', () async {
    final container = await wiredContainer();

    await emit(container, _flipFailed(_t0, _pierError));
    await emit(
      container,
      _flipFailed(
          _t0 + const Duration(minutes: 74).inMilliseconds, _solveError),
    );

    final messages = bannerMessages(container);
    expect(messages, hasLength(1),
        reason: 'one flip, one banner row: the newest failure');
    expect(messages.single, contains('Plate solve failed'));
    expect(messages.single, isNot(contains('still West')));
  });

  test(
      'a host event is not dropped because an earlier event carried a later '
      'timestamp', () async {
    final container = await wiredContainer();

    await emit(container, _flipFailed(_t0, _pierError));
    // The client's own "connection back" event, stamped with a client clock
    // that runs a few seconds ahead of the host's.
    await emit(
      container,
      _wire(
        _t0 + const Duration(minutes: 74, seconds: 5).inMilliseconds,
        'BackendReconnected',
        {'message': 'WebSocket reconnected'},
        category: EventCategory.system,
      ),
    );
    await emit(
      container,
      _flipFailed(
          _t0 + const Duration(minutes: 74).inMilliseconds, _solveError),
    );

    final messages = bannerMessages(container);
    expect(messages, hasLength(1));
    expect(messages.single, contains('Plate solve failed'));
  });

  test('two critical events of the same millisecond both reach the banner',
      () async {
    final container = await wiredContainer();

    await emit(
      container,
      _wire(
        _t0,
        'ExposureFailed',
        {'error': 'Camera timed out'},
        severity: EventSeverity.error,
        category: EventCategory.imaging,
      ),
    );
    await emit(container, _flipFailed(_t0, _pierError));

    expect(container.read(runDashboardCriticalEventsProvider), hasLength(2));
  });

  test('resuming the run clears the flip failure that paused it', () async {
    final container = await wiredContainer();

    await emit(container, _flipFailed(_t0, _pierError));
    expect(bannerMessages(container), hasLength(1));

    await emit(container, _wire(_t0 + 60000, 'Resumed', const {}));

    expect(container.read(runDashboardCriticalEventsProvider), isEmpty);
  });

  test(
      'a run seen to go from paused back to running clears the flip failure, '
      'also without a Resumed event (a client that joined while paused)',
      () async {
    final container = await wiredContainer();
    final state = container.read(sequenceExecutionStateProvider.notifier);
    state.state = SequenceExecutionState.paused;

    await emit(container, _flipFailed(_t0, _pierError));
    expect(bannerMessages(container), hasLength(1));

    state.state = SequenceExecutionState.running;
    await Future<void>.delayed(Duration.zero);

    expect(container.read(runDashboardCriticalEventsProvider), isEmpty);
  });

  test('resuming keeps a critical event that is not about the run', () async {
    final container = await wiredContainer();

    await emit(
      container,
      _wire(
        _t0,
        'ExposureFailed',
        {'error': 'Camera timed out'},
        severity: EventSeverity.error,
        category: EventCategory.imaging,
      ),
    );
    await emit(container, _flipFailed(_t0 + 1, _pierError));
    await emit(container, _wire(_t0 + 60000, 'Resumed', const {}));

    final banner = container.read(runDashboardCriticalEventsProvider);
    expect(banner, hasLength(1));
    expect(banner.single.category, 'Imaging');
  });

  test('a successful flip clears the earlier flip failure', () async {
    final container = await wiredContainer();

    await emit(container, _flipFailed(_t0, _pierError));
    await emit(
      container,
      _wire(
        _t0 + 60000,
        'MeridianFlipOutcome',
        {
          'outcome': 'success',
          'target_name': 'NGC 7814',
          'new_pier_side': 'East',
          'duration_secs': 120.0,
          'attempts': 2,
          'failed_steps': <String>[],
        },
      ),
    );

    expect(container.read(runDashboardCriticalEventsProvider), isEmpty);
  });
}

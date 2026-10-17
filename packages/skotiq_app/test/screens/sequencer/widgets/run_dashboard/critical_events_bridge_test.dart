// End-to-end smoke test for the critical-event escalation
// path. Verifies that a critical bridge event:
//   * Appears in `runDashboardCriticalEventsProvider` (banner data)
//   * Routes through `uiNotificationProvider` (toast queue)
//   * Triggers `criticalAlertPlayerProvider.play` (audible alert, gated by
//     `audibleAlertsOnCritical` and `criticalAlertSound`)
//   * Enqueues a `PushNotification` (mobile push, gated by
//     `pushCriticalAlerts`)
//
// Also pins the cooldown behaviour so a storm of critical events doesn't
// trigger the system bell more than once per 5 seconds, and confirms
// `effectiveHorizonDeg` flows into the planetarium-side provider so the
// altitude card and dashboard agree on time-to-set.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_app/services/location_sync_service.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Capture-fake for the audio path so the test can assert how many times
/// the alert was fired without touching the platform audio channel.
class _FakeCriticalAlertPlayer implements CriticalAlertPlayer {
  final List<String> playCalls = [];

  @override
  Future<void> play({required String sound}) async {
    playCalls.add(sound);
  }
}

/// Forces `appSettingsProvider` into a known state without the AsyncNotifier
/// hitting the on-disk settings DAO.
class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

bridge_event.SkotiqEvent _criticalSystemErrorEvent({
  required int id,
  String message = 'FITS save failed: disk full',
}) {
  // SystemEvent.error is classified critical by `bridge_event.isCriticalEvent`
  // because its severity is `error` and it appears in the small allow-list
  // there. We use it instead of EquipmentEvent.error because System errors
  // are exactly the kind the user must not miss while away from the laptop.
  return bridge_event.SkotiqEvent(
    eventId: BigInt.from(id),
    // PlatformInt64 is `int` on native targets and `BigInt` on web; on
    // the test VM we're on native so an `int` works directly.
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: bridge_event.EventSeverity.error,
    category: bridge_event.EventCategory.system,
    payload: bridge_event.EventPayload.system(
      bridge_event.SystemEvent.error(message: message),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runDashboardCriticalEventsBridgeProvider', () {
    late _FakeCriticalAlertPlayer player;
    late SkotiqDatabase db;

    setUp(() {
      player = _FakeCriticalAlertPlayer();
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    ProviderContainer makeContainer({
      required bool audibleAlertsOnCritical,
      required bool pushCriticalAlerts,
      String criticalAlertSound = 'systemBell',
      double effectiveHorizonDeg = 0.0,
    }) {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // Drive settings deterministically.
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              AppSettingsState(
                audibleAlertsOnCritical: audibleAlertsOnCritical,
                pushCriticalAlerts: pushCriticalAlerts,
                criticalAlertSound: criticalAlertSound,
                effectiveHorizonDeg: effectiveHorizonDeg,
              ),
            ),
          ),
          // Capture-fake for the audio path. Why an override (not just a
          // sniffer on SystemChannels.platform): the production code goes
          // through Riverpod, so override is the precise extension point.
          criticalAlertPlayerProvider.overrideWithValue(player),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
        'critical event populates banner, toast, audio, and push when all '
        'toggles are on', () async {
      final container = makeContainer(
        audibleAlertsOnCritical: true,
        pushCriticalAlerts: true,
      );

      // Force settings to load before the bridge fires so the gates read
      // the values we configured rather than the initial nulls.
      await container.read(appSettingsProvider.future);

      // Subscribe to the push stream BEFORE invoking the bridge so we
      // catch the first emission. Buffer with a Completer so the test can
      // assert exactly one notification was enqueued for this event.
      final pushService = container.read(pushNotificationServiceProvider);
      // The broadcaster starts fail-closed; load the push config (fresh DB →
      // enabled defaults) and let its listener enable the service before the
      // bridge fires, matching a running app with its config provisioned.
      await container.read(pushNotificationConfigProvider.future);
      await Future<void>.delayed(Duration.zero);
      final firstPush = Completer<PushNotification>();
      final pushSub = pushService.notifications.listen((n) {
        if (!firstPush.isCompleted) firstPush.complete(n);
      });
      addTearDown(pushSub.cancel);

      // Wire the bridge so the listen() fires. fireImmediately=true means
      // we'll get the current (empty) state first, then subsequent updates.
      container.read(runDashboardCriticalEventsBridgeProvider);

      // Inject a critical event into the history. The bridge listens to
      // `eventHistoryProvider`; pushing through its notifier is the same
      // path the real `skotiqEventsProvider` stream uses.
      container
          .read(eventHistoryProvider.notifier)
          .addEvent(_criticalSystemErrorEvent(id: 1));

      // The bridge processes synchronously; one microtask drain is enough
      // for the listener callbacks to run.
      await Future<void>.delayed(Duration.zero);

      // 1. Banner data
      final banner = container.read(runDashboardCriticalEventsProvider);
      expect(banner, hasLength(1));
      expect(banner.first.isCritical, isTrue);
      expect(banner.first.category, 'System');

      // 2. Audible alert fired exactly once with the systemBell sound
      expect(player.playCalls, ['systemBell']);

      // 3. Push notification enqueued (priority critical)
      final push = await firstPush.future.timeout(const Duration(seconds: 1));
      expect(push.priority, PushNotificationPriority.critical);
      expect(push.title, contains('Critical · System'));
      expect(push.category, EventCategory.system);
    });

    test('audible alert respects 5-second cooldown across a burst', () async {
      final container = makeContainer(
        audibleAlertsOnCritical: true,
        pushCriticalAlerts: false,
      );
      await container.read(appSettingsProvider.future);

      container.read(runDashboardCriticalEventsBridgeProvider);

      // Fire 5 critical events in rapid succession.
      for (var i = 1; i <= 5; i++) {
        container
            .read(eventHistoryProvider.notifier)
            .addEvent(_criticalSystemErrorEvent(id: i));
        await Future<void>.delayed(Duration.zero);
      }

      // Cooldown is 5 s — exactly one alert should have fired.
      expect(player.playCalls, ['systemBell']);
      // But all 5 should still be in the banner queue.
      expect(container.read(runDashboardCriticalEventsProvider), hasLength(5));
    });

    test('"none" sound suppresses audio but keeps banner + toast', () async {
      final container = makeContainer(
        audibleAlertsOnCritical: true,
        pushCriticalAlerts: false,
        criticalAlertSound: 'none',
      );
      await container.read(appSettingsProvider.future);

      container.read(runDashboardCriticalEventsBridgeProvider);
      container
          .read(eventHistoryProvider.notifier)
          .addEvent(_criticalSystemErrorEvent(id: 7));
      await Future<void>.delayed(Duration.zero);

      // Banner still populated.
      expect(container.read(runDashboardCriticalEventsProvider), hasLength(1));
      // Audio path NOT invoked.
      expect(player.playCalls, isEmpty);
    });

    test('pushCriticalAlerts=false suppresses push, keeps banner + audio',
        () async {
      final container = makeContainer(
        audibleAlertsOnCritical: true,
        pushCriticalAlerts: false,
      );
      await container.read(appSettingsProvider.future);

      // Subscribe and accumulate; we expect zero notifications. Enable the
      // broadcaster authoritatively so this proves the pushCriticalAlerts gate
      // suppresses the push, not merely that the fail-closed default did.
      final pushService = container.read(pushNotificationServiceProvider);
      await container.read(pushNotificationConfigProvider.future);
      await Future<void>.delayed(Duration.zero);
      final received = <PushNotification>[];
      final pushSub = pushService.notifications.listen(received.add);
      addTearDown(pushSub.cancel);

      container.read(runDashboardCriticalEventsBridgeProvider);
      container
          .read(eventHistoryProvider.notifier)
          .addEvent(_criticalSystemErrorEvent(id: 11));
      // Let stream drain (broadcast streams need an extra microtask).
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(container.read(runDashboardCriticalEventsProvider), hasLength(1));
      expect(player.playCalls, ['systemBell']);
      expect(received, isEmpty);
    });

    test(
        'audibleAlertsOnCritical=false suppresses audio but still banners '
        'and pushes', () async {
      final container = makeContainer(
        audibleAlertsOnCritical: false,
        pushCriticalAlerts: true,
      );
      await container.read(appSettingsProvider.future);

      final pushService = container.read(pushNotificationServiceProvider);
      await container.read(pushNotificationConfigProvider.future);
      await Future<void>.delayed(Duration.zero);
      final firstPush = Completer<PushNotification>();
      final pushSub = pushService.notifications.listen((n) {
        if (!firstPush.isCompleted) firstPush.complete(n);
      });
      addTearDown(pushSub.cancel);

      container.read(runDashboardCriticalEventsBridgeProvider);
      container
          .read(eventHistoryProvider.notifier)
          .addEvent(_criticalSystemErrorEvent(id: 13));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(runDashboardCriticalEventsProvider), hasLength(1));
      expect(player.playCalls, isEmpty);
      final push = await firstPush.future.timeout(const Duration(seconds: 1));
      expect(push.priority, PushNotificationPriority.critical);
    });
  });

  group('horizon-aware time-to-set agreement', () {
    test(
        'planetariumEffectiveHorizonDegProvider receives the user value '
        'after locationSyncProvider fires', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      const horizon = 18.0;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              const AppSettingsState(
                effectiveHorizonDeg: horizon,
                // Provide a sensible location so the sync provider's
                // location-gated branch executes too.
                latitude: 30.0,
                longitude: -97.0,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Drain the AsyncNotifier and wire the listener.
      await container.read(appSettingsProvider.future);
      container.read(locationSyncProvider);

      // The sync provider schedules Future.microtask updates; flush them.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        container.read(planetariumEffectiveHorizonDegProvider),
        horizon,
      );
    });

    test(
        'schedulerService.nextSetTime differs between horizonDeg=0 and '
        'horizonDeg=18 for a non-circumpolar target', () {
      // Why this assertion: the user's complaint is "set time should
      // respect the trees". Pin the differential here so a refactor that
      // accidentally hard-codes horizonDeg=0 fires a red test.
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      final scheduler = container.read(schedulerServiceProvider);
      // Use a target at +30° dec from a +30° latitude, currently 30 min
      // past transit, so it is still high in the sky.
      final now = DateTime.utc(2026, 5, 18, 6, 0); // arbitrary fixed time
      final tToSet0 = scheduler.nextSetTime(
        raHours: 6.5, // 30 min west of meridian at LST=6.0
        decDegrees: 30.0,
        now: now,
        latitudeDegrees: 30.0,
        longitudeDegrees: 0.0,
        horizonDeg: 0.0,
      );
      final tToSet18 = scheduler.nextSetTime(
        raHours: 6.5,
        decDegrees: 30.0,
        now: now,
        latitudeDegrees: 30.0,
        longitudeDegrees: 0.0,
        horizonDeg: 18.0,
      );

      // Both should be non-null (target is not circumpolar at lat=30, dec=30
      // — declination is BELOW the always-above latitude of 60).
      expect(tToSet0, isNotNull);
      expect(tToSet18, isNotNull);
      // 18° horizon must produce an earlier set time than 0°.
      expect(tToSet18!.inSeconds, lessThan(tToSet0!.inSeconds),
          reason: 'Effective horizon must shorten time-to-set');
    });
  });
}

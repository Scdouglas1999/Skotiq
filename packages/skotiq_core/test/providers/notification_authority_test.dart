// v6 "make it real" — notification authority hardening.
//
// The phone-push feed and the notification router used to manufacture their
// own defaults while their persisted authority (push config / routing matrix /
// per-transport config) was loading or errored:
//   * the broadcaster started ENABLED (PushNotificationConfig default), so a
//     DB stall or corrupt blob could still push to paired phones;
//   * the router seeded NotificationRoutingMatrix.defaults(), which routes
//     several categories to systemPush, so a corrupt/unavailable matrix could
//     still page phones against routing the user never authorised;
//   * a transport-config reload error left the previously-live external
//     transport active with stale credentials.
//
// These tests pin the fail-closed replacements: disabled-until-authoritative
// push, an in-app-only fallback matrix (safety-critical events still surface
// in-app, but NO external transport fires), and transport reset-on-error.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Minimal fake diagnostics backend: just a controllable event stream.
class _FakeDiagnosticsBackend implements DiagnosticsBackend {
  final StreamController<SkotiqEvent> events =
      StreamController<SkotiqEvent>.broadcast();

  @override
  Stream<SkotiqEvent> get eventStream => events.stream;

  @override
  bool get dispatchPluginNodesLocally => false;

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  void dispose() {}

  @override
  Future<LocationSettings> getLocationFromInternet() =>
      throw UnimplementedError('not needed for this test');
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

int _unexpectedRemotePushConfigLoads = 0;

class _CountingPushConfigNotifier extends PushNotificationConfigNotifier {
  @override
  Future<PushNotificationConfig> build() async {
    _unexpectedRemotePushConfigLoads++;
    return const PushNotificationConfig();
  }
}

/// A routing matrix whose authority never resolves — models the DB read still
/// in flight so the router must use its in-app-only fallback.
class _NeverLoadingMatrixNotifier extends RoutingMatrixNotifier {
  @override
  Future<NotificationRoutingMatrix> build() =>
      Completer<NotificationRoutingMatrix>().future;
}

/// A webhook config that loads CONFIGURED, then errors on the next build. Lets a
/// test drive the "a previously-configured transport is deactivated when its
/// config refresh errors" path deterministically.
bool _webhookShouldFail = false;

class _FlakyWebhookNotifier extends WebhookConfigNotifier {
  @override
  Future<WebhookTransportConfig> build() async {
    if (_webhookShouldFail) {
      throw StateError('webhook config store unavailable');
    }
    return const WebhookTransportConfig(url: 'https://example.com/hook');
  }
}

SkotiqEvent _weatherUnsafeEvent() => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.error,
  category: EventCategory.safety,
  eventType: 'WeatherUnsafe',
  data: const {'reason': 'clouds'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer(
    SkotiqDatabase db, {
    List<Override> extra = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('push broadcaster fail-closed authority', () {
    test('starts disabled while config is loading, enables on authoritative '
        'load, and disables again after a refresh error', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = makeContainer(db);

      // 1. Loading: the service is read before the config resolves, so its
      //    master gate is off — no push can broadcast against manufactured
      //    enabled-by-default config.
      final service = container.read(pushNotificationServiceProvider);
      expect(service.config.enabled, isFalse);

      // 2. Authoritative load (fresh DB → enabled defaults): the listener
      //    flips the SAME live service to enabled without replacing it.
      await container.read(pushNotificationConfigProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(service.config.enabled, isTrue);
      expect(
        identical(container.read(pushNotificationServiceProvider), service),
        isTrue,
        reason: 'the service instance must survive a config transition',
      );

      // 3. Refresh error: corrupt the stored blob and invalidate. The
      //    service must return to disabled rather than retain the enabled
      //    config it held before the failed refresh.
      await db.settingsDao.setSetting(
        'push_notification_config',
        '{not valid json',
      );
      container.invalidate(pushNotificationConfigProvider);
      await expectLater(
        container.read(pushNotificationConfigProvider.future),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        service.config.enabled,
        isFalse,
        reason: 'a failed refresh after a prior success must fail closed',
      );
    });
  });

  group('router in-app-only fallback while matrix authority is unavailable', () {
    test('an event during matrix loading reaches in-app exactly once while '
        'external push is suppressed', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final backend = _FakeDiagnosticsBackend();
      addTearDown(() => backend.events.close());
      final container = makeContainer(
        db,
        extra: [
          diagnosticsBackendProvider.overrideWithValue(backend),
          // Matrix authority never resolves — the router must fall back to
          // in-app-only for the whole test.
          notificationRoutingMatrixProvider.overrideWith(
            _NeverLoadingMatrixNotifier.new,
          ),
        ],
      );

      // Enable the broadcaster authoritatively so suppression is proven to
      // come from the in-app-only fallback MATRIX, not a fail-closed feed.
      final service = container.read(pushNotificationServiceProvider);
      await container.read(pushNotificationConfigProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(service.config.enabled, isTrue);

      final pushes = <PushNotification>[];
      final sub = service.notifications.listen(pushes.add);
      addTearDown(sub.cancel);

      container.read(notificationRouterProvider);
      backend.events.add(_weatherUnsafeEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        container.read(uiNotificationProvider),
        hasLength(1),
        reason: 'safety-critical events must still surface in-app',
      );
      expect(
        pushes,
        isEmpty,
        reason: 'no external push may fire against an unavailable matrix',
      );
    });

    test('a corrupt matrix errors -> in-app works but push does not; once the '
        'matrix loads authoritatively push can fire', () async {
      // Phase 1: corrupt matrix -> the router reverts to the in-app-only
      // fallback on the error, so push is suppressed even though push is on.
      final corruptDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(corruptDb.close);
      await corruptDb.settingsDao.setSetting(
        'notification_routing_matrix',
        '{not valid json',
      );
      final backend1 = _FakeDiagnosticsBackend();
      addTearDown(() => backend1.events.close());
      final c1 = makeContainer(
        corruptDb,
        extra: [diagnosticsBackendProvider.overrideWithValue(backend1)],
      );

      final service1 = c1.read(pushNotificationServiceProvider);
      await c1.read(pushNotificationConfigProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(service1.config.enabled, isTrue);
      final pushes1 = <PushNotification>[];
      final sub1 = service1.notifications.listen(pushes1.add);
      addTearDown(sub1.cancel);

      c1.read(notificationRouterProvider);
      await expectLater(
        c1.read(notificationRoutingMatrixProvider.future),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);

      backend1.events.add(_weatherUnsafeEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c1.read(uiNotificationProvider), hasLength(1));
      expect(
        pushes1,
        isEmpty,
        reason: 'a corrupt matrix must not route to systemPush',
      );

      // Phase 2: a fresh (empty) DB loads NotificationRoutingMatrix.defaults()
      // — which routes weatherUnsafe to systemPush — so the SAME event now
      // pushes once the authoritative matrix is in place.
      final okDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(okDb.close);
      final backend2 = _FakeDiagnosticsBackend();
      addTearDown(() => backend2.events.close());
      final c2 = makeContainer(
        okDb,
        extra: [diagnosticsBackendProvider.overrideWithValue(backend2)],
      );

      final service2 = c2.read(pushNotificationServiceProvider);
      await c2.read(pushNotificationConfigProvider.future);
      await Future<void>.delayed(Duration.zero);
      final pushes2 = <PushNotification>[];
      final sub2 = service2.notifications.listen(pushes2.add);
      addTearDown(sub2.cancel);

      c2.read(notificationRouterProvider);
      await c2.read(notificationRoutingMatrixProvider.future);
      await Future<void>.delayed(Duration.zero);

      backend2.events.add(_weatherUnsafeEvent());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c2.read(uiNotificationProvider), hasLength(1));
      expect(
        pushes2,
        hasLength(1),
        reason: 'authoritative defaults route weatherUnsafe to systemPush',
      );
      expect(pushes2.single.priority, PushNotificationPriority.critical);
    });
  });

  group('transport reset-on-error', () {
    test('a config refresh error deactivates a previously-configured external '
        'transport', () async {
      _webhookShouldFail = false;
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final backend = _FakeDiagnosticsBackend();
      addTearDown(() => backend.events.close());
      final container = makeContainer(
        db,
        extra: [
          diagnosticsBackendProvider.overrideWithValue(backend),
          webhookTransportConfigProvider.overrideWith(
            _FlakyWebhookNotifier.new,
          ),
        ],
      );

      // Load the configured webhook, then build the router; the live
      // transport picks up the configured URL.
      await container.read(webhookTransportConfigProvider.future);
      final router = container.read(notificationRouterProvider);
      await Future<void>.delayed(Duration.zero);
      final webhook = router.transportOf(
        NotificationTransportKind.webhookGeneric,
      )!;
      expect(
        webhook.isConfigured,
        isTrue,
        reason: 'the persisted webhook URL makes the transport configured',
      );

      // A refresh that errors must reset the live transport to its
      // unconfigured safe config so the stale URL can no longer send.
      _webhookShouldFail = true;
      container.invalidate(webhookTransportConfigProvider);
      await expectLater(
        container.read(webhookTransportConfigProvider.future),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        webhook.isConfigured,
        isFalse,
        reason: 'a config refresh error deactivates the external transport',
      );
    });
  });

  test(
    'remote controller router is in-app-only and ignores local configs',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final remote = NetworkBackend(
        serverHost: '127.0.0.1',
        serverPort: 1,
        webSocketPort: 1,
        autoConnectWebSocket: false,
      );
      addTearDown(remote.dispose);
      _unexpectedRemotePushConfigLoads = 0;
      final container = makeContainer(
        db,
        extra: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, remote),
          ),
          pushNotificationConfigProvider.overrideWith(
            _CountingPushConfigNotifier.new,
          ),
        ],
      );

      final router = container.read(notificationRouterProvider);
      final pushService = container.read(pushNotificationServiceProvider);

      expect(
        router.transportOf(NotificationTransportKind.webhookGeneric),
        isNull,
      );
      expect(router.transportOf(NotificationTransportKind.systemPush), isNull);
      expect(pushService.config.enabled, isFalse);
      expect(_unexpectedRemotePushConfigLoads, 0);
      for (final category in NotificationCategory.values) {
        expect(router.matrix.ruleFor(category).transports, const [
          NotificationTransportKind.inApp,
        ]);
      }
      expect(
        await db.settingsDao.getSetting('notification_secrets_migrated_v2'),
        isNull,
        reason: 'a controller must not initialize or mutate host-style secrets',
      );
    },
  );
}

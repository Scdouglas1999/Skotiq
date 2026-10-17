// Architecture-unification, Subsystem 3 phase 1 (eager-mount) — provider
// guard.
//
// The plan mounts the NotificationRouter eagerly at app start
// (desktop_app_bootstrap / main_headless / the connected mobile shell read
// `notificationRouterProvider` before any notification UI exists) so the
// router classifies and dispatches for the whole app lifetime instead of
// being dead until some UI surface lazily built it.
//
// This test pins the two provider-level properties that the eager mount
// relies on:
//
//   1. A bare `container.read(notificationRouterProvider)` — no widget tree,
//      no notifications screen — yields a router that is ALREADY attached to
//      the backend event stream: an at-idle critical event (no sequence
//      running) reaches the in-app sink.
//   2. Provider caching makes the eager read and any later read (e.g. the
//      sequence executor's) the SAME instance — exactly one event-stream
//      subscription, so an event is dispatched exactly once. (The plan's
//      "eager mount must not double-subscribe" guard.)

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

SkotiqEvent _weatherUnsafeEvent() => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.error,
  category: EventCategory.safety,
  eventType: 'WeatherUnsafe',
  data: const {'reason': 'clouds'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late _FakeDiagnosticsBackend backend;
  late ProviderContainer container;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    backend = _FakeDiagnosticsBackend();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        diagnosticsBackendProvider.overrideWithValue(backend),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await backend.events.close();
    await db.close();
  });

  test('an eager read at app start (no notification UI) attaches the router '
      'to the backend event stream: an at-idle critical event reaches the '
      'in-app sink', () async {
    // Simulates desktop_app_bootstrap / main_headless: a plain read on the
    // root container during startup, before any screen exists.
    final router = container.read(notificationRouterProvider);
    expect(router, isA<NotificationRouter>());

    // No sequence running, no notifications screen open — fire a backend
    // weather-unsafe event.
    backend.events.add(_weatherUnsafeEvent());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final inApp = container.read(uiNotificationProvider);
    expect(
      inApp,
      hasLength(1),
      reason:
          'the eagerly-mounted router must classify and dispatch the '
          'at-idle event to the in-app sink',
    );
  });

  test('a later read returns the identical cached router — one subscription, '
      'an event dispatches exactly once (no double-subscribe)', () async {
    // Eager read at app start...
    final eager = container.read(notificationRouterProvider);
    // ...and the later read the executor (or a UI surface) performs.
    final later = container.read(notificationRouterProvider);
    expect(
      identical(eager, later),
      isTrue,
      reason: 'Provider caching must yield a single router instance',
    );

    backend.events.add(_weatherUnsafeEvent());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      container.read(uiNotificationProvider),
      hasLength(1),
      reason:
          'a single backend event must dispatch exactly once even after '
          'multiple provider reads',
    );
  });
}

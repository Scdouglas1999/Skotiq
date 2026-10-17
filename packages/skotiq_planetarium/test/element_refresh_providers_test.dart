import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/providers/element_refresh_providers.dart';
import 'package:skotiq_planetarium/src/services/element_refresh_service.dart';

/// Controllable stand-in for [ElementRefreshService] that never touches disk
/// or the network. Its knobs let each test decide whether the config authority
/// loads, whether the cache reports stale, and it counts [refresh] calls so a
/// test can assert the controller did (or did not) auto-fetch.
class _StubService extends ElementRefreshService {
  _StubService(String dir) : super(cacheDirectory: dir);

  bool failConfig = false;
  bool stale = true;
  bool retryDue = true;
  int refreshCalls = 0;
  RefreshedElements refreshResult = const RefreshedElements();

  @override
  Future<RefreshedElements> loadCached() async => const RefreshedElements();

  @override
  Future<ElementRefreshConfig> loadConfig() async {
    if (failConfig) throw StateError('config authority unavailable');
    return const ElementRefreshConfig();
  }

  @override
  bool isStale(RefreshedElements cached, ElementRefreshConfig config) => stale;

  @override
  Future<DateTime?> lastAttempt() async => DateTime.utc(2026, 1, 1);

  @override
  bool isAutoRetryDue(DateTime? lastAttemptAt) => retryDue;

  @override
  Future<RefreshedElements> refresh({ElementRefreshConfig? config}) async {
    refreshCalls++;
    return refreshResult;
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_er_prov_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ProviderContainer containerWith(_StubService stub) {
    final c = ProviderContainer(
      overrides: [elementRefreshServiceProvider.overrideWithValue(stub)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'controller does not auto-refresh when the config authority fails',
    () async {
      final stub = _StubService(tempDir.path)
        ..failConfig = true
        ..stale = true;
      final c = containerWith(stub);

      // Instantiate the controller (its constructor fires _init).
      c.read(elementRefreshControllerProvider);
      await pumpEventQueue();

      final status = c.read(elementRefreshControllerProvider);
      expect(
        stub.refreshCalls,
        0,
        reason: 'must not fetch from a manufactured default schedule/URL',
      );
      expect(status.error, isNotNull);
      expect(status.error, contains('configuration unavailable'));
    },
  );

  test(
    'controller auto-refreshes once when config loads and cache is stale',
    () async {
      final stub = _StubService(tempDir.path)
        ..failConfig = false
        ..stale = true;
      final c = containerWith(stub);

      c.read(elementRefreshControllerProvider);
      await pumpEventQueue();

      expect(stub.refreshCalls, 1);
      expect(c.read(elementRefreshControllerProvider).error, isNull);
    },
  );

  test('controller does not refresh when the cache is fresh', () async {
    final stub = _StubService(tempDir.path)
      ..failConfig = false
      ..stale = false;
    final c = containerWith(stub);

    c.read(elementRefreshControllerProvider);
    await pumpEventQueue();

    expect(stub.refreshCalls, 0);
    expect(c.read(elementRefreshControllerProvider).error, isNull);
  });

  test('controller honors the failed-attempt retry cooldown', () async {
    final stub = _StubService(tempDir.path)
      ..stale = true
      ..retryDue = false;
    final c = containerWith(stub);

    c.read(elementRefreshControllerProvider);
    await pumpEventQueue();

    expect(stub.refreshCalls, 0);
  });

  test('controller surfaces partial refresh failures', () async {
    final stub = _StubService(tempDir.path)
      ..stale = true
      ..refreshResult = const RefreshedElements(
        asteroidRefreshError: 'HTTP 503',
      );
    final c = containerWith(stub);

    c.read(elementRefreshControllerProvider);
    await pumpEventQueue();

    expect(stub.refreshCalls, 1);
    expect(
      c.read(elementRefreshControllerProvider).error,
      contains('Asteroids'),
    );
  });

  test('summary age uses the oldest populated source', () {
    final status = ElementRefreshStatus(
      asteroidCount: 1,
      cometCount: 1,
      asteroidsFetchedAt: DateTime.utc(2026, 6, 10),
      cometsFetchedAt: DateTime.utc(2026, 5, 1),
    );

    expect(status.lastUpdated, DateTime.utc(2026, 5, 1));
  });

  test('controller recovers after the config authority comes back', () async {
    final stub = _StubService(tempDir.path)
      ..failConfig = true
      ..stale = true;
    final c = containerWith(stub);

    c.read(elementRefreshControllerProvider);
    await pumpEventQueue();
    expect(c.read(elementRefreshControllerProvider).error, isNotNull);
    expect(stub.refreshCalls, 0);

    // Config recovers; a controller rebuild should now work end to end.
    stub.failConfig = false;
    c.invalidate(elementRefreshControllerProvider);
    c.read(elementRefreshControllerProvider);
    await pumpEventQueue();

    expect(c.read(elementRefreshControllerProvider).error, isNull);
    expect(stub.refreshCalls, 1);
  });
}

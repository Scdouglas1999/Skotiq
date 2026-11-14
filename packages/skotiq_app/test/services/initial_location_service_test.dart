import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_app/startup/initial_location_service.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../harness/mock_backend.dart';

class _Backend extends BackendNotifier {
  _Backend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
  void replace(SkotiqBackend backend) => state = backend;
}

class _RemoteBackend extends Mock implements NetworkBackend {}

class _DelayedLocationDao extends SettingsDao {
  _DelayedLocationDao(super.db);
  bool block = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setSettings(Map<String, String> settings) async {
    await super.setSettings(settings);
    if (block && settings.containsKey('observer_latitude')) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const estimate = PositioningResult(
    latitude: 40.1234,
    longitude: -75.1234,
    source: PositioningSource.ipAddress,
    provider: 'ipinfo.io',
    locationName: 'Test city',
  );
  late SkotiqDatabase db;
  late ProviderContainer container;
  late Completer<PositioningResult?> lookup;
  late Completer<void> started;
  late int calls;
  late _DelayedLocationDao dao;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = _DelayedLocationDao(db);
    lookup = Completer<PositioningResult?>();
    started = Completer<void>();
    calls = 0;
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      settingsDaoProvider.overrideWithValue(dao),
      backendProvider.overrideWith((ref) => _Backend(ref, mockBackend())),
      initialLocationLookupProvider.overrideWithValue(() {
        calls++;
        if (!started.isCompleted) started.complete();
        return lookup.future;
      }),
    ]);
    await container.read(appSettingsProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('an unset host detects and persists a starting location automatically',
      () async {
    lookup.complete(estimate);
    await container.read(initialLocationProvider.future);
    expect(calls, 1);
    final settings = await container.read(appSettingsProvider.future);
    expect(settings.latitude, estimate.latitude);
    expect(settings.longitude, estimate.longitude);
    expect(await db.settingsDao.getSetting('observer_latitude'), '40.1234');
  });

  test('a saved observing site is immediately retained without lookup',
      () async {
    await container
        .read(appSettingsProvider.notifier)
        .updateLocation(latitude: 51, longitude: 1, elevation: 90);
    await container.read(initialLocationProvider.future);
    expect(calls, 0);
    expect((await container.read(appSettingsProvider.future)).elevation, 90);
  });

  test('startup registration runs on imaging hosts, never companions', () {
    final service = alwaysOnServices
        .singleWhere((item) => item.provider == initialLocationProvider);
    expect(service.roles, {AppRole.hostGui, AppRole.hostDaemon});
  });

  for (final disconnected in [true, false]) {
    test(
        '${disconnected ? 'disconnected' : 'linked'} client does not locate this computer',
        () async {
      (container.read(backendProvider.notifier) as _Backend)
          .replace(disconnected ? DisconnectedBackend() : _RemoteBackend());
      await container.read(initialLocationProvider.future);
      expect(calls, 0);
    });
  }

  test('a coordinate edit queued before the estimate completes wins', () async {
    final detection = container.read(initialLocationProvider.future);
    await started.future;
    final edit = container
        .read(appSettingsProvider.notifier)
        .updateLocation(latitude: 51, longitude: 1);
    lookup.complete(estimate);
    await Future.wait([detection, edit]);
    expect((await container.read(appSettingsProvider.future)).latitude, 51);
    expect(await db.settingsDao.getSetting('observer_latitude'), '51.0');
  });

  test('editing and then clearing a site does not revive an old estimate',
      () async {
    final detection = container.read(initialLocationProvider.future);
    await started.future;
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.updateLocation(latitude: 51, longitude: 1);
    await notifier.updateLocation(latitude: 0, longitude: 0);
    lookup.complete(estimate);
    await detection;
    expect(
        (await container.read(appSettingsProvider.future)).hasObserverLocation,
        isFalse);
  });

  test('an incomplete field edit cancels the pending estimate', () async {
    final detection = container.read(initialLocationProvider.future);
    await started.future;
    container.read(appSettingsProvider.notifier).noteLocationEdit();
    lookup.complete(estimate);
    await detection;
    expect(
        (await container.read(appSettingsProvider.future)).hasObserverLocation,
        isFalse);
  });

  test('switching hosts discards the late estimate', () async {
    final subscription = container.listen(initialLocationProvider, (_, __) {});
    addTearDown(subscription.close);
    final detection = container.read(initialLocationProvider.future);
    await started.future;
    (container.read(backendProvider.notifier) as _Backend)
        .replace(DisconnectedBackend());
    lookup.complete(estimate);
    await detection;
    expect(await db.settingsDao.getSetting('observer_latitude'), '0.0');
  });

  test('a failed lookup leaves the observing site unset', () async {
    lookup.complete(null);
    await container.read(initialLocationProvider.future);
    expect(
        (await container.read(appSettingsProvider.future)).hasObserverLocation,
        isFalse);
  });

  test('a stalled startup lookup finishes and ignores a late answer', () async {
    await container
        .read(initialLocationProvider.future)
        .timeout(const Duration(seconds: 9));
    expect(calls, 1);
    lookup.complete(estimate);
    await Future<void>.delayed(Duration.zero);
    expect(
        (await container.read(appSettingsProvider.future)).hasObserverLocation,
        isFalse);
    expect(await db.settingsDao.getSetting('observer_latitude'), '0.0');
  });

  test('editing during persistence rolls back the startup coordinates',
      () async {
    dao.block = true;
    lookup.complete(estimate);
    final detection = container.read(initialLocationProvider.future);
    await dao.entered.future;
    container.read(appSettingsProvider.notifier).noteLocationEdit();
    dao.release.complete();
    await detection;
    expect(await db.settingsDao.getSetting('observer_latitude'), '0.0');
    expect(
        (await container.read(appSettingsProvider.future)).hasObserverLocation,
        isFalse);
  });

  test('switching hosts during persistence rolls back the startup coordinates',
      () async {
    final subscription = container.listen(initialLocationProvider, (_, __) {});
    addTearDown(subscription.close);
    dao.block = true;
    lookup.complete(estimate);
    final detection = container.read(initialLocationProvider.future);
    await dao.entered.future;
    (container.read(backendProvider.notifier) as _Backend)
        .replace(DisconnectedBackend());
    dao.release.complete();
    await detection;
    expect(await db.settingsDao.getSetting('observer_latitude'), '0.0');
  });
}

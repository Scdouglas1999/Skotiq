// Tests for the multi-night planning providers (component C6).
//
// Coverage:
//   * activeProjectIdProvider — persists the selection through the settings DAO
//     and reads it back on a fresh container (hydrate path).
//   * projectListProvider — emits the initial list and re-emits after a
//     createProject mutation (the watchChanges → re-list bridge).
//   * projectProgressProvider — recomputes after a captured_images insert
//     (accrued-from-history recomputation trigger).
//   * weekForecastProvider — surfaces WeekForecast.unavailable when the injected
//     http.Client errors (fail-closed contract), and builds a real week against
//     the active project's incomplete targets when the feed is healthy.
//
// Setup: an in-memory drift database wired through `databaseProvider`, with the
// observing location pre-seeded into `app_settings`. The OpenMeteo fetch is
// driven by a fake `http.Client` (package:http/testing MockClient) injected via
// `planningCloudProviderFactoryProvider`, so no real network access occurs.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show InsertMode, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/planning_provider.dart';
import 'package:skotiq_core/src/services/planning/project_service.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';
import 'package:skotiq_core/src/services/weather/providers/openmeteo_cloud_provider.dart';

class _FailingSettingsDao extends SettingsDao {
  _FailingSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    throw StateError('write failed');
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }

  void replaceWith(SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  /// Seed the observing location so weekForecastProvider's (0,0) guard passes.
  Future<void> seedLocation({double lat = 47.6, double lng = -122.3}) async {
    await database
        .into(database.appSettings)
        .insert(
          AppSettingsCompanion.insert(
            key: 'observer_latitude',
            value: lat.toString(),
          ),
          mode: InsertMode.insertOrReplace,
        );
    await database
        .into(database.appSettings)
        .insert(
          AppSettingsCompanion.insert(
            key: 'observer_longitude',
            value: lng.toString(),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  Future<int> insertTarget({
    required String name,
    double ra = 5.5,
    double dec = -5.4,
    double minAltitude = 20.0,
  }) {
    return database
        .into(database.targets)
        .insert(
          TargetsCompanion.insert(
            name: name,
            ra: ra,
            dec: dec,
            minAltitude: Value(minAltitude),
          ),
        );
  }

  Future<void> insertCaptures({
    required int targetId,
    required String filter,
    required int count,
    double exposureSeconds = 60.0,
  }) async {
    for (var i = 0; i < count; i++) {
      await database
          .into(database.capturedImages)
          .insert(
            CapturedImagesCompanion.insert(
              filePath: 'frame_${filter}_$i.fits',
              fileName: 'frame_${filter}_$i.fits',
              exposureDuration: exposureSeconds,
              capturedAt: DateTime(2026, 5, 12, 22, 0),
              frameType: const Value('light'),
              targetId: Value(targetId),
              filter: Value(filter),
            ),
          );
    }
  }

  /// A MockClient returning a synthetic Open-Meteo hourly cloud_cover payload.
  /// Frames are placed every hour from [start] across [hours], all at the given
  /// constant [cloudCoverPercent] so the forecast is deterministic.
  MockClient cloudClient({
    required DateTime start,
    int hours = 24 * 8,
    double cloudCoverPercent = 0.0,
  }) {
    return MockClient((request) async {
      final times = <String>[];
      final cover = <double>[];
      for (var i = 0; i < hours; i++) {
        final t = start.add(Duration(hours: i));
        // Open-Meteo emits local-naive ISO-8601 without a zone suffix.
        times.add(
          '${t.year.toString().padLeft(4, '0')}-'
          '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')}T'
          '${t.hour.toString().padLeft(2, '0')}:00',
        );
        cover.add(cloudCoverPercent);
      }
      final body = jsonEncode({
        'hourly': {'time': times, 'cloud_cover': cover},
      });
      return http.Response(body, 200);
    });
  }

  /// An http.Client that always fails the request, to exercise the fail-closed
  /// path. OpenMeteoCloudProvider catches ClientException and returns an error
  /// RadarFetchResult, which the forecast service maps to unavailable.
  MockClient failingClient() {
    return MockClient((request) async {
      throw http.ClientException('forced network failure', request.url);
    });
  }

  ProviderContainer makeContainer({
    OpenMeteoCloudProvider Function()? cloudFactory,
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        if (cloudFactory != null)
          planningCloudProviderFactoryProvider.overrideWithValue(cloudFactory),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('activeProjectIdProvider', () {
    test('defaults to null and persists / reads back a selection', () async {
      final container = makeContainer();

      // Cold start: hydrate completes with no stored value → null.
      final notifier = container.read(activeProjectIdProvider.notifier);
      await notifier.loaded;
      expect(container.read(activeProjectIdProvider), isNull);

      await notifier.setActiveProject(42);
      expect(container.read(activeProjectIdProvider), 42);

      // A fresh container over the same database hydrates the persisted value.
      final container2 = makeContainer();
      final notifier2 = container2.read(activeProjectIdProvider.notifier);
      await notifier2.loaded;
      expect(container2.read(activeProjectIdProvider), 42);
    });

    test('clearing the selection persists empty and reads back null', () async {
      final container = makeContainer();
      final notifier = container.read(activeProjectIdProvider.notifier);
      await notifier.loaded;

      await notifier.setActiveProject(7);
      expect(container.read(activeProjectIdProvider), 7);

      await notifier.setActiveProject(null);
      expect(container.read(activeProjectIdProvider), isNull);

      final container2 = makeContainer();
      final notifier2 = container2.read(activeProjectIdProvider.notifier);
      await notifier2.loaded;
      expect(container2.read(activeProjectIdProvider), isNull);
    });

    test('a corrupt stored value hydrates as null (no throw)', () async {
      await database
          .into(database.appSettings)
          .insert(
            AppSettingsCompanion.insert(
              key: 'planning.active_project_id',
              value: 'not-a-number',
            ),
            mode: InsertMode.insertOrReplace,
          );
      final container = makeContainer();
      final notifier = container.read(activeProjectIdProvider.notifier);
      await notifier.loaded;
      expect(container.read(activeProjectIdProvider), isNull);
    });

    test(
      'failed persistence leaves the confirmed selection unchanged',
      () async {
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            settingsDaoProvider.overrideWithValue(
              _FailingSettingsDao(database),
            ),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(activeProjectIdProvider.notifier);
        await notifier.loaded;

        await expectLater(notifier.setActiveProject(9), throwsStateError);

        expect(container.read(activeProjectIdProvider), isNull);
      },
    );

    test(
      'rapid selections persist and expose the last requested project',
      () async {
        final container = makeContainer();
        final notifier = container.read(activeProjectIdProvider.notifier);
        await notifier.loaded;

        await Future.wait([
          notifier.setActiveProject(3),
          notifier.setActiveProject(8),
        ]);

        expect(container.read(activeProjectIdProvider), 8);
        expect(
          await database.settingsDao.getSetting('planning.active_project_id'),
          '8',
        );
      },
    );

    test('rejects invalid persisted project ids', () async {
      final container = makeContainer();
      final notifier = container.read(activeProjectIdProvider.notifier);
      await notifier.loaded;

      await expectLater(notifier.setActiveProject(0), throwsArgumentError);

      expect(container.read(activeProjectIdProvider), isNull);
      expect(
        await database.settingsDao.getSetting('planning.active_project_id'),
        isNot('0'),
      );
    });

    test(
      'keeps active project selections isolated per remote imaging host',
      () async {
        final hostA = NetworkBackend(
          serverHost: 'rig-a.local',
          serverPort: 8080,
          pinnedFingerprint: 'fingerprint-a',
          autoConnectWebSocket: false,
        );
        final hostB = NetworkBackend(
          serverHost: 'rig-b.local',
          serverPort: 8080,
          pinnedFingerprint: 'fingerprint-b',
          autoConnectWebSocket: false,
        );
        late _TestBackendNotifier backendNotifier;
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            backendProvider.overrideWith((ref) {
              backendNotifier = _TestBackendNotifier(ref, hostA);
              return backendNotifier;
            }),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(hostA.dispose);
        addTearDown(hostB.dispose);

        final notifier = container.read(activeProjectIdProvider.notifier);
        await notifier.loaded;
        await notifier.setActiveProject(11);
        expect(container.read(activeProjectIdProvider), 11);

        backendNotifier.replaceWith(hostB);
        await notifier.loaded;
        expect(container.read(activeProjectIdProvider), isNull);
        await notifier.setActiveProject(22);
        expect(container.read(activeProjectIdProvider), 22);

        final hostAReconnected = NetworkBackend(
          serverHost: 'RIG-A.LOCAL',
          serverPort: 8080,
          pinnedFingerprint: 'FINGERPRINT-A',
          autoConnectWebSocket: false,
        );
        backendNotifier.replaceWith(hostAReconnected);
        await notifier.loaded;

        expect(container.read(activeProjectIdProvider), 11);
      },
    );
  });

  group('projectListProvider', () {
    test('emits initial empty list then re-emits after createProject', () async {
      final container = makeContainer();
      final service = container.read(projectServiceProvider);

      // Initial emit.
      final first = await container.read(projectListProvider.future);
      expect(first, isEmpty);

      await service.createProject(name: 'Winter Nebulae');

      // The watchChanges → re-list bridge must surface the new project. Poll
      // the provider's future until the mutation propagates through the stream.
      List<Object?> latest = const [];
      for (var attempt = 0; attempt < 50; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        latest = await container.read(projectListProvider.future);
        if (latest.isNotEmpty) break;
      }
      expect(latest, hasLength(1));
    });

    test('provider disposal closes the project mutation stream', () async {
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      final service = container.read(projectServiceProvider);
      final done = Completer<void>();
      service.watchChanges().listen(null, onDone: done.complete);

      container.dispose();

      await done.future.timeout(const Duration(seconds: 1));
    });
  });

  group('projectProgressProvider', () {
    test('recomputes after a captured_images insert', () async {
      final container = makeContainer();
      final service = container.read(projectServiceProvider);
      final goalService = container.read(integrationGoalServiceProvider);

      final projectId = await service.createProject(name: 'Campaign');
      final targetId = await insertTarget(name: 'M42');
      await service.addTarget(projectId: projectId, targetId: targetId);
      await goalService.upsert(
        IntegrationGoal(
          targetId: targetId,
          filter: 'Lum',
          exposureSeconds: 60.0,
          frameCount: 100,
          priority: 5,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

      // Keep the provider alive across the mutation so its autoDispose does not
      // tear it down between reads.
      final sub = container.listen(
        projectProgressProvider(projectId),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      final before = await container.read(
        projectProgressProvider(projectId).future,
      );
      expect(before.targets.single.filters.single.capturedFrames, 0);

      await insertCaptures(targetId: targetId, filter: 'lum', count: 30);

      // The allDbImagesProvider stream re-emits on the new capture; the
      // FutureProvider depends on it and recomputes. Poll until accrued updates.
      var captured = before.targets.single.filters.single.capturedFrames;
      for (var attempt = 0; attempt < 50; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final progress = await container.read(
          projectProgressProvider(projectId).future,
        );
        captured = progress.targets.single.filters.single.capturedFrames;
        if (captured == 30) break;
      }
      expect(captured, 30);
    });
  });

  group('weekForecastProvider', () {
    test('throws StateError when the observing location is unset', () async {
      // No location seeded → (0,0) guard fires.
      final container = makeContainer(
        cloudFactory: () => OpenMeteoCloudProvider(
          httpClient: cloudClient(start: DateTime.now().toUtc()),
        ),
      );
      await expectLater(
        container.read(weekForecastProvider.future),
        throwsStateError,
      );
    });

    test(
      'surfaces WeekForecast.unavailable when the http client errors',
      () async {
        // FAIL-CLOSED: a network failure must never become a fabricated clear
        // week — the forecast comes back explicitly unavailable.
        await seedLocation();
        final container = makeContainer(
          cloudFactory: () =>
              OpenMeteoCloudProvider(httpClient: failingClient()),
        );

        // Keep the autoDispose forecast alive across its async build.
        final sub = container.listen(weekForecastProvider, (_, __) {});
        addTearDown(sub.close);

        final week = await container.read(weekForecastProvider.future);
        expect(week.available, isFalse);
        expect(week.nights, isEmpty);
        expect(week.unavailableReason, isNotNull);
      },
    );

    test('builds a week against the active project incomplete targets', () async {
      await seedLocation();

      // An active project with one incomplete target (Orion, well-placed at the
      // seeded mid-northern latitude during winter-ish dates).
      final tmpContainer = makeContainer();
      final service = tmpContainer.read(projectServiceProvider);
      final goalService = tmpContainer.read(integrationGoalServiceProvider);
      final projectId = await service.createProject(name: 'Orion');
      final targetId = await insertTarget(name: 'M42', ra: 5.6, dec: -5.4);
      await service.addTarget(projectId: projectId, targetId: targetId);
      await goalService.upsert(
        IntegrationGoal(
          targetId: targetId,
          filter: 'Ha',
          exposureSeconds: 300.0,
          frameCount: 30,
          priority: 7,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
      tmpContainer.dispose();

      // A healthy, fully-clear week-long feed anchored to "now".
      final container = makeContainer(
        cloudFactory: () => OpenMeteoCloudProvider(
          httpClient: cloudClient(
            start: DateTime.now().toUtc().subtract(const Duration(days: 1)),
            cloudCoverPercent: 0.0,
          ),
        ),
      );
      final notifier = container.read(activeProjectIdProvider.notifier);
      await notifier.loaded;
      await notifier.setActiveProject(projectId);

      // Keep the autoDispose forecast alive across its async build.
      final sub = container.listen(weekForecastProvider, (_, __) {});
      addTearDown(sub.close);

      final week = await container.read(weekForecastProvider.future);
      expect(week.available, isTrue);
      expect(week.nights, hasLength(7));
      // At a northern winter site the feed is clear, so at least one night
      // should have a real dark window with the target up — i.e. a non-null
      // best night. (We do not assert a specific score, only that the pipeline
      // produced an available, target-bearing forecast rather than unavailable.)
      final available = week.nights.where((n) => n.forecastAvailable).toList();
      expect(available, isNotEmpty);
    });

    test(
      'with no active project, falls back to catalog incomplete-goal targets',
      () async {
        await seedLocation();

        // No project active, but a catalog target carries an unmet goal.
        final setupContainer = makeContainer();
        final goalService = setupContainer.read(integrationGoalServiceProvider);
        final targetId = await insertTarget(name: 'M31', ra: 0.71, dec: 41.27);
        await goalService.upsert(
          IntegrationGoal(
            targetId: targetId,
            filter: 'Lum',
            exposureSeconds: 60.0,
            frameCount: 50,
            priority: 5,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        );
        setupContainer.dispose();

        final container = makeContainer(
          cloudFactory: () => OpenMeteoCloudProvider(
            httpClient: cloudClient(
              start: DateTime.now().toUtc().subtract(const Duration(days: 1)),
              cloudCoverPercent: 0.0,
            ),
          ),
        );
        // Ensure the active-project selection has hydrated to null.
        final notifier = container.read(activeProjectIdProvider.notifier);
        await notifier.loaded;
        expect(container.read(activeProjectIdProvider), isNull);

        // Keep the autoDispose forecast alive across its async build.
        final sub = container.listen(weekForecastProvider, (_, __) {});
        addTearDown(sub.close);

        final week = await container.read(weekForecastProvider.future);
        expect(week.available, isTrue);
        expect(week.nights, hasLength(7));
      },
    );
  });
}

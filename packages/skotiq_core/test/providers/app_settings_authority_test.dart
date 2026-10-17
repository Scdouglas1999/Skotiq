import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

class _FailingReadSettingsDao extends SettingsDao {
  _FailingReadSettingsDao(super.db);

  int writes = 0;

  @override
  Future<Map<String, String>> getAllSettings() async {
    throw StateError('settings database unavailable');
  }

  @override
  Future<void> setSetting(String key, String value) async {
    writes++;
  }

  @override
  Future<void> setSettings(Map<String, String> settings) async {
    writes++;
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const models.AppSettings());
  });

  group('unavailable application settings', () {
    late SkotiqDatabase database;
    late _FailingReadSettingsDao dao;
    late ProviderContainer container;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      dao = _FailingReadSettingsDao(database);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          settingsDaoProvider.overrideWithValue(dao),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test(
      'individual setter refuses to write defaults after load failure',
      () async {
        await expectLater(
          container.read(appSettingsProvider.future),
          throwsStateError,
        );

        await expectLater(
          container.read(appSettingsProvider.notifier).setTheme('light'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('refusing saving theme'),
            ),
          ),
        );
        expect(dao.writes, 0);
      },
    );

    test(
      'remote import and export refuse manufactured default snapshots',
      () async {
        await expectLater(
          container.read(appSettingsProvider.future),
          throwsStateError,
        );
        final notifier = container.read(appSettingsProvider.notifier);

        await expectLater(
          notifier.applyRemoteSettings(
            const models.AppSettings(theme: 'light'),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('refusing applying a remote settings snapshot'),
            ),
          ),
        );
        expect(
          notifier.exportRemoteSettings,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('refusing exporting a remote settings snapshot'),
            ),
          ),
        );
        expect(dao.writes, 0);
      },
    );
  });

  test(
    'host import preserves settings omitted from the remote wire model',
    () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.settingsDao.setSettings({
        'database_path': '/host/database.sqlite',
        'logs_path': '/host/logs',
        'theme': 'dark',
      });
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.applyRemoteSettings(
        const models.AppSettings(theme: 'light', language: 'fr'),
      );

      final state = container.read(appSettingsProvider).requireValue;
      expect(state.theme, 'light');
      expect(state.language, 'fr');
      expect(state.databasePath, '/host/database.sqlite');
      expect(state.logsPath, '/host/logs');
      expect(
        await database.settingsDao.getSetting('database_path'),
        '/host/database.sqlite',
      );
      expect(await database.settingsDao.getSetting('logs_path'), '/host/logs');
    },
  );

  test('host-only import is rejected on a network client', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(
      () => backend.getSettings(),
    ).thenAnswer((_) async => const models.AppSettings());
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    await expectLater(
      container
          .read(appSettingsProvider.notifier)
          .applyRemoteSettings(const models.AppSettings(theme: 'light')),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('host-only'),
        ),
      ),
    );
  });

  // The local (desktop / headless-host) write path persists and reflects
  // settings whose DB key is intentionally NOT carried by the remote wire
  // model. `_applySettingsMap`'s `_assertKeysRemotable` guard is a remote-write
  // concern; routing local patches through it makes every host-only setter
  // throw `UnsupportedError` AFTER the DAO write, surfacing a spurious write
  // failure and skipping the setter's own state patch.
  group('local host writes of non-remotable settings', () {
    late SkotiqDatabase database;
    late ProviderContainer container;

    setUp(() async {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      await container.read(appSettingsProvider.future);
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test('single-key setter (start_minimized) persists and patches', () async {
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setStartMinimized(true);

      expect(
        container.read(appSettingsProvider).requireValue.startMinimized,
        isTrue,
      );
      expect(await database.settingsDao.getSetting('start_minimized'), 'true');
      expect(container.read(appSettingsWriteFailureProvider), isNull);
    });

    test('host filesystem paths (logs/database) persist and patch', () async {
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setLogsPath('/host/logs');
      await notifier.setDatabasePath('/host/db.sqlite');

      final state = container.read(appSettingsProvider).requireValue;
      expect(state.logsPath, '/host/logs');
      expect(state.databasePath, '/host/db.sqlite');
      expect(await database.settingsDao.getSetting('logs_path'), '/host/logs');
      expect(
        await database.settingsDao.getSetting('database_path'),
        '/host/db.sqlite',
      );
      expect(container.read(appSettingsWriteFailureProvider), isNull);
    });

    test(
      'horizon-mask blob (non-remotable JSON) persists and patches',
      () async {
        final notifier = container.read(appSettingsProvider.notifier);
        const mask =
            '{"N":10.0,"NE":0.0,"E":0.0,"SE":0.0,"S":0.0,"SW":0.0,'
            '"W":0.0,"NW":0.0}';
        await notifier.setHorizonProfileJson(mask);

        expect(
          container.read(appSettingsProvider).requireValue.horizonProfileJson,
          mask,
        );
        expect(
          await database.settingsDao.getSetting('horizon_profile_json'),
          mask,
        );
        expect(container.read(appSettingsWriteFailureProvider), isNull);
      },
    );

    test(
      'batched setter co-writing a non-remotable compat key persists both',
      () async {
        final notifier = container.read(appSettingsProvider.notifier);
        await notifier.setImageOutputPath('/host/captures');

        expect(
          container.read(appSettingsProvider).requireValue.imageOutputPath,
          '/host/captures',
        );
        expect(
          await database.settingsDao.getSetting('image_output_path'),
          '/host/captures',
        );
        // The compatibility key is NOT in the remote wire model; the batched
        // local write must still persist it.
        expect(
          await database.settingsDao.getSetting('default_image_directory'),
          '/host/captures',
        );
        expect(container.read(appSettingsWriteFailureProvider), isNull);
      },
    );
  });

  // Device-local display prefs (theme/accent/font/UI-scale) belong to the
  // device rendering the UI, not the imaging host. On a remote client they
  // persist LOCALLY and must NOT be pushed over `POST /api/settings` (admin-
  // scoped — a control-token phone got "Access denied" and the theme
  // reverted). A reconnect must keep the device's own choice.
  group('device-local display prefs on a network client', () {
    late SkotiqDatabase database;
    late _MockNetworkBackend backend;
    late ProviderContainer container;

    setUp(() async {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      // Host serves its own theme (dark); the device will override to redNight.
      when(
        () => backend.getSettings(),
      ).thenAnswer((_) async => const models.AppSettings(theme: 'dark'));
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      await container.read(appSettingsProvider.future);
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test('setTheme persists locally and never calls updateSettings', () async {
      await container.read(appSettingsProvider.notifier).setTheme('redNight');

      // Applied in memory...
      expect(
        container.read(appSettingsProvider).valueOrNull?.theme,
        'redNight',
      );
      // ...persisted to the LOCAL store...
      expect(await database.settingsDao.getSetting('theme'), 'redNight');
      // ...and NOT pushed to the host (that endpoint is admin-scoped).
      verifyNever(() => backend.updateSettings(any()));
      expect(container.read(appSettingsWriteFailureProvider), isNull);
    });

    test('local theme overlays the host value after a reload', () async {
      await container.read(appSettingsProvider.notifier).setTheme('redNight');
      // Force a rebuild (the reconnect path re-fetches host settings = dark).
      container.invalidate(appSettingsProvider);
      final reloaded = await container.read(appSettingsProvider.future);
      expect(reloaded.theme, 'redNight');
    });
  });
}

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        BackendNotifier,
        DarkGroupKey,
        NetworkBackend,
        SkotiqBackend,
        backendProvider;
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/dark_library_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/services/calibration_service.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dark library / calibration unification (§2.1 WIRE-UP #6)', () {
    late ProviderContainer container;
    late SkotiqDatabase database;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test('autoDarkSubtractEnabledProvider reads calibrationSettings', () async {
      // This provider and the calibration pipeline share one backing value:
      // `dark_library.auto_subtract` and `calibration.auto_calibrate` must not
      // diverge.
      final notifier = container.read(calibrationSettingsProvider.notifier);
      await notifier.setAutoCalibrate(true);

      expect(container.read(autoDarkSubtractEnabledProvider), isTrue);

      await notifier.setAutoCalibrate(false);
      expect(container.read(autoDarkSubtractEnabledProvider), isFalse);
    });

    test(
      'legacy dark_library.auto_subtract migrates into calibration on load',
      () async {
        // Pre-seed the legacy key directly into the settings DAO so we
        // simulate an upgrade from a build that wrote there. Drift seeds
        // default settings on first open; use insertOrReplace so the test
        // works whether or not a default is present.
        await database
            .into(database.appSettings)
            .insert(
              AppSettingsCompanion.insert(
                key: 'dark_library.auto_subtract',
                value: 'true',
              ),
              mode: InsertMode.insertOrReplace,
            );

        // Invalidate the settings cache so the calibration notifier reads
        // the freshly-seeded legacy value on next read.
        container.invalidate(allSettingsProvider);
        // Force the async load microtask to run.
        await Future<void>.delayed(Duration.zero);
        // Reading the calibration notifier should observe the legacy
        // value, lift it forward into calibration.auto_calibrate, then
        // delete the legacy key.
        final notifier = container.read(calibrationSettingsProvider.notifier);
        // Wait until the migration write completes.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Calibration store now reports the migrated value.
        expect(notifier.state.autoCalibrate, isTrue);

        // Legacy key is gone.
        final legacy = await database
            .customSelect(
              'SELECT value FROM app_settings WHERE key = ?',
              variables: [const Variable<String>('dark_library.auto_subtract')],
            )
            .get();
        expect(legacy, isEmpty);
      },
    );

    test('remote settings read and write the imaging host only', () async {
      final backend = _MockNetworkBackend();
      when(backend.getDarkLibrarySettings).thenAnswer(
        (_) async => {'autoCalibrate': true, 'temperatureTolerance': 1.5},
      );
      when(
        () => backend.updateDarkLibrarySettings(autoCalibrate: false),
      ).thenAnswer((_) async => {'ok': true});
      when(
        () => backend.updateDarkLibrarySettings(temperatureTolerance: 2.0),
      ).thenAnswer((_) async => {'ok': true});
      final remote = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(remote.dispose);

      final settings = await remote.read(darkLibrarySettingsProvider.future);
      expect(settings.autoCalibrate, isTrue);
      expect(settings.temperatureTolerance, 1.5);

      final actions = remote.read(darkLibrarySettingsActionsProvider);
      await actions.setAutoCalibrate(false);
      await actions.setTemperatureTolerance(2);

      verify(
        () => backend.updateDarkLibrarySettings(autoCalibrate: false),
      ).called(1);
      verify(
        () => backend.updateDarkLibrarySettings(temperatureTolerance: 2.0),
      ).called(1);
    });

    test(
      'complete calibration settings read and write the imaging host only',
      () async {
        final backend = _MockNetworkBackend();
        when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
        when(backend.getCalibrationSettings).thenAnswer(
          (_) async => {
            'autoCalibrate': true,
            'masterFlatPath': '/host/master_flat.fits',
            'masterBiasPath': null,
            'autoDarkFromLibrary': false,
            'manualDarkPath': '/host/master_dark.fits',
          },
        );
        when(
          () => backend.updateCalibrationSettings(any()),
        ).thenAnswer((_) async => const {'status': 'updated'});

        final localFlatBefore = await database.settingsDao.getSetting(
          'calibration.master_flat_path',
        );
        final remote = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(remote.dispose);

        final notifier = remote.read(calibrationSettingsProvider.notifier);
        expect(notifier.state.isLoading, isTrue);
        // Programmatic callers are allowed to write before the initial GET
        // completes. The patch must wait for that snapshot and preserve every
        // unrelated host field instead of re-applying constructor defaults.
        await notifier.setMasterBiasPath('/host/new_bias.fits');

        expect(notifier.state.isLoading, isFalse);
        expect(notifier.state.loadError, null);
        expect(notifier.state.autoCalibrate, isTrue);
        expect(notifier.state.masterFlatPath, '/host/master_flat.fits');
        expect(notifier.state.masterBiasPath, '/host/new_bias.fits');
        expect(notifier.state.autoDarkFromLibrary, isFalse);
        expect(notifier.state.manualDarkPath, '/host/master_dark.fits');

        await notifier.setMasterFlatPath('/host/new_flat.fits');
        await notifier.setAutoDarkFromLibrary(true);

        verify(
          () => backend.updateCalibrationSettings({
            'masterBiasPath': '/host/new_bias.fits',
          }),
        ).called(1);
        verify(
          () => backend.updateCalibrationSettings({
            'masterFlatPath': '/host/new_flat.fits',
          }),
        ).called(1);
        verify(
          () =>
              backend.updateCalibrationSettings({'autoDarkFromLibrary': true}),
        ).called(1);
        expect(
          await database.settingsDao.getSetting('calibration.master_flat_path'),
          localFlatBefore,
        );
      },
    );

    test(
      'remote library management actions never mutate the client DAO',
      () async {
        final backend = _MockNetworkBackend();
        when(
          () => backend.createDarkLibraryMaster(
            exposureTime: 60,
            gain: 100,
            offset: 10,
            binX: 1,
            binY: 1,
            outputPath: '/host/master.fits',
            frameType: 'dark',
          ),
        ).thenAnswer((_) async => {'id': 8, 'frameCount': 12});
        when(backend.cleanDarkLibraryOrphans).thenAnswer((_) async => 2);
        when(
          () => backend.deleteDark(4, deleteFile: true),
        ).thenAnswer((_) async {});
        when(
          () => backend.clearDarkLibrary(deleteFiles: false),
        ).thenAnswer((_) async => 5);
        when(
          () => backend.deleteDarkLibraryGroup(
            exposureTime: 60,
            gain: 100,
            offset: 10,
            binX: 1,
            binY: 1,
            frameType: 'dark',
            deleteFiles: true,
          ),
        ).thenAnswer((_) async => 3);
        when(() => backend.listDarks()).thenAnswer((_) async => const []);
        final remote = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(remote.dispose);
        final notifier = remote.read(darkLibraryNotifierProvider.notifier);

        await notifier.createMasterDark(
          exposureTime: 60,
          gain: 100,
          offset: 10,
          binX: 1,
          binY: 1,
          outputPath: '/host/master.fits',
        );
        await notifier.cleanOrphans();
        await notifier.deleteEntry(4, deleteFile: true);
        await notifier.clearLibrary();
        final removed = await notifier.deleteGroup(
          const DarkGroupKey(
            exposureTime: 60,
            gain: 100,
            offset: 10,
            binX: 1,
            binY: 1,
            frameType: 'dark',
          ),
          deleteFiles: true,
        );

        expect(removed, 3);
        expect(await database.darkLibraryDao.getAllEntries(), isEmpty);
        verify(backend.cleanDarkLibraryOrphans).called(1);
        verify(() => backend.deleteDark(4, deleteFile: true)).called(1);
        verify(() => backend.clearDarkLibrary(deleteFiles: false)).called(1);
      },
    );
  });
}

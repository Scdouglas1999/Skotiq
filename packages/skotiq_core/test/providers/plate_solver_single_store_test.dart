// "Which plate solver runs" had two stores that never agreed.
//
// The store the solve dispatcher reads is the native `PlateSolverPreference`
// (`platesolver.json`), which the Plate Solving page writes. The `plate_solver`
// app-setting was a second, independent row: no UI wrote it, its seed was
// 'ASTAP', and it was what backup export, `/api/settings`, and the science
// provenance label all read — so a rig set to Auto with only astrometry.net
// installed still stamped every science record "ASTAP" and exported "ASTAP".
//
// The app-setting is now a projection of the preference: refreshed when
// settings load, written through when set, and never consulted for which
// engine actually ran.

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;

class _Backend extends Mock implements SkotiqBackend {
  @override
  Stream<SkotiqEvent> get eventStream => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  void dispose() {}
}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

PlateSolveResult _solved() => PlateSolveResult(
  success: true,
  ra: 150,
  dec: 45,
  rotation: 0,
  pixelScale: 1,
  fieldWidth: 2,
  fieldHeight: 1.5,
  solveTimeSecs: 0,
  cd11: 0,
  cd12: 0,
  cd21: 0,
  cd22: 0,
  sipAOrder: 0,
  sipBOrder: 0,
  sipACoeffs: Float64List(0),
  sipBCoeffs: Float64List(0),
  sipApOrder: 0,
  sipBpOrder: 0,
  sipApCoeffs: Float64List(0),
  sipBpCoeffs: Float64List(0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const PlateSolverPreference());
  });

  late SkotiqDatabase database;
  late _Backend backend;
  late ProviderContainer container;

  ProviderContainer build() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
    ],
  );

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    backend = _Backend();
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('selecting a solver writes the store the dispatcher reads', () async {
    when(
      () => backend.getPlateSolverConfig(),
    ).thenAnswer((_) async => const PlateSolverPreference());
    when(() => backend.setPlateSolverConfig(any())).thenAnswer((_) async {});
    container = build();
    await container.read(appSettingsProvider.future);

    await container
        .read(appSettingsProvider.notifier)
        .setPlateSolver('Astrometry.net');

    final applied =
        verify(() => backend.setPlateSolverConfig(captureAny())).captured.last
            as PlateSolverPreference;
    expect(applied.choice, PlateSolverChoice.astrometry);
    // Only then is the projection allowed to claim the selection.
    expect(
      await database.settingsDao.getSetting('plate_solver'),
      'Astrometry.net',
    );
    expect(
      container.read(appSettingsProvider).value!.plateSolver,
      'Astrometry.net',
    );
  });

  test('a rejected selection is not recorded as applied', () async {
    when(
      () => backend.getPlateSolverConfig(),
    ).thenAnswer((_) async => const PlateSolverPreference());
    when(
      () => backend.setPlateSolverConfig(any()),
    ).thenThrow(StateError('solver config is read-only on this host'));
    container = build();
    await container.read(appSettingsProvider.future);
    await database.settingsDao.setSetting('plate_solver', 'Auto');

    await expectLater(
      container.read(appSettingsProvider.notifier).setPlateSolver('ASTAP'),
      throwsA(isA<StateError>()),
    );
    expect(await database.settingsDao.getSetting('plate_solver'), 'Auto');
  });

  test(
    'the Plate Solving page carries its choice into the projection',
    () async {
      // The page writes the preference directly, so the projection has to
      // follow it or export/`/api/settings` go stale the moment it is used.
      await database.settingsDao.setSetting('plate_solver', 'Auto');
      when(
        () => backend.getPlateSolverConfig(),
      ).thenAnswer((_) async => const PlateSolverPreference());
      when(() => backend.setPlateSolverConfig(any())).thenAnswer((_) async {});
      when(
        () => backend.detectPlateSolvers(),
      ).thenAnswer((_) async => const PlateSolverDetection());
      container = build();
      await container.read(appSettingsProvider.future);

      final saved = await container
          .read(plateSolverSettingsNotifierProvider.notifier)
          .updatePreference(
            const PlateSolverPreference(choice: PlateSolverChoice.astap),
          );

      expect(saved, isTrue);
      expect(await database.settingsDao.getSetting('plate_solver'), 'ASTAP');
      expect(container.read(appSettingsProvider).value!.plateSolver, 'ASTAP');
    },
  );

  test('a settings snapshot cannot move the projection', () async {
    when(
      () => backend.getPlateSolverConfig(),
    ).thenAnswer((_) async => const PlateSolverPreference());
    when(() => backend.setPlateSolverConfig(any())).thenAnswer((_) async {});
    container = build();
    final loaded = await container.read(appSettingsProvider.future);
    expect(loaded.plateSolver, 'Auto');

    // What the headless host does with POST /api/settings. The wire model
    // defaults plateSolver to 'ASTAP', so a partial post built without a
    // previous snapshot carries a value the operator never chose.
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.applyRemoteSettings(
      const models.AppSettings(theme: 'light'),
    );

    // The engine preference is untouched, and the projection still reports
    // the selection that is actually in force rather than the posted one.
    verifyNever(() => backend.setPlateSolverConfig(any()));
    expect(container.read(appSettingsProvider).value!.plateSolver, 'Auto');
    expect(await database.settingsDao.getSetting('plate_solver'), 'Auto');
    // The rest of the snapshot still applies.
    expect(container.read(appSettingsProvider).value!.theme, 'light');
  });

  test('loading settings refreshes a stale projection', () async {
    // A profile seeded by an older build: the row says ASTAP...
    await database.settingsDao.setSetting('plate_solver', 'ASTAP');
    // ...while the store that dispatches solves says Auto.
    when(() => backend.getPlateSolverConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(choice: PlateSolverChoice.auto),
    );
    container = build();

    final settings = await container.read(appSettingsProvider.future);

    expect(settings.plateSolver, 'Auto');
    // Persisted too, so a backup taken without touching any setting stops
    // carrying the contradiction.
    expect(await database.settingsDao.getSetting('plate_solver'), 'Auto');
  });

  test('science provenance reads the preference, not the projection', () async {
    // Settings load while the preference says Auto, so the projection is
    // 'Auto' and differs from the resolved solver the record must carry.
    var preference = const PlateSolverPreference(
      choice: PlateSolverChoice.auto,
    );
    when(
      () => backend.getPlateSolverConfig(),
    ).thenAnswer((_) async => preference);
    when(() => backend.detectPlateSolvers()).thenAnswer(
      (_) async => const PlateSolverDetection(
        astapPath: '/usr/bin/astap',
        catalogPath: '/usr/share/astap',
      ),
    );
    when(
      () => backend.plateSolve(
        imagePath: any(named: 'imagePath'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        fovDegrees: any(named: 'fovDegrees'),
        timeoutSeconds: any(named: 'timeoutSeconds'),
      ),
    ).thenAnswer((_) async => _solved());
    container = build();
    final loaded = await container.read(appSettingsProvider.future);
    expect(loaded.plateSolver, 'Auto');

    // The operator switches engines on the Plate Solving page, which writes
    // the preference directly.
    preference = const PlateSolverPreference(
      choice: PlateSolverChoice.astrometry,
    );

    final wcs = await container
        .read(scienceBackendProvider)
        .solveForScience('/tmp/frame.fits', const SolveOptions());

    expect(wcs, isNotNull);
    expect(wcs!.solverId, 'Astrometry.net');
  });

  test('Auto does not name one engine when either could have solved', () async {
    when(() => backend.getPlateSolverConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(choice: PlateSolverChoice.auto),
    );
    when(() => backend.detectPlateSolvers()).thenAnswer(
      (_) async => const PlateSolverDetection(
        astapPath: '/usr/bin/astap',
        catalogPath: '/usr/share/astap',
        astrometryPath: '/usr/bin/solve-field',
      ),
    );
    when(
      () => backend.plateSolve(
        imagePath: any(named: 'imagePath'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        fovDegrees: any(named: 'fovDegrees'),
        timeoutSeconds: any(named: 'timeoutSeconds'),
      ),
    ).thenAnswer((_) async => _solved());
    container = build();
    await container.read(appSettingsProvider.future);

    final wcs = await container
        .read(scienceBackendProvider)
        .solveForScience('/tmp/frame.fits', const SolveOptions());

    // Auto tries ASTAP and falls back to astrometry.net per frame, and the
    // solve result carries no engine id — so naming one would be a guess.
    expect(wcs!.solverId, 'ASTAP or Astrometry.net');
  });
}

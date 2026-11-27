// "Which plate solver runs" had two stores that never agreed.
//
// The store the solve dispatcher reads is the native `PlateSolverPreference`
// (`platesolver.json`), which the Plate Solving page writes. The `plate_solver`
// app-setting was a second, independent row: no UI wrote it, its seed was
// 'ASTAP', and it was what backup export, `/api/settings`, and the science
// provenance label all read — so a rig set to Auto with only astrometry.net
// installed still stamped every science record "ASTAP" and exported "ASTAP".
//
// The settings are now held by the preference ([Setting.heldNatively]): the
// settings document is built from it, the stored rows are never read, and
// neither is consulted for which engine actually ran.

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
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

  test(
    'the settings document names the choice the Plate Solving page saved',
    () async {
      await database.settingsDao.setSetting('plate_solver', 'Auto');
      var preference = const PlateSolverPreference();
      when(
        () => backend.getPlateSolverConfig(),
      ).thenAnswer((_) async => preference);
      when(() => backend.setPlateSolverConfig(any())).thenAnswer((call) async {
        preference = call.positionalArguments.single as PlateSolverPreference;
      });
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
      final served = await container
          .read(appSettingsProvider.notifier)
          .exportHostSettings();
      expect(served.plateSolver, 'ASTAP');
    },
  );

  test('a settings snapshot cannot move the solver choice', () async {
    when(
      () => backend.getPlateSolverConfig(),
    ).thenAnswer((_) async => const PlateSolverPreference());
    when(() => backend.setPlateSolverConfig(any())).thenAnswer((_) async {});
    container = build();
    await container.read(appSettingsProvider.future);

    // What the headless host does with POST /api/settings. The wire model
    // defaults plateSolver to 'ASTAP', so a partial post built without a
    // previous snapshot carries a value the operator never chose.
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.applyRemoteSettings(
      const models.AppSettings(theme: 'light'),
    );

    // The engine preference is untouched, and the settings document still
    // reports the selection that is actually in force.
    verifyNever(() => backend.setPlateSolverConfig(any()));
    expect((await notifier.exportHostSettings()).plateSolver, 'Auto');
    // The rest of the snapshot still applies.
    expect(container.read(appSettingsProvider).value!.theme, 'light');
  });

  test('a solver path in a settings snapshot reaches the preference', () async {
    when(() => backend.getPlateSolverConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(choice: PlateSolverChoice.astap),
    );
    when(() => backend.setPlateSolverConfig(any())).thenAnswer((_) async {});
    container = build();
    await container.read(appSettingsProvider.future);

    await container
        .read(appSettingsProvider.notifier)
        .applyRemoteSettings(const models.AppSettings(astapPath: '/opt/astap'));

    final written =
        verify(() => backend.setPlateSolverConfig(captureAny())).captured.last
            as PlateSolverPreference;
    expect(written.astapPath, '/opt/astap');
    expect(written.choice, PlateSolverChoice.astap);
  });

  test(
    'a solver path posted back to its earlier value reaches the preference',
    () async {
      // The host's Plate Solving page moves ASTAP from O to X; a linked client
      // that sets it back to O must reach the store the solver reads, not be
      // compared with a copy that still says O.
      var preference = const PlateSolverPreference(
        choice: PlateSolverChoice.astap,
        astapPath: '/opt/old/astap',
      );
      when(
        () => backend.getPlateSolverConfig(),
      ).thenAnswer((_) async => preference);
      when(() => backend.setPlateSolverConfig(any())).thenAnswer((call) async {
        preference = call.positionalArguments.single as PlateSolverPreference;
      });
      when(
        () => backend.detectPlateSolvers(),
      ).thenAnswer((_) async => const PlateSolverDetection());
      container = build();
      await container.read(appSettingsProvider.future);
      final saved = await container
          .read(plateSolverSettingsNotifierProvider.notifier)
          .updatePreference(preference.copyWith(astapPath: '/opt/new/astap'));
      expect(saved, isTrue);
      expect(preference.astapPath, '/opt/new/astap');

      final notifier = container.read(appSettingsProvider.notifier);
      final served = await notifier.exportHostSettings();
      expect(served.astapPath, '/opt/new/astap');
      await notifier.applyRemoteSettings(
        served.copyWith(astapPath: '/opt/old/astap'),
      );

      expect(preference.astapPath, '/opt/old/astap');
      expect((await notifier.exportHostSettings()).astapPath, '/opt/old/astap');
    },
  );

  test(
    'an unreadable preference is served as a fresh install, not a stored copy',
    () async {
      var readable = true;
      when(() => backend.getPlateSolverConfig()).thenAnswer((_) async {
        if (!readable) throw StateError('platesolver.json cannot be read');
        return const PlateSolverPreference(
          choice: PlateSolverChoice.astap,
          astapPath: '/opt/astap/astap',
          astrometryPath: '/usr/bin/solve-field',
        );
      });
      container = build();
      await container.read(appSettingsProvider.future);
      readable = false;

      final notifier = container.read(appSettingsProvider.notifier);
      final served = await notifier.exportHostSettings();
      expect(served.plateSolver, 'Auto');
      expect(served.astapPath, '');
      expect(served.astrometryPath, '');
      expect(await notifier.solverPreferenceRows(), {
        'plate_solver': 'Auto',
        'astap_path': '',
        'astrometry_path': '',
      });
    },
  );

  test('a stored solver row is never read', () async {
    // A database written by an older build: the row says ASTAP...
    await database.settingsDao.setSetting('plate_solver', 'ASTAP');
    // ...while the store that dispatches solves says Auto.
    when(() => backend.getPlateSolverConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(choice: PlateSolverChoice.auto),
    );
    container = build();
    await container.read(appSettingsProvider.future);

    final served = await container
        .read(appSettingsProvider.notifier)
        .exportHostSettings();
    expect(served.plateSolver, 'Auto');
    expect(
      await container.read(appSettingsProvider.notifier).solverPreferenceRows(),
      {'plate_solver': 'Auto', 'astap_path': '', 'astrometry_path': ''},
    );
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
    await container.read(appSettingsProvider.future);

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

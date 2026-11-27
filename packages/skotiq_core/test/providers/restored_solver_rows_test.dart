// A replace-restore swaps the database, not the native solver preference (a
// file beside it). The restored plate-solver rows are written to the
// preference when the restored database is first opened, instead of being
// overwritten by the preference the machine had before.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../services/backup_restore_support.dart';

class _Solver extends Mock implements PlateSolveService {}

void main() {
  setUpAll(() => registerFallbackValue(const PlateSolverPreference()));

  late SkotiqDatabase db;
  late _Solver solver;
  late PlateSolverPreference preference;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    solver = _Solver();
    preference = const PlateSolverPreference(
      astapPath: '/opt/astap/astap',
      choice: PlateSolverChoice.astap,
    );
    when(() => solver.getConfig()).thenAnswer((_) async => preference);
    when(() => solver.setConfig(any())).thenAnswer((call) async {
      preference = call.positionalArguments.single as PlateSolverPreference;
    });
  });
  tearDown(() => db.close());

  /// Opens the settings and returns the solver the settings document names.
  Future<String> open() async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        plateSolveServiceProvider.overrideWithValue(solver),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final served = await container
        .read(appSettingsProvider.notifier)
        .exportHostSettings();
    return served.plateSolver;
  }

  Future<void> restoreRows() => SettingsDao(db).setSettings({
    'plate_solver': 'Astrometry.net',
    'astap_path': '/usr/local/bin/astap',
    'astrometry_path': '/usr/bin/solve-field',
    BackupService.restoredSolverRowsSettingKey:
        'plate_solver,astap_path,astrometry_path',
  });

  test('the first open of a restored database sets the solver from it, '
      'once', () async {
    await restoreRows();

    expect(await open(), 'Astrometry.net');
    expect(preference.choice, PlateSolverChoice.astrometry);
    expect(preference.astapPath, '/usr/local/bin/astap');
    expect(preference.astrometryPath, '/usr/bin/solve-field');
    expect(
      await SettingsDao(
        db,
      ).getSetting(BackupService.restoredSolverRowsSettingKey),
      isNull,
    );

    // From then on the preference is the source again.
    preference = preference.copyWith(choice: PlateSolverChoice.astap);
    expect(await open(), 'ASTAP');
  });

  test(
    "a backup carrying solver rows sets the preference through a replace",
    () async {
      final dir = await Directory.systemTemp.createTemp('sk_solver_restore_');
      addTearDown(() => dir.delete(recursive: true));
      // A backup an earlier build made: the solver rows as it stored them.
      final logger = testLogger(dir);
      final source = SkotiqDatabase.forTesting(
        NativeDatabase(File('${dir.path}/source.db')),
      );
      await SettingsDao(source).setSettings({
        'plate_solver': 'Astrometry.net',
        'astap_path': '/usr/local/bin/astap',
        'astrometry_path': '/usr/bin/solve-field',
      });
      final bundle = '${dir.path}/old.skbackup';
      final made = await BackupService(
        database: source,
        logger: logger,
      ).createBackup(customPath: bundle);
      expect(made.success, isTrue, reason: made.errorMessage);
      await source.close();
      await db.close();
      db = await replacedDatabase(dir, bundle, logger);

      expect(await open(), 'Astrometry.net');
      expect(preference.choice, PlateSolverChoice.astrometry);
      expect(preference.astapPath, '/usr/local/bin/astap');
      expect(preference.astrometryPath, '/usr/bin/solve-field');
    },
  );

  for (final fixture in ['backup_2_1', 'backup_3_0']) {
    test('a $fixture backup sets the preference through a replace', () async {
      final dir = await Directory.systemTemp.createTemp('sk_solver_legacy_');
      addTearDown(() => dir.delete(recursive: true));
      preference = const PlateSolverPreference(
        choice: PlateSolverChoice.astrometry,
        astapPath: '/opt/astap/astap',
        astrometryPath: '/usr/bin/solve-field',
      );
      await db.close();
      db = await replacedDatabase(
        dir,
        'test/fixtures/backups/$fixture.skbackup',
        testLogger(dir),
      );

      expect(await open(), 'Auto');
      expect(preference.choice, PlateSolverChoice.auto);
      expect(preference.astapPath, '');
      expect(preference.astrometryPath, '');
    });
  }

  test('a restore marks only the solver rows the backup carried', () async {
    await SettingsDao(db).setSettings({
      'plate_solver': 'Auto',
      'astap_path': '/usr/local/bin/astap',
      BackupService.restoredSolverRowsSettingKey: 'astap_path',
    });

    await open();

    expect(preference.choice, PlateSolverChoice.astap);
    expect(preference.astapPath, '/usr/local/bin/astap');
  });

  test('without a restore the preference wins over stale rows', () async {
    await SettingsDao(db).setSettings({'plate_solver': 'Astrometry.net'});

    expect(await open(), 'ASTAP');
    verifyNever(() => solver.setConfig(any()));
  });
}

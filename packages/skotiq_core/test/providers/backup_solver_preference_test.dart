// A backup's plate-solver settings come from this computer's native solver
// preference, the store the solver reads, even when the app settings were
// never loaded, and are a fresh install's when it cannot be read. A linked
// client's preference is its host's, so its backup carries the rows it
// stores.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _Solver extends Mock implements PlateSolveService {}

void main() {
  late SkotiqDatabase db;
  late Directory dir;
  late _Solver solver;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('sk_backup_solver_');
    solver = _Solver();
    when(() => solver.getConfig()).thenAnswer(
      (_) async => const PlateSolverPreference(
        choice: PlateSolverChoice.astrometry,
        astapPath: '/opt/astap/astap',
        astrometryPath: '/usr/bin/solve-field',
      ),
    );
    await SettingsDao(db).setSettings({
      'plate_solver': 'ASTAP',
      'astap_path': '/stale/astap',
      'astrometry_path': '',
    });
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> backupSettings({bool linked = false}) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        plateSolveServiceProvider.overrideWithValue(solver),
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '9.4.0', buildNumber: 1),
        ),
        if (linked) isRemoteModeProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);
    final file = File(p.join(dir.path, 'backup.skbackup'));
    final result = await container
        .read(backupServiceProvider)
        .createBackup(customPath: file.path);
    expect(result.success, isTrue, reason: result.errorMessage);
    final archive = jsonDecode(await file.readAsString()) as Map;
    return (archive['settings'] as Map).cast<String, dynamic>();
  }

  test('carries the preference without the settings having loaded', () async {
    final settings = await backupSettings();

    expect(settings['plate_solver'], 'Astrometry.net');
    expect(settings['astap_path'], '/opt/astap/astap');
    expect(settings['astrometry_path'], '/usr/bin/solve-field');
  });

  test("carries a fresh install's solver settings when the preference cannot "
      'be read', () async {
    when(() => solver.getConfig()).thenThrow(StateError('no bridge'));

    final settings = await backupSettings();

    expect(settings['plate_solver'], 'Auto');
    expect(settings['astap_path'], '');
    expect(settings['astrometry_path'], '');
  });

  test('on a linked client carries the stored rows', () async {
    final settings = await backupSettings(linked: true);

    expect(settings['plate_solver'], 'ASTAP');
    expect(settings['astap_path'], '/stale/astap');
    verifyNever(() => solver.getConfig());
  });
}

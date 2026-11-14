// Migration test for the v69 -> v70 step: a mosaic project keeps the panel
// numbering it was planned with. A v69 database is simulated by dropping the
// two columns and rewinding `PRAGMA user_version = 69`; reopening runs
// onUpgrade(69, 70).

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart'
    show MosaicStartCorner, mosaicPanelCenters;
import 'package:skotiq_core/src/database/daos/mosaic_projects_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  test('migration v69 -> v70 keeps every project, numbered as it was', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_v69_v70_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/skotiq.db');
    final setup = SkotiqDatabase.forTesting(NativeDatabase(file));
    await setup.customStatement(
      'INSERT INTO mosaic_projects (id, name, "rows", cols, overlap_pct, '
      'position_angle_deg, status, created_at, updated_at, hub_mosaic_id) '
      'VALUES (7, ?, 2, 3, 20.0, 12.5, ?, 1700000000, 1700000100, ?)',
      ['M31', 'capturing', 'hub-1'],
    );
    await setup.customStatement(
      'INSERT INTO mosaic_projects (id, name, "rows", cols, position_angle_deg, created_at, updated_at) '
      'VALUES (8, ?, 2, 3, 35, 1700000000, 1700000100)',
      ['New grid'],
    );
    for (final id in [7, 8]) {
      final panels = mosaicPanelCenters(
        centerRaHours: 0.01,
        centerDecDegrees: 41,
        stepRaDegrees: 0.8,
        stepDecDegrees: 0.6,
        columns: 3,
        rows: 2,
        rotationDegrees: id == 7 ? 12.5 : 35,
        startCorner: id == 7
            ? MosaicStartCorner.bottomRight
            : MosaicStartCorner.topLeft,
        serpentine: id == 8,
      );
      for (final panel in panels.where((p) => p.index != 1)) {
        await setup.customStatement(
          'INSERT INTO mosaic_panels (project_id, panel_index, center_ra, center_dec, captured_count) '
          'VALUES (?, ?, ?, ?, ?)',
          [id, panel.index, panel.raHours, panel.decDegrees, 12],
        );
      }
    }
    final oldPanels = await setup
        .customSelect('SELECT * FROM mosaic_panels ORDER BY id')
        .get();
    await setup.customStatement(
      'ALTER TABLE mosaic_projects DROP COLUMN start_corner',
    );
    await setup.customStatement(
      'ALTER TABLE mosaic_projects DROP COLUMN serpentine',
    );
    await setup.customStatement('PRAGMA user_version = 69');
    await setup.close();

    final db = SkotiqDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data['user_version'], db.schemaVersion);

    final project = await MosaicProjectsDao(db).getById(7);
    expect(project, isNotNull);
    expect(project!.name, 'M31');
    expect((project.rows, project.cols), (2, 3));
    expect(project.overlapPct, 20.0);
    expect(project.positionAngleDeg, 12.5);
    expect(project.hubMosaicId, 'hub-1');
    expect(project.startCorner, MosaicStartCorner.bottomRight);
    expect(project.serpentine, isFalse);
    final newer = await MosaicProjectsDao(db).getById(8);
    expect(newer!.startCorner, MosaicStartCorner.topLeft);
    expect(newer.serpentine, isTrue);
    final panels = await db
        .customSelect('SELECT * FROM mosaic_panels ORDER BY id')
        .get();
    expect(panels.map((p) => p.data), oldPanels.map((p) => p.data));
  });
}

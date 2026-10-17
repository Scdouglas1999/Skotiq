import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';

void main() {
  test('v57 adds durable rejection and coverage preview paths', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_v56_v57_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File('${dir.path}/skotiq.db');

    final setup = SkotiqDatabase.forTesting(NativeDatabase(file));
    final setupDao = IntegratedMastersDao(setup);
    late int masterId;
    try {
      masterId = await setupDao.insertMaster(
        name: 'Legacy master',
        masterFitsPath: '/data/master.fits',
        previewPngPath: '/data/master.png',
        rejectionMapPath: '/data/master_rejmap.fits',
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
      );

      final info = await setup
          .customSelect("PRAGMA table_info('integrated_masters')")
          .get();
      const added = <String>{
        'rejection_map_preview_path',
        'coverage_map_path',
        'coverage_map_preview_path',
      };
      final legacyColumns = info
          .map((row) => row.read<String>('name'))
          .where((name) => !added.contains(name))
          .toList(growable: false);
      final projection = legacyColumns.map((name) => '"$name"').join(', ');
      await setup.customStatement(
        'CREATE TABLE integrated_masters_v56 AS '
        'SELECT $projection FROM integrated_masters',
      );
      await setup.customStatement('DROP TABLE integrated_masters');
      await setup.customStatement(
        'ALTER TABLE integrated_masters_v56 RENAME TO integrated_masters',
      );
      await setup.customStatement('PRAGMA user_version = 56');
    } finally {
      await setup.close();
    }

    final upgraded = SkotiqDatabase.forTesting(NativeDatabase(file));
    final upgradedDao = IntegratedMastersDao(upgraded);
    try {
      final columns = await upgraded
          .customSelect("PRAGMA table_info('integrated_masters')")
          .get();
      final names = columns.map((row) => row.read<String>('name')).toSet();
      expect(
        names,
        containsAll(<String>{
          'rejection_map_preview_path',
          'coverage_map_path',
          'coverage_map_preview_path',
        }),
      );

      final legacy = await upgradedDao.getById(masterId);
      expect(legacy?.rejectionMapPath, '/data/master_rejmap.fits');
      expect(legacy?.rejectionMapPreviewPath, isNull);
      expect(legacy?.coverageMapPath, isNull);
      expect(legacy?.coverageMapPreviewPath, isNull);

      await upgradedDao.updateBookkeeping(
        masterId,
        rejectionMapPreviewPath: '/data/master_rejmap.png',
        coverageMapPath: '/data/master_cov.fits',
        coverageMapPreviewPath: '/data/master_cov.png',
      );
      final updated = await upgradedDao.getById(masterId);
      expect(updated?.rejectionMapPreviewPath, '/data/master_rejmap.png');
      expect(updated?.coverageMapPath, '/data/master_cov.fits');
      expect(updated?.coverageMapPreviewPath, '/data/master_cov.png');
    } finally {
      await upgraded.close();
    }
  });
}

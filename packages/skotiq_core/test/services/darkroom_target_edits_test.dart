import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/services/darkroom_target_edits.dart';
import 'package:skotiq_core/src/services/file_trash.dart';

class _NoopFileTrash implements FileTrash {
  @override
  bool get restorable => false;

  @override
  Future<List<String>> remove(List<String> paths) async => const [];
}

Future<DbCapturedImage> _frame(
  SkotiqDatabase db, {
  required String name,
  required double raHours,
  required double dec,
}) async {
  final id = await db.imagesDao.insertSequenceFrame(
    filePath: '/lights/$name.fits',
    fileName: '$name.fits',
    fileFormat: 'fits',
    exposureDuration: 60,
    capturedAt: DateTime.utc(2026, 11, 1),
    isAccepted: true,
    producingNodeId: 'n1',
    mountRa: raHours,
    mountDec: dec,
  );
  return (await db.imagesDao.getImageById(id))!;
}

void main() {
  test(
    'a target named from lights that straddle 0h uses the circular median RA',
    () async {
      // Hours 22, 23, 0, 1, 2 are symmetric about 0h, so their circular
      // median is 0h. Sorting them on a line and taking the middle element
      // yields 2h, which is 30 degrees away from that center.
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final edits = DarkroomTargetEdits(
        db,
        trash: () async => _NoopFileTrash(),
      );
      const hours = [22.0, 23.0, 0.0, 1.0, 2.0];
      const decs = [10.0, 20.0, 30.0, 40.0, 50.0];
      final frames = [
        for (var i = 0; i < hours.length; i++)
          await _frame(db, name: 'wrap_$i', raHours: hours[i], dec: decs[i]),
      ];

      final edit = await edits.rename(
        DarkroomTargetGroup(key: 'Unknown', frames: frames),
        'NGC 7822',
      );
      final target = await db.targetsDao.getTargetById(edit.createdRow!);

      expect(target!.ra, closeTo(0, 1e-9));
      expect(target.dec, closeTo(30, 1e-9));
    },
  );

  test(
    'moving more lights than SQLite can bind in one statement still files every light',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final limit = await _variableLimit(db);
      // The update binds the new target id plus one variable per light.
      final count = limit;
      await db.customStatement(
        'INSERT INTO captured_images ('
        'file_path, file_name, exposure_duration, captured_at, mount_ra, mount_dec'
        ') WITH RECURSIVE seq(n) AS ('
        'SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < ?'
        ') SELECT \'/lights/\' || n || \'.fits\', n || \'.fits\', 60, '
        '1700000000, 1.0, 40.0 FROM seq',
        [count],
      );
      final frames = await db.select(db.capturedImages).get();
      expect(frames, hasLength(count));

      final edits = DarkroomTargetEdits(
        db,
        trash: () async => _NoopFileTrash(),
      );
      final edit = await edits.rename(
        DarkroomTargetGroup(key: 'Unknown', frames: frames),
        'NGC 7822',
      );
      final stamped = await db
          .customSelect(
            'SELECT COUNT(*) AS n FROM captured_images WHERE target_id = ?',
            variables: [Variable<int>(edit.createdRow!)],
          )
          .getSingle();

      expect(edit.frameTargets, hasLength(count));
      expect(stamped.read<int>('n'), count);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a rename that fails while moving lights leaves no target or placement',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement(
        'CREATE TRIGGER abort_light_move BEFORE UPDATE OF target_id '
        'ON captured_images BEGIN SELECT RAISE(ABORT, \'move refused\'); END',
      );
      final frame = await _frame(db, name: 'sub', raHours: 1, dec: 2);
      final edits = DarkroomTargetEdits(
        db,
        trash: () async => _NoopFileTrash(),
      );

      await expectLater(
        edits.rename(
          DarkroomTargetGroup(key: 'Unknown', frames: [frame]),
          'Veil',
        ),
        throwsA(anything),
      );

      expect(await db.targetsDao.getAllTargets(), isEmpty);
      expect(
        (await db.settingsDao.readTargetPlacements()).of('Veil'),
        TargetPlacement.auto,
      );
      expect((await db.imagesDao.getImageById(frame.id))!.targetId, isNull);
    },
  );

  test(
    'a merge that fails while moving lights does not keep the target it created',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement(
        'CREATE TRIGGER abort_light_move BEFORE UPDATE OF target_id '
        'ON captured_images BEGIN SELECT RAISE(ABORT, \'move refused\'); END',
      );
      final from = await _frame(db, name: 'from', raHours: 1, dec: 2);
      final into = await _frame(db, name: 'into', raHours: 1.1, dec: 2.1);
      final edits = DarkroomTargetEdits(
        db,
        trash: () async => _NoopFileTrash(),
      );

      await expectLater(
        edits.merge(
          DarkroomTargetGroup(key: 'Sh2-101', frames: [from]),
          DarkroomTargetGroup(key: 'Veil', frames: [into]),
        ),
        throwsA(anything),
      );

      expect(await db.targetsDao.getAllTargets(), isEmpty);
      expect((await db.imagesDao.getImageById(from.id))!.targetId, isNull);
      expect((await db.imagesDao.getImageById(into.id))!.targetId, isNull);
    },
  );
}

Future<int> _variableLimit(SkotiqDatabase db) async {
  final rows = await db.customSelect('PRAGMA compile_options').get();
  for (final row in rows) {
    final option = row.data.values.first.toString();
    const prefix = 'MAX_VARIABLE_NUMBER=';
    if (option.startsWith(prefix)) {
      return int.parse(option.substring(prefix.length));
    }
  }
  throw StateError('SQLite did not report MAX_VARIABLE_NUMBER');
}

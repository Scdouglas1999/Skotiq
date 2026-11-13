import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';

DbCapturedImage _row(String frameType) => DbCapturedImage(
  id: 1,
  filePath: '/f.fits',
  fileName: 'f.fits',
  fileFormat: 'fits',
  frameType: frameType,
  exposureDuration: 60,
  binX: 1,
  binY: 1,
  isPlateSolved: false,
  capturedAt: DateTime.utc(2026, 11, 13),
  createdAt: DateTime.utc(2026, 11, 13),
  isAccepted: true,
);

void main() {
  test('every frame type reads back from the record it writes', () {
    for (final type in FrameType.values) {
      expect(FrameType.fromRecord(type.record), type);
      expect(FrameType.fromRecord(type.imageType), type);
      expect(FrameType.fromRecord(type.displayName), type);
    }
  });

  test('rows written in older spellings read as their frame type', () {
    expect(_row('Light').isLight, isTrue);
    expect(_row(' light ').isLight, isTrue);
    expect(_row('darkFlat').recordedFrameType, FrameType.darkFlat);
    expect(_row('dark_flat').recordedFrameType, FrameType.darkFlat);
    expect(_row('Snapshot').isLight, isFalse);
    expect(_row('lights').recordedFrameType, isNull);
  });

  test('the query filter finds light rows in any letter case', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (i, type) in ['light', 'Light', 'dark', 'LIGHT'].indexed) {
      await db.imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/f$i.fits',
          fileName: 'f$i.fits',
          frameType: Value(type),
          exposureDuration: 60,
          capturedAt: DateTime.utc(2026, 11, 13, 1, i),
        ),
      );
    }
    final lights = await (db.select(
      db.capturedImages,
    )..where((t) => t.frameTypeIs(FrameType.light))).get();
    expect(lights.map((r) => r.fileName), ['f0.fits', 'f1.fits', 'f3.fits']);
  });
}

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('every frame type reads back from the names it writes', () {
    for (final type in FrameType.values) {
      expect(FrameType.fromRecord(type.record), type);
      expect(FrameType.fromImageType(type.imageType), type);
    }
    expect(FrameType.fromRecord('Light'), isNull);
    expect(FrameType.fromImageType('light'), isNull);
  });

  test('the query filter finds the light rows', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (i, type) in [FrameType.light, FrameType.dark, FrameType.light].indexed) {
      await db.imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/f$i.fits',
          fileName: 'f$i.fits',
          frameType: Value(type.record),
          exposureDuration: 60,
          capturedAt: DateTime.utc(2026, 11, 13, 1, i),
        ),
      );
    }
    final lights = await (db.select(
      db.capturedImages,
    )..where((t) => t.frameTypeIs(FrameType.light))).get();
    expect(lights.map((r) => r.fileName), ['f0.fits', 'f2.fits']);
    expect(lights.every((r) => r.isLight), isTrue);
  });
}

// qa-surfaces S31: frames shot without a target were listed under the target
// name "Session unassigned", which read as an error state.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('frames with no target and no session are named plainly', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db
        .into(db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: '/nowhere/l_1.fits',
            fileName: 'l_1.fits',
            exposureDuration: 10,
            filter: const Value('L'),
            capturedAt: DateTime(2026, 11, 2, 22),
          ),
        );

    final targets = await loadDarkroomTargets(
      db,
      readHeader: (_) async => const {},
    );
    expect(targets.keys, ['Frames with no target']);
  });
}

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('turns true when the first frame is stored', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final seen = <bool>[];
    final stored = Completer<void>();
    container.listen<AsyncValue<bool>>(hasCapturedImagesProvider, (_, next) {
      final value = next.valueOrNull;
      if (value == null) return;
      seen.add(value);
      if (value) stored.complete();
    }, fireImmediately: true);
    await pumpEventQueue();

    await db.imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/frames/first.fits',
        fileName: 'first.fits',
        exposureDuration: 30,
        capturedAt: DateTime(2026, 11, 12, 22),
      ),
    );
    await stored.future.timeout(const Duration(seconds: 5));

    expect(seen, [false, true]);
  });
}

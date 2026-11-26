// The demo rig's scratch frames are deleted when it stops, so the frame list
// must not keep rows that point at them. Frames kept elsewhere stay.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/demo_backend/demo_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';

void main() {
  late SkotiqDatabase database;
  late Directory root;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    root = Directory.systemTemp.createTempSync('demo_forget');
  });

  tearDown(() async {
    await database.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> frameAt(String path) => database
      .into(database.capturedImages)
      .insert(
        CapturedImagesCompanion.insert(
          filePath: path,
          fileName: path.split(Platform.pathSeparator).last,
          exposureDuration: 2,
          capturedAt: DateTime(2026, 11, 26, 21),
        ),
      );

  Future<List<String>> paths() async => [
    for (final row in await database.select(database.capturedImages).get())
      row.filePath,
  ];

  test(
    'deleteImagesUnder removes the folder\'s frames and no others',
    () async {
      final sep = Platform.pathSeparator;
      await frameAt('${root.path}${sep}demo${sep}a.fits');
      await frameAt('${root.path}${sep}demo${sep}b.fits');
      await frameAt('${root.path}${sep}demo2${sep}c.fits');
      await frameAt('${root.path}${sep}captures${sep}d.fits');

      final removed = await database.imagesDao.deleteImagesUnder(
        '${root.path}${sep}demo',
      );

      expect(removed, 2);
      expect(await paths(), [
        '${root.path}${sep}demo2${sep}c.fits',
        '${root.path}${sep}captures${sep}d.fits',
      ]);
    },
  );

  test('turning the demo rig off forgets its scratch frames', () async {
    final scratch = Directory('${root.path}${Platform.pathSeparator}scratch');
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        backendProvider.overrideWith(
          (ref) =>
              BackendNotifier(ref, demoScratchDirectory: () async => scratch),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(backendProvider.notifier);
    Future<void> want(bool on) =>
        notifier.setDemoRigWanted(on, latitudeDeg: 40, longitudeDeg: -105);

    await want(true);
    expect(notifier.currentBackend, isA<DemoBackend>());
    final kept =
        '${root.path}${Platform.pathSeparator}captures'
        '${Platform.pathSeparator}kept.fits';
    await frameAt('${scratch.path}${Platform.pathSeparator}snapshot.fits');
    await frameAt(kept);

    await want(false);
    // The rows go after the swap, without holding it up.
    for (var i = 0; i < 50 && (await paths()).length > 1; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await paths(), [kept]);
  });
}

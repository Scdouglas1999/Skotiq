import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/flat_library_service.dart';

import 'post_session_integration_service_test.dart' show FakePostSessionSeam;

void main() {
  late SkotiqDatabase db;
  late FlatLibraryDao dao;
  late FakePostSessionSeam seam;
  late FlatLibraryService service;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = FlatLibraryDao(db);
    seam = FakePostSessionSeam();
    service = FlatLibraryService(dao: dao, seam: seam);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'createMasterFlat invokes the native build and registers a row',
    () async {
      final id = await service.createMasterFlat(
        flatPaths: ['/flats/a.fits', '/flats/b.fits', '/flats/c.fits'],
        outputPath: '/cal/master_flat_L.fits',
        biasOrDarkFlatPath: '/cal/master_bias.fits',
        filter: 'L',
        gain: 100,
        binX: 1,
        binY: 1,
        temperature: -10.0,
      );

      // Native build received the right args.
      expect(seam.flatCalls, hasLength(1));
      final call = seam.flatCalls.single;
      expect((call['flatPaths'] as List), hasLength(3));
      expect(call['biasOrDarkFlat'], '/cal/master_bias.fits');
      expect(call['method'], 'sigmaClip');
      expect(call['outputBitDepth'], 'f32');

      // Row registered with the master flat metadata.
      final entry = await dao.getEntryById(id);
      expect(entry, isNotNull);
      expect(entry!.filePath, '/cal/master_flat_L.fits');
      expect(entry.filter, 'L');
      expect(entry.masterFrameCount, 3);
    },
  );

  test('empty flat list is a hard error', () async {
    expect(
      () => service.createMasterFlat(
        flatPaths: const [],
        outputPath: '/cal/x.fits',
      ),
      throwsArgumentError,
    );
  });

  test('findBestMatch honors filter + binning + temperature tolerance', () async {
    await dao.addEntry(
      filePath: '/cal/flat_L_cold.fits',
      filter: 'L',
      gain: 100,
      binX: 1,
      binY: 1,
      temperature: -10.0,
    );
    await dao.addEntry(
      filePath: '/cal/flat_L_warm.fits',
      filter: 'L',
      gain: 100,
      binX: 1,
      binY: 1,
      temperature: -5.0,
    );
    await dao.addEntry(
      filePath: '/cal/flat_R.fits',
      filter: 'R',
      gain: 100,
      binX: 1,
      binY: 1,
      temperature: -10.0,
    );

    // Closest temperature wins among the matching-filter pool.
    final match = await service.findBestMatch(
      filter: 'L',
      gain: 100,
      binX: 1,
      binY: 1,
      temperature: -9.5,
    );
    expect(match, isNotNull);
    expect(match!.filePath, '/cal/flat_L_cold.fits');

    // A filter with no registered flat returns null (never a wrong-filter flat).
    final none = await service.findBestMatch(
      filter: 'SII',
      gain: 100,
      binX: 1,
      binY: 1,
    );
    expect(none, isNull);

    // Binning mismatch excludes the L flats.
    final binMismatch = await service.findBestMatch(
      filter: 'L',
      gain: 100,
      binX: 2,
      binY: 2,
    );
    expect(binMismatch, isNull);
  });

  test('addEntry dedups by file path (rebuild overwrites)', () async {
    final first = await dao.addEntry(
      filePath: '/cal/flat.fits',
      filter: 'L',
      masterFrameCount: 10,
    );
    final second = await dao.addEntry(
      filePath: '/cal/flat.fits',
      filter: 'L',
      masterFrameCount: 20,
    );
    expect(first, second);
    final all = await dao.getAllEntries();
    expect(all, hasLength(1));
    expect(all.single.masterFrameCount, 20);
  });
}

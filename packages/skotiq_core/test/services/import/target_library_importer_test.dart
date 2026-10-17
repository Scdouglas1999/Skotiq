import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/import/target_library_importer.dart';

void main() {
  late SkotiqDatabase database;
  late TargetLibraryImporter importer;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    importer = TargetLibraryImporter(database);
  });

  tearDown(() => database.close());

  test('CSV supports quoted commas and imports every validated row', () async {
    const csv =
        'name,ra,dec,catalogId,objectType\r\n'
        '"Andromeda, Galaxy",0.7122,41.269,M31,Galaxy\r\n'
        'R Andromedae,0.405,38.58,,Star';

    expect(await importer.importCsv(csv), 2);
    final targets = await database.targetsDao.getAllTargets();
    expect(targets.map((target) => target.name), [
      'Andromeda, Galaxy',
      'R Andromedae',
    ]);
    expect(targets.first.catalogId, 'M31');
    expect(targets.last.catalogId, isNull);
  });

  test('a target name containing "ra" is not mistaken for a header', () async {
    expect(await importer.importCsv('R Andromedae,0.405,38.58'), 1);
    expect(
      (await database.targetsDao.getAllTargets()).single.name,
      'R Andromedae',
    );
  });

  test('bad CSV row aborts the whole import with its row number', () async {
    const csv = 'name,ra,dec\nM31,0.7122,41.269\nBroken,25,-5';

    await expectLater(
      importer.importCsv(csv),
      throwsA(
        isA<TargetLibraryImportException>().having(
          (error) => error.message,
          'message',
          contains('row 3'),
        ),
      ),
    );
    expect(await database.targetsDao.getAllTargets(), isEmpty);
  });

  test(
    'malformed JSON and malformed entries fail instead of importing zero',
    () async {
      await expectLater(
        importer.importJson('{broken'),
        throwsA(isA<TargetLibraryImportException>()),
      );
      await expectLater(
        importer.importJson(
          jsonEncode({
            'targets': [false],
          }),
        ),
        throwsA(isA<TargetLibraryImportException>()),
      );
    },
  );

  test('JSON validation is all-or-nothing', () async {
    final json = jsonEncode({
      'targets': [
        {'name': 'M31', 'ra': 0.7122, 'dec': 41.269},
        {'name': 'Invalid', 'ra': 1.0, 'dec': -91},
      ],
    });

    await expectLater(
      importer.importJson(json),
      throwsA(isA<TargetLibraryImportException>()),
    );
    expect(await database.targetsDao.getAllTargets(), isEmpty);
  });
}

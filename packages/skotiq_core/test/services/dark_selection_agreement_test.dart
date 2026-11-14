import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// Live calibration ([DarkLibraryService.findMatchingDark]) and the Darkroom
/// ([CalibrationLibraryService.match]) answer "which dark" from one rule.
void main() {
  late SkotiqDatabase db;
  late DarkLibraryDao darkDao;
  late DarkLibraryService live;
  late CalibrationLibraryService darkroom;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    darkDao = DarkLibraryDao(db);
    live = DarkLibraryService(darkDao);
    darkroom = CalibrationLibraryService(
      db: db,
      flatLibraryDao: FlatLibraryDao(db),
      tagsDao: CalibrationTagsDao(db),
    );
  });

  tearDown(() => db.close());

  Future<void> insertMaster({
    required String name,
    double exposure = 300,
    int? gain = 100,
    double? temperature,
  }) => darkDao.addEntry(
    DarkLibraryCompanion.insert(
      filePath: '/raw/$name.fits',
      exposureTime: exposure,
      gain: Value(gain),
      offset: const Value(50),
      temperature: Value(temperature),
      masterDarkPath: Value('/master/$name.fits'),
      masterFrameCount: const Value(20),
    ),
  );

  Future<String?> darkroomPick(LightFrameContext context) async =>
      (await darkroom.match(
        context,
        includeRemote: false,
      )).dark?.record.filePath;

  test(
    'a dark outside the temperature tolerance is the pick of both',
    () async {
      await insertMaster(name: 'warm', temperature: -6.5);

      final livePick = await live.findMatchingDark(
        exposureTime: 300,
        gain: 100,
        offset: 50,
        temperature: -10,
      );
      final darkroomPath = await darkroomPick(
        const LightFrameContext(
          gain: 100,
          offset: 50,
          exposureSeconds: 300,
          temperature: -10,
        ),
      );

      expect(darkroomPath, '/master/warm.fits');
      expect(livePick?.calibrationPath, darkroomPath);
    },
  );

  test('lights that record no gain draw the same dark from both', () async {
    await insertMaster(name: 'gain100');

    final livePick = await live.findMatchingDark(
      exposureTime: 300,
      gain: null,
      offset: 50,
    );
    final darkroomPath = await darkroomPick(
      const LightFrameContext(gain: null, offset: 50, exposureSeconds: 300),
    );

    expect(darkroomPath, '/master/gain100.fits');
    expect(livePick?.calibrationPath, darkroomPath);
  });

  test('the nearest temperature within tolerance wins in both', () async {
    await insertMaster(name: 'm9', temperature: -9.2);
    await insertMaster(name: 'm10', temperature: -10.1);
    await insertMaster(name: 'm20', temperature: -20);

    final livePick = await live.findMatchingDark(
      exposureTime: 300,
      gain: 100,
      offset: 50,
      temperature: -10,
    );
    final darkroomPath = await darkroomPick(
      const LightFrameContext(
        gain: 100,
        offset: 50,
        exposureSeconds: 300,
        temperature: -10,
      ),
    );

    expect(darkroomPath, '/master/m10.fits');
    expect(livePick?.calibrationPath, darkroomPath);
  });

  test('the Darkroom matches on the operator\'s tolerances, as live '
      'calibration does', () async {
    await insertMaster(name: 'm8', temperature: -8.5);
    const operator = DarkLibraryMatchTolerances(temperatureC: 2.0);
    final withSettings = CalibrationLibraryService(
      db: db,
      flatLibraryDao: FlatLibraryDao(db),
      tagsDao: CalibrationTagsDao(db),
      darkTolerances: () => operator,
    );
    const context = LightFrameContext(
      gain: 100,
      offset: 50,
      exposureSeconds: 300,
      temperature: -10,
    );

    final match = await withSettings.match(context, includeRemote: false);

    // 1.5 °C off is inside the operator's 2 °C, so nothing to warn about.
    expect(
      match.dark!.warnings.where((w) => w.contains('temperature')),
      isEmpty,
    );
    expect(match.dark!.reasons, contains(contains('tolerance ±2.0°C')));
  });
}

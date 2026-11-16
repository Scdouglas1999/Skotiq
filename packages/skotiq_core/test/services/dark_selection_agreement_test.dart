import 'dart:io';

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

  group('a master built from frames off its set-point', () {
    late Directory dir;
    final headers = <String, FrameHeader>{};
    const operator = DarkLibraryMatchTolerances(temperatureC: 2.0);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('off-set-point');
      headers.clear();
      live = DarkLibraryService(
        darkDao,
        readHeader: (path) async => headers[path]!,
      );
      darkroom = CalibrationLibraryService(
        db: db,
        flatLibraryDao: FlatLibraryDao(db),
        tagsDao: CalibrationTagsDao(db),
        readHeader: (path) async => headers[path]!,
        darkTolerances: () => operator,
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<String> master(String name, Map<String, Object> header) async {
      final path = '${dir.path}/$name.fits';
      File(path).writeAsStringSync('');
      headers[path] = FrameHeader(header);
      await darkDao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: path,
          exposureTime: 3,
          gain: const Value(139),
          offset: const Value(21),
          temperature: Value(header['CCD-TEMP']! as double),
          masterDarkPath: Value(path),
          masterFrameCount: const Value(6),
        ),
      );
      return path;
    }

    // The rig's MasterDark_3s_g139_o21_m8C of 2026-11-15: darks read -9.7 to
    // -5.5 °C while the cooler held 1 °C, built before set-points grouped.
    Future<String> stale() => master('MasterDark_3s_g139_o21_m8C', {
      'SET-TEMP': 1.0,
      'CCD-TEMP': -7.6,
    });

    for (final lights in [1.0, -8.0]) {
      test('is picked by neither for lights at $lights °C', () async {
        await stale();
        final context = LightFrameContext(
          gain: 139,
          offset: 21,
          exposureSeconds: 3,
          temperature: lights,
        );

        final livePick = await live.findMatchingDark(
          exposureTime: 3,
          gain: 139,
          offset: 21,
          temperature: lights,
          tolerances: operator,
        );
        final darkroomPick = await darkroom.match(
          context,
          includeRemote: false,
        );

        expect(livePick, isNull);
        expect(darkroomPick.dark, isNull);
      });
    }

    test('stays in the library, flagged with why', () async {
      final path = await stale();

      final listed = await darkroom.listMasters();

      expect(listed.single.filePath, path);
      expect(File(path).existsSync(), isTrue);
      expect(
        listed.single.offSetPoint,
        'Built from frames that read -7.6 °C on average at a 1 °C set-point, '
        'more than 2 °C from it',
      );
    });

    test(
      'is judged by its coldest and warmest frames when it states them',
      () async {
        await master('spread', {
          'SET-TEMP': -4.0,
          'CCD-TEMP': -4.2,
          'CCDTMIN': -6.5,
          'CCDTMAX': -3.0,
        });
        final atSetPoint = await master('at', {
          'SET-TEMP': -4.0,
          'CCD-TEMP': -4.6,
          'CCDTMIN': -6.0,
          'CCDTMAX': -3.5,
        });

        final listed = await darkroom.listMasters();
        final pick = await live.findMatchingDark(
          exposureTime: 3,
          gain: 139,
          offset: 21,
          temperature: -4.2,
          tolerances: operator,
        );

        expect(
          {for (final r in listed) r.filePath!.split('/').last: r.offSetPoint},
          {
            'spread.fits':
                'Built from frames that read -6.5 °C to -3 °C at a -4 °C '
                'set-point, more than 2 °C from it',
            'at.fits': null,
          },
        );
        expect(pick?.calibrationPath, atSetPoint);
      },
    );
  });
}

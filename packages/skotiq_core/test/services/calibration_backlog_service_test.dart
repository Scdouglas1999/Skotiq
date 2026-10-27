import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/calibration_backlog_service.dart';
import 'package:skotiq_core/src/services/calibration_library_service.dart';
import 'package:skotiq_core/src/services/calibration_master_builder.dart';
import 'package:skotiq_core/src/services/dark_library_service.dart';
import 'package:skotiq_core/src/services/flat_library_service.dart';

import 'post_session_integration_service_test.dart' show FakePostSessionSeam;

/// A FITS primary header holding [cards], padded to one 2880-byte block.
List<int> fitsHeader(Map<String, Object> cards) {
  String card(String key, Object value) {
    final v = value is String ? "'$value'" : '$value';
    return '${key.padRight(8)}= ${v.padLeft(20)}'.padRight(80);
  }

  final text = StringBuffer()
    ..write(card('SIMPLE', 'T').replaceFirst("'T'", '  T'))
    ..write(card('BITPIX', 16))
    ..write(card('NAXIS', 0));
  cards.forEach((k, v) => text.write(card(k, v)));
  text.write('END'.padRight(80));
  final s = text.toString();
  return s.padRight(((s.length + 2879) ~/ 2880) * 2880).codeUnits;
}

void main() {
  late Directory tmp;
  late SkotiqDatabase db;
  late DarkLibraryDao darkDao;
  late FlatLibraryDao flatDao;
  late FakePostSessionSeam seam;
  late List<CalibrationMasterBuildRequest> masterCalls;
  late CalibrationBacklogService service;
  final missing = <String>{};

  CalibrationBacklogService makeService() => CalibrationBacklogService(
    db: db,
    library: CalibrationLibraryService(
      db: db,
      flatLibraryDao: flatDao,
      tagsDao: CalibrationTagsDao(db),
    ),
    darkLibrary: DarkLibraryService(darkDao),
    flatLibrary: FlatLibraryService(dao: flatDao, seam: seam),
    buildMaster: (request) async {
      masterCalls.add(request);
      return CalibrationMasterBuildResult(
        outputPath: request.outputPath,
        kind: request.kind,
        width: 4656,
        height: 3520,
        frameCount: request.framePaths.length - 1,
        leakingFrames: [request.framePaths.last],
        frameLevels: const [],
        leakBaseline: 0,
        leakThreshold: 0,
        masterMean: 500,
        rejectionFraction: 0.01,
        exposureSecs: request.kind == 'bias' ? 0.001 : 90,
        gain: 76,
        offset: 15,
        binX: 1,
        binY: 1,
        ccdTempMean: -10,
      );
    },
    settings: SettingsDao(db),
    fileExists: (path) async => !missing.contains(path),
    now: () => DateTime(2026, 10, 25, 9),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('backlog_test');
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    darkDao = DarkLibraryDao(db);
    flatDao = FlatLibraryDao(db);
    seam = FakePostSessionSeam();
    masterCalls = [];
    missing.clear();
    service = makeService();
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> addFrames(
    String type,
    int count, {
    required DateTime start,
    double exposure = 90,
    String? filter,
    double? temp = -10,
    int gain = 76,
    int offset = 15,
    String dir = 'Dark',
  }) async {
    for (var i = 0; i < count; i++) {
      final path = '${tmp.path}/$dir/${type}_${exposure}_${filter}_$i.fits';
      await db
          .into(db.capturedImages)
          .insert(
            CapturedImagesCompanion.insert(
              filePath: path,
              fileName: path.split('/').last,
              frameType: Value(type),
              exposureDuration: exposure,
              capturedAt: start.add(Duration(seconds: 100 * i)),
              gain: Value(gain),
              offset: Value(offset),
              filter: Value(filter),
              sensorTemp: Value(temp),
            ),
          );
    }
  }

  Future<void> addMaster({
    required String frameType,
    required double exposure,
    required DateTime createdAt,
    double temp = -10,
  }) => darkDao.addEntry(
    DarkLibraryCompanion.insert(
      filePath: '/masters/$frameType$exposure.fits',
      exposureTime: exposure,
      frameType: Value(frameType),
      temperature: Value(temp),
      gain: const Value(76),
      offset: const Value(15),
      masterDarkPath: Value('/masters/$frameType$exposure.fits'),
      masterFrameCount: const Value(20),
      createdAt: Value(createdAt),
    ),
  );

  final night = DateTime(2026, 10, 22, 2);

  test(
    'night-end uses only approved exact batches for matching lights',
    () async {
      await addFrames(
        'flat',
        3,
        start: night,
        filter: 'Ha',
        gain: 139,
        offset: 21,
      );
      await addFrames('flat', 3, start: night, filter: 'R');
      await addFrames(
        'light',
        2,
        start: night,
        filter: 'Ha',
        gain: 139,
        offset: 21,
      );
      final lights = (await db.imagesDao.getAllImages())
          .where((f) => f.frameType == 'light')
          .toList();
      expect(await service.scheduledForLights(lights), isEmpty);
      final ha = (await service.pending()).singleWhere((g) => g.filter == 'Ha');
      await service.scheduleFlat(ha, true);
      service = makeService();
      expect((await service.scheduledForLights(lights)).single.key, ha.key);
      await service.scheduleFlat(ha, false);
      expect(await service.scheduledForLights(lights), isEmpty);
      await service.scheduleFlat(ha, true);
      await service.dismiss(ha.key);
      expect(await service.scheduledForLights(lights), isEmpty);
    },
  );

  test(
    'new frames need renewed approval and competing batches need a choice',
    () async {
      await addFrames('flat', 3, start: night, filter: 'Ha');
      await addFrames('light', 2, start: night, filter: 'Ha');
      final lights = (await db.imagesDao.getAllImages())
          .where((f) => f.frameType == 'light')
          .toList();
      await service.scheduleFlat((await service.pending()).single, true);
      await addFrames('flat', 2, start: night, filter: 'Ha', dir: 'More');
      await expectLater(
        service.scheduledForLights(lights),
        throwsA(isA<CalibrationBacklogException>()),
      );
      await service.scheduleFlat((await service.pending()).single, true);
      await addFrames(
        'flat',
        3,
        start: night.add(const Duration(days: 1)),
        filter: 'Ha',
        dir: 'Other',
      );
      await service.scheduleFlat((await service.pending()).first, true);
      await expectLater(
        service.scheduledForLights(lights),
        throwsA(isA<CalibrationBacklogException>()),
      );
    },
  );

  test(
    'concurrent selections persist and unrelated masters do not cover approval',
    () async {
      await addFrames('flat', 3, start: night, filter: 'Ha');
      await addFrames('flat', 3, start: night, filter: 'L');
      await addFrames('light', 2, start: night, filter: 'Ha');
      final groups = await service.pending();
      await Future.wait(groups.map((g) => service.scheduleFlat(g, true)));
      expect(await service.scheduledFlats(), hasLength(2));
      await Future.wait([
        service.scheduleFlat(groups.first, false),
        service.scheduleFlat(groups.last, true),
      ]);
      expect((await service.scheduledFlats()).keys, [groups.last.key]);
      final ha = groups.singleWhere((g) => g.filter == 'Ha');
      await service.scheduleFlat(ha, true);
      await flatDao.addEntry(
        filePath: '/unrelated.fits',
        filter: 'Ha',
        gain: 76,
        offset: 15,
        createdAt: night.add(const Duration(days: 1)),
      );
      final lights = (await db.imagesDao.getAllImages())
          .where((f) => f.frameType == 'light')
          .toList();
      expect((await service.scheduledForLights(lights)).single.key, ha.key);
      expect(await service.scheduledMaster(ha), isNull);
    },
  );

  test('groups raw frames by kind, night, exposure and temperature', () async {
    await addFrames('dark', 20, start: night);
    await addFrames('dark', 20, start: night, exposure: 120);
    await addFrames('bias', 50, start: night, exposure: 0.001);
    // Same exposure, the cooler off: a separate master.
    await addFrames('dark', 3, start: night, temp: 20, dir: 'Warm');
    await addFrames('dark', 5, start: night.add(const Duration(days: 2)));

    final groups = await service.pending();

    expect(
      groups.map((g) => '${g.title}|${g.night}|${g.frames.length}').toSet(),
      {
        'Dark 90 s|2026-10-21|20',
        'Dark 120 s|2026-10-21|20',
        'Bias|2026-10-21|50',
        'Dark 90 s|2026-10-21|3',
        'Dark 90 s|2026-10-23|5',
      },
    );
    final warm = groups.firstWhere((g) => g.frames.length == 3);
    expect(warm.temperature, 20);
    expect(warm.settings, 'gain 76 · offset 15 · bin 1x1 · 20 °C');
    // Newest night first.
    expect(groups.first.night, '2026-10-23');
  });

  test(
    'a master built after the frames covers them; an older one does not',
    () async {
      await addFrames('dark', 20, start: night);
      await addFrames('bias', 50, start: night, exposure: 0.001);
      await addMaster(
        frameType: 'dark',
        exposure: 90,
        createdAt: night.add(const Duration(days: 2)),
        temp: -9.9,
      );
      await addMaster(
        frameType: 'bias',
        exposure: 0.001,
        createdAt: night.subtract(const Duration(days: 30)),
      );

      final groups = await service.pending();

      expect(groups.map((g) => g.title), ['Bias']);
    },
  );

  test('frames not on this computer are listed but cannot be built', () async {
    await addFrames('dark', 3, start: night);
    missing.add('${tmp.path}/Dark/dark_90.0_null_1.fits');

    final group = (await service.pending()).single;

    expect(group.missingFiles, 1);
    expect(group.buildable, isFalse);
    expect(
      () => service.build(group),
      throwsA(isA<CalibrationBacklogException>()),
    );
  });

  test('a dismissed group stays hidden', () async {
    await addFrames('dark', 3, start: night);
    final group = (await service.pending()).single;

    await service.dismiss(group.key);

    expect(await service.pending(), isEmpty);
  });

  test('building darks registers a master the matcher finds', () async {
    await addFrames('dark', 20, start: night);
    final group = (await service.pending()).single;

    final built = await service.build(group);

    expect(masterCalls.single.kind, 'dark');
    expect(masterCalls.single.framePaths, hasLength(20));
    expect(
      masterCalls.single.outputPath,
      '${tmp.path}/Dark/Masters/'
      'MasterDark_90s_g76_o15_m10C_bin1_20261025-090000.fits',
    );
    expect(built.framesCombined, 19);
    expect(built.leftOut, hasLength(1));
    final row = await darkDao.getEntryById(built.libraryId);
    expect(row!.masterDarkPath, masterCalls.single.outputPath);
    expect(row.gain, 76);
    expect(await service.pending(), isEmpty);
  });

  test(
    'flats are bias-subtracted and filed under their filter and gain',
    () async {
      await addMaster(
        frameType: 'bias',
        exposure: 0.001,
        createdAt: night.subtract(const Duration(days: 1)),
      );
      await addFrames(
        'flat',
        15,
        start: night,
        exposure: 1.5,
        filter: 'Ha',
        dir: 'Flats',
      );
      final group = (await service.pending()).single;
      expect(group.title, 'Flat Ha');

      final built = await service.build(group);

      expect(
        seam.flatCalls.single['biasOrDarkFlat'],
        '/masters/bias0.001.fits',
      );
      expect(built.pedestalPath, '/masters/bias0.001.fits');
      final entry = await flatDao.getEntryById(built.libraryId);
      expect(entry!.filter, 'Ha');
      expect(entry.gain, 76);
      expect(entry.offset, 15);
      expect(entry.masterFrameCount, 15);
      expect(await service.pending(), isEmpty);
    },
  );

  test(
    'narrowband flats use their recorded gain, not the usual light preset',
    () async {
      await addMaster(frameType: 'bias', exposure: .001, createdAt: night);
      for (final filter in ['SII', 'OIII', 'Ha']) {
        await addFrames(
          'flat',
          20,
          start: night,
          exposure: .3,
          filter: filter,
          gain: filter == 'Ha' ? 139 : 76,
          offset: filter == 'Ha' ? 21 : 15,
        );
      }
      final groups = await service.pending();
      for (final filter in ['SII', 'OIII']) {
        final built = await service.build(
          groups.singleWhere((g) => g.filter == filter),
        );
        final entry = await flatDao.getEntryById(built.libraryId);
        expect(entry!.gain, 76);
        expect(entry.offset, 15);
      }
      await expectLater(
        service.build(groups.singleWhere((g) => g.filter == 'Ha')),
        throwsA(
          isA<CalibrationBacklogException>().having(
            (e) => e.message,
            'actionable capture settings',
            allOf(
              contains('gain 139, offset 21'),
              contains('recorded in the flats'),
              contains('dark-flat'),
            ),
          ),
        ),
      );
      expect(seam.flatCalls, hasLength(2));
    },
  );

  test('flats without a matching bias are refused with the reason', () async {
    await addFrames('flat', 15, start: night, exposure: 1.5, filter: 'L');
    final group = (await service.pending()).single;

    await expectLater(
      service.build(group),
      throwsA(
        isA<CalibrationBacklogException>().having(
          (e) => e.message,
          'message',
          contains('No master bias at gain 76, offset 15, bin 1x1'),
        ),
      ),
    );
    expect(seam.flatCalls, isEmpty);
  });

  test(
    'a master flat built without settings reads them from its frames',
    () async {
      final flat = File('${tmp.path}/flat_L.fits');
      await flat.writeAsBytes(
        fitsHeader({
          'FILTER': 'L',
          'GAIN': 76.0,
          'OFFSET': 15,
          'XBINNING': 1,
          'YBINNING': 1,
          'CCD-TEMP': -9.5,
        }),
      );
      final flats = FlatLibraryService(dao: flatDao, seam: seam);

      final id = await flats.createMasterFlat(
        flatPaths: [flat.path, flat.path],
        outputPath: '${tmp.path}/master_flat.fits',
      );

      final entry = await flatDao.getEntryById(id);
      expect(entry!.filter, 'L');
      expect(entry.gain, 76);
      expect(entry.offset, 15);
      expect(entry.temperature, -9.5);
    },
  );

  test('a recorded wizard flat waits in the backlog', () async {
    await service.recordCapturedFlat(
      filePath: '${tmp.path}/Flats/L_1.fits',
      exposureSeconds: 2,
      capturedAt: night,
      filter: 'L',
      gain: 76,
      offset: 15,
    );
    await service.recordCapturedFlat(
      filePath: '${tmp.path}/Flats/L_2.fits',
      exposureSeconds: 2,
      capturedAt: night.add(const Duration(seconds: 5)),
      filter: 'L',
      gain: 76,
      offset: 15,
    );

    final group = (await service.pending()).single;

    expect(group.kind, CalibrationFrameKind.flat);
    expect(group.frames, hasLength(2));
  });

  test(
    'scheduled flats wait for bias then register once before integration',
    () async {
      await addFrames('flat', 20, start: night, exposure: 0.32, filter: 'Ha');
      await addFrames('light', 2, start: night, exposure: 180, filter: 'Ha');
      final lights = (await db.imagesDao.getAllImages())
          .where((f) => f.frameType == 'light')
          .toList();
      await service.scheduleFlat((await service.pending()).single, true);
      final container = ProviderContainer(
        overrides: [
          calibrationBacklogServiceProvider.overrideWithValue(service),
          calibrationBacklogProvider.overrideWith(
            (ref) => CalibrationBacklogNotifier(ref, remote: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(calibrationBacklogProvider.notifier);
      await expectLater(
        notifier.prepareForLights(lights),
        throwsA(isA<CalibrationBacklogException>()),
      );
      expect(seam.flatCalls, isEmpty);
      expect(await service.scheduledFlats(), isNotEmpty);
      await addMaster(frameType: 'bias', exposure: 0.001, createdAt: night);
      await notifier.prepareForLights(lights);
      expect(seam.flatCalls, hasLength(1));
      expect((await flatDao.getAllEntries()).single.filter, 'Ha');
      await notifier.prepareForLights(lights);
      expect(seam.flatCalls, hasLength(1));
    },
  );

  test('the notifier builds in turn and bumps the library revision', () async {
    await addFrames('dark', 20, start: night);
    await addFrames('bias', 50, start: night, exposure: 0.001, dir: 'Bias');
    final container = ProviderContainer(
      overrides: [
        calibrationBacklogServiceProvider.overrideWithValue(service),
        calibrationBacklogProvider.overrideWith(
          (ref) => CalibrationBacklogNotifier(ref, remote: false),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(calibrationBacklogProvider.notifier);
    await notifier.refresh();
    expect(
      container.read(calibrationBacklogProvider).groups.value,
      hasLength(2),
    );

    notifier.buildAll();
    // Bias is queued first so flats built later can use it.
    expect(
      container
          .read(calibrationBacklogProvider)
          .builds
          .values
          .map((b) => b.phase),
      everyElement(
        anyOf(CalibrationBuildPhase.queued, CalibrationBuildPhase.building),
      ),
    );
    while (container
        .read(calibrationBacklogProvider)
        .builds
        .values
        .any((b) => b.phase != CalibrationBuildPhase.built)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(masterCalls.map((c) => c.kind), ['bias', 'dark']);
    expect(container.read(calibrationLibraryRevisionProvider), 2);
    // The list is read again after the last build; wait for that read.
    for (
      var i = 0;
      i < 200 &&
          (container
                  .read(calibrationBacklogProvider)
                  .groups
                  .value
                  ?.isNotEmpty ??
              true);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(calibrationBacklogProvider).groups.value, isEmpty);
  });
}

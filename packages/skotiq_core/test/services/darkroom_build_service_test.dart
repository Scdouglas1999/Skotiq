import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/calibration_library_service.dart';
import 'package:skotiq_core/src/services/calibration_master_builder.dart';
import 'package:skotiq_core/src/services/dark_library_service.dart';
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/services/darkroom_build_service.dart';

import 'darkroom_fake_native.dart';

CapturedImage _image(
  int id,
  String filter,
  DateTime at, {
  double? temp,
  String path = '/x.fits',
  double quality = 50,
}) => CapturedImage(
  id: id,
  filePath: path,
  fileName: 'f$id.fits',
  fileFormat: 'fits',
  frameType: 'light',
  exposureDuration: 120,
  gain: 100,
  offset: 50,
  binX: 1,
  binY: 1,
  filter: filter,
  sensorTemp: temp,
  capturedAt: at,
  qualityScore: quality,
  isPlateSolved: false,
  createdAt: at,
  isAccepted: true,
);

void main() {
  late SkotiqDatabase db;
  late Directory folder;
  late FakeDarkroomNative native;
  late DarkroomBuildService service;
  late DarkroomBuildPlan plan;
  late Map<String, String> paths;

  DarkroomBuildService makeService() => DarkroomBuildService(
    library: CalibrationLibraryService(
      db: db,
      flatLibraryDao: FlatLibraryDao(db),
      tagsDao: CalibrationTagsDao(db),
    ),
    masters: IntegratedMastersDao(db),
    readHeader: (_) async => {
      'INSTRUME': 'ZWO ASI2600MM Pro',
      'TELESCOP': 'RedCat 51',
      'NAXIS1': '100',
      'NAXIS2': '80',
    },
    operation: native.call,
  );

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    folder = await Directory.systemTemp.createTemp('skotiq-guided-');
    paths = {};
    final groups = <Map<String, dynamic>>[];
    var id = 0;
    for (final f in ['B', 'L', 'R']) {
      final lights = <Map<String, dynamic>>[];
      for (var i = 0; i < 2; i++) {
        final file = File('${folder.path}/${f}_$i.fits');
        await file.writeAsString('raw input');
        paths['$f$i'] = file.path;
        final dbId = await db.imagesDao.createImage(
          CapturedImagesCompanion.insert(
            filePath: file.path,
            fileName: '${f}_$i.fits',
            exposureDuration: 90,
            capturedAt: DateTime(2026, 10, 22, 23),
            filter: Value(f),
          ),
        );
        lights.add({
          'id': dbId,
          'path': file.path,
          'exposureSec': 90.0,
          'side': i == 0 ? 'West' : 'East',
        });
        id++;
      }
      groups.add({
        'label': 'Night of 2026-10-22 · $f',
        'filter': f,
        'calibration': <String, dynamic>{},
        'lights': lights,
      });
    }
    expect(id, 6);
    plan = DarkroomBuildPlan.fromJson({
      'version': 1,
      'target': 'NGC891',
      'groups': groups,
      'referencePath': paths['L0'],
      'minOverlap': .95,
      'maxEccentricity': .65,
    });
    native = FakeDarkroomNative(paths);
    service = makeService();
  });

  tearDown(() async {
    await db.close();
    await folder.delete(recursive: true);
  });

  test('a filter with no integrable light is reported with reasons', () {
    const e =
        '{"kind":"noSubsIntegrated","filter":"R","offered":2,"skipped":['
        '{"path":"/d/R_1.fits","group":"n1","stage":"registration","reason":"too few stars"}]}';
    expect(
      describeFilterFailure(e),
      'None of its 2 lights could be integrated (R_1.fits: too few stars).',
    );
    expect(
      describeFilterFailure(StateError('disk full')),
      'Bad state: disk full',
    );
  });

  test('a plan may pair a dark with a bias only to scale the dark', () {
    Map<String, dynamic> plan(Map<String, dynamic> calibration) => {
      'version': 1,
      'target': 'T',
      'referencePath': '/a.fits',
      'minOverlap': .95,
      'maxEccentricity': .65,
      'groups': [
        {
          'label': 'n1',
          'filter': 'L',
          'calibration': calibration,
          'lights': [
            {'id': 1, 'path': '/a.fits', 'exposureSec': 120},
          ],
        },
      ],
    };
    expect(
      () => DarkroomBuildPlan.fromJson(plan({'dark': '/d', 'bias': '/b'})),
      throwsFormatException,
    );
    expect(
      DarkroomBuildPlan.fromJson(
        plan({'dark': '/d', 'bias': '/b', 'scaleDark': true}),
      ).target,
      'T',
    );
  });

  test('integration time reads in minutes under an hour', () {
    expect(describeIntegration(105), '2 min');
    expect(describeIntegration(14160), '3.9 h');
  });

  group('observing night', () {
    test('runs from local noon to local noon', () {
      expect(observingNight(DateTime(2026, 10, 22, 20)), '2026-10-22');
      expect(observingNight(DateTime(2026, 10, 23, 2, 30)), '2026-10-22');
      expect(observingNight(DateTime(2026, 10, 23, 11, 59)), '2026-10-22');
      expect(observingNight(DateTime(2026, 10, 23, 12)), '2026-10-23');
      expect(observingNight(DateTime(2026, 11, 1, 1)), '2026-10-31');
    });
  });

  group('prepare', () {
    test(
      'keeps a night together across midnight and over small cooler drift',
      () async {
        final frames = [
          _image(1, 'L', DateTime(2026, 10, 22, 21), temp: -10.0),
          _image(2, 'L', DateTime(2026, 10, 22, 23, 50), temp: -9.2),
          _image(3, 'L', DateTime(2026, 10, 23, 0, 10), temp: -8.6),
          _image(4, 'L', DateTime(2026, 10, 23, 4), temp: -10.4),
          _image(5, 'L', DateTime(2026, 10, 23, 21), temp: -10.0),
        ];
        final groups = await service.prepare(frames);
        expect(groups, hasLength(2));
        expect(groups[0].frames.map((f) => f.id), [1, 2, 3, 4]);
        expect(groups[0].night, '2026-10-22');
        expect(groups[0].label, startsWith('Night of 2026-10-22 · L · 120 s'));
        expect(groups[1].night, '2026-10-23');
      },
    );

    test('a different cooler set point is its own group', () async {
      final frames = [
        _image(1, 'L', DateTime(2026, 10, 22, 21), temp: -10.0),
        _image(2, 'L', DateTime(2026, 10, 22, 22), temp: -9.5),
        _image(3, 'L', DateTime(2026, 10, 22, 23), temp: 0.2),
        _image(4, 'L', DateTime(2026, 10, 22, 23, 30)),
      ];
      final groups = await service.prepare(frames);
      expect(groups, hasLength(2));
      expect(groups.map((g) => g.frames.length).toList()..sort(), [1, 3]);
      expect(
        groups.firstWhere((g) => g.frames.length == 3).label,
        contains('-10 C'),
      );
    });
  });

  group('flats', () {
    DarkroomBuildGroup g(
      String filter,
      String night, {
      String? flat,
      int n = 10,
    }) => DarkroomBuildGroup(
      label: '$night $filter',
      filter: filter,
      night: night,
      frames: [
        for (var i = 0; i < n; i++) _image(i, filter, DateTime(2026, 10, 22)),
      ],
      calibration: {if (flat != null) 'flat': flat},
      warnings: [],
    );

    test('a filter flat applies to its nights that have none', () {
      final groups = [
        g('L', 'n1', flat: '/flats/L_a.fits', n: 30),
        g('L', 'n2'),
        g('L', 'n3', flat: '/flats/L_b.fits', n: 5),
        g('R', 'n1'),
      ];
      DarkroomBuildService.shareFlatsWithinFilters(groups);
      expect(groups[1].calibration['flat'], '/flats/L_a.fits');
      expect(groups[1].warnings.single, contains('another night'));
      expect(groups[2].calibration['flat'], '/flats/L_b.fits');
      expect(groups[3].hasFlat, isFalse);
    });

    test('coverage warns plainly when some filters have no flats', () {
      final groups = [
        g('L', 'n1', flat: '/L.fits'),
        g('B', 'n1', flat: '/B.fits'),
        g('R', 'n1'),
        g('G', 'n1'),
      ];
      final coverage = DarkroomBuildService.flatCoverage(groups);
      expect(coverage.withFlats, ['B', 'L']);
      expect(coverage.withoutFlats, ['G', 'R']);
      expect(
        coverage.warning,
        'Flats are available for B, L, but not for G, R. '
        'Masters built without flats keep dust shadows and vignetting.',
      );
      DarkroomBuildService.applyToFilter(groups, 'R', 'flat', '/L.fits');
      expect(DarkroomBuildService.flatCoverage(groups).withoutFlats, ['G']);
    });

    test('built masters register in the calibration library', () async {
      final darkDao = DarkLibraryDao(db);
      final flatDao = FlatLibraryDao(db);
      final svc = DarkroomBuildService(
        operation: native.call,
        library: CalibrationLibraryService(
          db: db,
          flatLibraryDao: flatDao,
          tagsDao: CalibrationTagsDao(db),
        ),
        masters: IntegratedMastersDao(db),
        darkLibrary: DarkLibraryService(darkDao),
        flatLibrary: flatDao,
        buildFlat: (args) async => {
          'width': 100,
          'height': 80,
          'frameCount': 19,
        },
        buildMaster: (request) async => CalibrationMasterBuildResult.fromJson({
          'outputPath': request.outputPath,
          'kind': request.kind,
          'width': 100,
          'height': 80,
          'frameCount': 30,
          'leakBaseline': 0,
          'leakThreshold': 0,
          'masterMean': 500,
          'rejectionFraction': 0,
          'exposureSecs': 120,
          'gain': 100,
          'offset': 50,
        }),
      );
      await svc.buildCalibration(
        kind: 'dark',
        paths: ['/d1.fits'],
        output: '/masters/dark.fits',
      );
      await svc.buildCalibration(
        kind: 'flat',
        paths: ['/f1.fits'],
        output: '/masters/flat_B.fits',
        bias: '/masters/bias.fits',
        forGroup: g('B', 'n1'),
      );
      final darks = await darkDao.getAllEntries();
      expect(darks.single.filePath, '/masters/dark.fits');
      expect(darks.single.exposureTime, 120);
      final flats = await flatDao.getAllEntries();
      expect(flats.single.filePath, '/masters/flat_B.fits');
      expect(flats.single.filter, 'B');
      expect(flats.single.masterFrameCount, 19);
    });
  });

  group('framing pre-pass', () {
    test('sends limits and pier sides, then reuses known footprints', () async {
      final first = await service.previewRegistration(plan);
      final request = native.requests.single;
      expect(request['minRetainedArea'], .8);
      expect(request['minOverlap'], .95);
      expect(request['groups'][0]['lights'][0]['side'], 'West');
      expect(request.containsKey('gridSize'), isFalse);
      expect(first.frames, hasLength(6));

      final fewer = plan.withoutLights({paths['R1']!: 'Limits the crop'});
      await service.previewRegistration(fewer, previous: first);
      final again = native.requests.last;
      expect(again['gridSize'], [100, 80]);
      final lights = [
        for (final g in again['groups'] as List) ...(g['lights'] as List),
      ];
      expect(lights, hasLength(5));
      expect(lights.every((l) => l['known'] != null), isTrue);
      expect(fewer.toJson()['excluded'].single['reason'], 'Limits the crop');
    });

    test('the reference cannot be excluded', () {
      expect(
        () => plan.withoutLights({paths['L0']!: 'x'}),
        throwsArgumentError,
      );
    });

    test('the crop error names the limiting frames', () async {
      native.retained = .62;
      native.limiting = [
        {'path': '/data/R_0058.fits', 'group': 'n2', 'retainedWithout': .93},
        {'path': '/data/G_0012.fits', 'group': 'n3', 'retainedWithout': .7},
      ];
      final preview = await service.previewRegistration(plan);
      expect(preview.meetsMinimum, isFalse);
      await expectLater(
        service.run(plan, Directory('${folder.path}/run'), accepted: preview),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('62.0%'),
              contains('R_0058.fits (93.0% without it)'),
              contains('G_0012.fits'),
            ),
          ),
        ),
      );
      expect(native.built, isEmpty);
    });

    test('a build never starts without an accepted pre-pass', () async {
      await expectLater(
        service.run(plan, Directory('${folder.path}/run')),
        throwsA(isA<StateError>()),
      );
      expect(native.built, isEmpty);
    });
  });

  group('run', () {
    test(
      'resume reuses finished filters, exports once and persists masters idempotently',
      () async {
        final preview = await service.previewRegistration(plan);
        final output = Directory('${folder.path}/run');
        native.cancelFilters.add('L');
        await expectLater(
          service.run(plan, output, accepted: preview),
          throwsStateError,
        );
        final saved =
            jsonDecode(await File('${output.path}/plan.json').readAsString())
                as Map;
        final resumed = DarkroomBuildPlan.fromJson(
          Map<String, dynamic>.from(saved['plan'] as Map),
        );
        final result = await service.run(resumed, output);
        expect(native.built, ['B', 'L', 'L', 'R']);
        expect(result['results'], hasLength(3));
        await service.run(resumed, output);
        expect(native.built, ['B', 'L', 'L', 'R']);
        expect(await IntegratedMastersDao(db).getAll(), hasLength(3));
        final build = native.requests.firstWhere((r) => r['op'] == 'build');
        expect(build['settings']['weighting']['formula'], 'starSignal');
        final delivery = native.requests.firstWhere(
          (r) => r['op'] == 'deliverUniform',
        );
        expect(delivery['minRetainedArea'], .8);
        expect(
          await File('${output.path}/frame-audit.csv').readAsString(),
          contains('true'),
        );
      },
    );

    test('a failing filter is reported and the others are built', () async {
      native.failFilters.add('R');
      final preview = await service.previewRegistration(plan);
      final report = await service.run(
        plan,
        Directory('${folder.path}/run'),
        accepted: preview,
      );
      expect(native.built, ['B', 'L', 'R']);
      expect([for (final r in report['results']) r['filter']], ['B', 'L']);
      expect(report['failures'].single['filter'], 'R');
      final delivery = native.requests.lastWhere(
        (r) => r['op'] == 'deliverUniform',
      );
      expect(delivery['masters'], hasLength(2));
      expect(await IntegratedMastersDao(db).getAll(), hasLength(2));
    });

    test(
      'excluding frames after a partial build rebuilds only the filters they touch',
      () async {
        native.failFilters.add('R');
        final preview = await service.previewRegistration(plan);
        final output = Directory('${folder.path}/run');
        await service.run(plan, output, accepted: preview);
        expect(native.built, ['B', 'L', 'R']);
        native.failFilters.clear();

        final edited = plan.withoutLights({paths['B1']!: 'Limits the crop'});
        await expectLater(
          service.run(edited, output),
          throwsA(isA<StateError>()),
          reason: 'an edited plan needs a fresh framing check',
        );
        final rechecked = await service.previewRegistration(
          edited,
          previous: preview,
        );
        final report = await service.run(edited, output, accepted: rechecked);
        expect(native.built, ['B', 'L', 'R', 'B', 'R']);
        expect(report['results'], hasLength(3));
        final journal =
            jsonDecode(await File('${output.path}/plan.json').readAsString())
                as Map;
        expect(jsonEncode(journal['plan']), jsonEncode(edited.toJson()));
      },
    );

    test('resume refuses changed source files', () async {
      final preview = await service.previewRegistration(plan);
      final output = Directory('${folder.path}/run');
      native.cancelFilters.add('B');
      await expectLater(
        service.run(plan, output, accepted: preview),
        throwsStateError,
      );
      await File(paths['L0']!).writeAsString('changed raw input');
      await expectLater(
        service.run(plan, output),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('input files changed'),
          ),
        ),
      );
      expect(native.built, ['B']);
    });

    test('a changed calibration choice is not an exclusion', () async {
      final preview = await service.previewRegistration(plan);
      final output = Directory('${folder.path}/run');
      await service.run(plan, output, accepted: preview);
      final json = plan.toJson();
      (json['groups'] as List).first['calibration'] = {'flat': paths['B0']};
      await expectLater(
        service.run(
          DarkroomBuildPlan.fromJson(json),
          output,
          accepted: preview,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('plan or its input files changed'),
          ),
        ),
      );
    });
  });

  group('unattended', () {
    Future<List<CapturedImage>> frames() async => [
      for (final f in await db.imagesDao.getAllImages())
        f.copyWith(sensorTemp: const Value(-10)),
    ];

    test('builds every filter when the crop meets the minimum', () async {
      final outcome = await service.buildUnattended(
        target: 'NGC891',
        frames: await frames(),
        directory: Directory('${folder.path}/auto'),
      );
      expect(outcome.built, isTrue);
      expect(native.built, ['B', 'L', 'R']);
      expect(outcome.plan!.referencePath, contains('/L_'));
      expect(
        outcome.warnings.single,
        contains('No filter has flats (B, L, R)'),
        reason: 'no flats in the empty library',
      );
    });

    test('waits for review below the minimum and integrates nothing', () async {
      native.retained = .5;
      final outcome = await service.buildUnattended(
        target: 'NGC891',
        frames: await frames(),
        directory: Directory('${folder.path}/auto'),
      );
      expect(outcome.built, isFalse);
      expect(outcome.preview.retainedArea, .5);
      expect(native.built, isEmpty);
    });
  });
}

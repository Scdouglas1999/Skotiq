import 'dart:io';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/services/calibration_library_service.dart';
import 'package:skotiq_core/src/services/darkroom_build_service.dart';

void main() {
  late SkotiqDatabase db;
  late Directory folder;
  late DarkroomBuildService service;
  late DarkroomBuildPlan plan;
  late List<String> built;
  late bool failRed;
  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    folder = await Directory.systemTemp.createTemp('skotiq-guided-');
    built = [];
    failRed = true;
    final inputs = <Map<String, dynamic>>[];
    for (final f in ['L', 'R']) {
      final file = File('${folder.path}/$f.fits');
      await file.writeAsString('raw input');
      await db.imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: file.path,
          fileName: '$f.fits',
          exposureDuration: 90,
          capturedAt: DateTime.now(),
        ),
      );
      inputs.add({
        'label': 'night-$f',
        'filter': f,
        'calibration': <String, dynamic>{},
        'lights': [
          {'id': inputs.length + 1, 'path': file.path, 'exposureSec': 90.0},
        ],
      });
    }
    plan = DarkroomBuildPlan.fromJson({
      'version': 1,
      'target': 'NGC891',
      'groups': inputs,
      'referencePath': inputs[0]['lights'][0]['path'],
      'minOverlap': .95,
      'maxEccentricity': .65,
    });
    service = DarkroomBuildService(
      library: CalibrationLibraryService(
        db: db,
        flatLibraryDao: FlatLibraryDao(db),
        tagsDao: CalibrationTagsDao(db),
      ),
      masters: IntegratedMastersDao(db),
      operation: (args) async {
        if (args['op'] == 'build') {
          final f = args['filter'] as String;
          built.add(f);
          if (f == 'R' && failRed) {
            throw StateError('interrupted');
          }
          expect(args['gridReference']['path'], inputs[0]['lights'][0]['path']);
          expect(args['minOverlap'], .95);
          expect(args['validateFlats'], true);
          for (final key in [
            'masterFitsPath',
            'coverageFitsPath',
            'previewPngPath',
          ]) {
            await File(args[key] as String).writeAsString('artifact');
          }
          return {
            'filter': f,
            'masterPath': args['masterFitsPath'],
            'coveragePath': args['coverageFitsPath'],
            'frameCount': 1,
            'totalIntegrationSec': 90.0,
            'folded': [
              {'path': inputs[f == 'L' ? 0 : 1]['lights'][0]['path']},
            ],
            'skipped': [],
          };
        }
        expect(args['op'], 'deliverUniform');
        await Directory(args['outputDir'] as String).create();
        final files = <Map<String, dynamic>>[];
        for (final f in ['L', 'R']) {
          final file = File('${args['outputDir']}/$f.fits');
          await file.writeAsString('linear');
          files.add({
            'path': file.path,
            'previewPath': '${file.path}.png',
            'channels': 1,
          });
        }
        return {
          'masters': files,
          'width': 100,
          'height': 80,
          'crop': [2, 3, 102, 83],
          'retainedArea': .9,
        };
      },
    );
  });
  tearDown(() async {
    await db.close();
    await folder.delete(recursive: true);
  });
  test(
    'resume reuses finished filters, exports once and persists masters idempotently',
    () async {
      final output = Directory('${folder.path}/run');
      await expectLater(service.run(plan, output), throwsStateError);
      expect(built, ['L', 'R']);
      failRed = false;
      final saved =
          jsonDecode(await File('${output.path}/plan.json').readAsString())
              as Map;
      final resumed = DarkroomBuildPlan.fromJson(
        Map<String, dynamic>.from(saved['plan'] as Map),
      );
      final result = await service.run(resumed, output);
      expect(built, ['L', 'R', 'R']);
      expect(result['results'], hasLength(2));
      await service.run(resumed, output);
      expect(built, ['L', 'R', 'R']);
      expect(await IntegratedMastersDao(db).getAll(), hasLength(2));
      expect(
        await File('${output.path}/frame-audit.csv').readAsString(),
        contains('true'),
      );
    },
  );
  test(
    'resume refuses changed source files instead of mixing old and new data',
    () async {
      final output = Directory('${folder.path}/run');
      await expectLater(service.run(plan, output), throwsStateError);
      await File('${folder.path}/L.fits').writeAsString('changed raw input');
      failRed = false;
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
      expect(built, ['L', 'R']);
    },
  );
  test(
    'saved plans reject unsupported versions, duplicate exposures and an external reference',
    () {
      final v = plan.toJson()..['version'] = 2;
      expect(() => DarkroomBuildPlan.fromJson(v), throwsFormatException);
      final d = plan.toJson();
      (d['groups'] as List).add((d['groups'] as List).first);
      expect(() => DarkroomBuildPlan.fromJson(d), throwsFormatException);
      final r = plan.toJson()..['referencePath'] = 'other.fits';
      expect(() => DarkroomBuildPlan.fromJson(r), throwsFormatException);
    },
  );
}

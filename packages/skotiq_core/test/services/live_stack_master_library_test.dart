import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/frame_header.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';
import 'package:skotiq_core/src/services/live_stack_master_library.dart';
import 'package:skotiq_core/src/models/imaging/live_stacking_models.dart';

void main() {
  late SkotiqDatabase db;
  late IntegratedMastersDao masters;
  late List<String> previews;
  late List<String> events;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    masters = IntegratedMastersDao(db);
    previews = [];
    events = [];
  });
  tearDown(() => db.close());

  LiveStackMasterLibrary library({
    LiveStackingMasterFormat format = LiveStackingMasterFormat.fitsMaster,
    Map<String, Object> header = const {'OBJECT': 'NGC 891', 'FILTER': 'L'},
    bool previewFails = false,
    Map<String, Map<String, Object>>? headersByPath,
  }) => LiveStackMasterLibrary(
    currentResult: () async {
      events.add('read');
      return const LiveStackingResult(
        width: 4656,
        height: 3520,
        data: [],
        stats: LiveStackingStats(stackedFrameCount: 12),
      );
    },
    saveMaster: (path) async {
      events.add('save');
      return LiveStackingMasterSave(
        filePath: path,
        stackedFrameCount: 12,
        format: format,
        totalIntegrationSecs: format == LiveStackingMasterFormat.fitsMaster
            ? 1440
            : null,
        dateObs: '2026-10-24T01:12:00',
      );
    },
    writePreview: (path, result) async {
      if (previewFails) throw StateError('disk full');
      previews.add(path);
    },
    masters: masters,
    readHeader: (path) async => FrameHeader(
      headersByPath == null
          ? header
          : (headersByPath[path] ?? (throw StateError('no file $path'))),
    ),
  );

  test(
    'a FITS master is registered under its target with a thumbnail',
    () async {
      final save = await library().save('/stacks/live_12frames.fits');

      expect(events, ['read', 'save'], reason: 'the stack is read first');
      expect(previews, ['/stacks/live_12frames.png']);
      final row = (await masters.getAll()).single;
      expect(row.id, save.masterId);
      expect(row.name, 'NGC 891 L live stack');
      expect(row.masterFitsPath, '/stacks/live_12frames.fits');
      expect(row.previewPngPath, '/stacks/live_12frames.png');
      expect(row.filter, 'L');
      expect(row.channels, 1);
      expect((row.width, row.height), (4656, 3520));
      expect(row.frameCount, 12);
      expect(row.totalIntegrationSeconds, 1440);
      expect(row.status, IntegratedMasterStatus.finalized);
      expect(jsonDecode(row.settingsJson), {
        'source': 'liveStack',
        'target': 'NGC 891',
      });
    },
  );

  test(
    'a PNG save is a picture, not a master, and is not registered',
    () async {
      final save = await library(
        format: LiveStackingMasterFormat.linearMono16,
      ).save('/stacks/live.png');

      expect(save.masterId, isNull);
      expect(await masters.getAll(), isEmpty);
    },
  );

  test('a master whose thumbnail fails is still registered', () async {
    final save = await library(previewFails: true).save('/stacks/live.fits');

    expect(save.previewPath, isNull);
    final row = (await masters.getAll()).single;
    expect(row.previewPngPath, isNull);
    expect(row.masterFitsPath, '/stacks/live.fits');
  });

  test('a header with no object names the master as a live stack', () async {
    await library(header: const {}).save('/stacks/live.fits');

    final row = (await masters.getAll()).single;
    expect(row.name, 'Live stack');
    expect(row.filter, isNull);
    expect(jsonDecode(row.settingsJson), {'source': 'liveStack'});
  });

  test('a named filter is saved through the per-filter callbacks', () async {
    final reads = <String>[];
    final writes = <String>[];
    final libraryWithFilter = LiveStackMasterLibrary(
      currentResult: () async => const LiveStackingResult(
        width: 4,
        height: 4,
        data: [],
        filterKey: 'L',
        stats: LiveStackingStats(stackedFrameCount: 3),
      ),
      currentResultForFilter: (filterKey) async {
        reads.add(filterKey);
        return LiveStackingResult(
          width: 4,
          height: 4,
          data: const [],
          filterKey: filterKey,
          stats: const LiveStackingStats(stackedFrameCount: 9),
        );
      },
      saveMaster: (path) async {
        events.add('active:$path');
        return LiveStackingMasterSave(
          filePath: path,
          stackedFrameCount: 3,
          format: LiveStackingMasterFormat.fitsMaster,
        );
      },
      saveMasterForFilter: (filterKey, path) async {
        writes.add('$filterKey:$path');
        return LiveStackingMasterSave(
          filePath: path,
          stackedFrameCount: 9,
          format: LiveStackingMasterFormat.fitsMaster,
          totalIntegrationSecs: 540,
        );
      },
      writePreview: (path, result) async => previews.add(path),
      masters: masters,
      readHeader: (_) async => FrameHeader(const {}),
    );

    await libraryWithFilter.save('/stacks/ha.fits', filterKey: '  Ha  ');

    expect(reads, ['Ha']);
    expect(writes, ['Ha:/stacks/ha.fits']);
    expect(events, isEmpty);
    final row = (await masters.getAll()).single;
    expect(row.filter, 'Ha');
    expect(row.frameCount, 9);
    expect(row.name, 'Live stack Ha');
  });

  test(
    'a named filter without a per-filter saver is an error, not the active slot',
    () async {
      await expectLater(
        library().save('/stacks/ha.fits', filterKey: 'Ha'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Ha'),
          ),
        ),
      );
      expect(events, isEmpty);
      expect(await masters.getAll(), isEmpty);
    },
  );

  test('a blank or dash filter key saves the active slot', () async {
    await library(header: const {}).save('/stacks/live.fits', filterKey: '—');

    expect(events, ['read', 'save']);
    final row = (await masters.getAll()).single;
    expect(row.filter, isNull);
    expect(row.name, 'Live stack');
  });

  test('the target and filter come from the stack\'s reference frame when the '
      'master names none', () async {
    await library(
      headersByPath: {
        '/stacks/live.fits': const {'IMAGETYP': 'MASTER_LIGHT'},
        '/frames/ref.fits': const {'OBJECT': 'M 81', 'FILTER': 'Ha'},
      },
    ).save('/stacks/live.fits', sourceFramePath: '/frames/ref.fits');

    final row = (await masters.getAll()).single;
    expect(row.name, 'M 81 Ha live stack');
    expect(row.filter, 'Ha');
    expect(jsonDecode(row.settingsJson)['target'], 'M 81');
  });
}

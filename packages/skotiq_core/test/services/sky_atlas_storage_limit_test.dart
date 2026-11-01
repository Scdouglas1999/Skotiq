// The Your Sky atlas has a size limit: when it is reached, new frames stop
// being folded and the user is told once. Nothing is ever deleted. Older
// uncompressed tiles can be rewritten compressed on request.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

class _RecordingSeam implements SkyAtlasSeam {
  final List<Map<String, dynamic>> dispatched = [];

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    dispatched.add(args);
    if (args['action'] == 'compact') {
      return {
        'ok': true,
        'compacted': 3,
        'alreadyCompact': 1,
        'unreadable': 0,
        'bytesBefore': 125000000,
        'bytesAfter': 31000000,
      };
    }
    return {'ok': true, 'framesSkippedNoCoverage': 0};
  }

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async => {
    'ok': true,
  };
}

DbCapturedImage _light(int id) => DbCapturedImage(
  id: id,
  filePath: '/tmp/light_$id.fits',
  fileName: 'light_$id.fits',
  fileFormat: 'fits',
  frameType: 'light',
  exposureDuration: 300.0,
  binX: 1,
  binY: 1,
  isPlateSolved: true,
  solvedRa: 5.575,
  solvedDec: -5.39,
  solvedPixelScale: 1.5,
  capturedAt: DateTime.utc(2026, 6, 11, 22),
  createdAt: DateTime.utc(2026, 6, 11, 22),
  isAccepted: true,
);

void main() {
  late SkotiqDatabase db;
  late Directory root;
  late _RecordingSeam seam;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('atlas-limit-');
    seam = _RecordingSeam();
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  SkyAtlasService serviceWith({
    required int? limitBytes,
    void Function(int used, int limit)? onLimit,
  }) => SkyAtlasService(
    dao: SkyAtlasDao(db),
    seam: seam,
    logger: LoggingService(),
    atlasRootResolver: () async => root.path,
    storageLimitBytes: () async => limitBytes,
    onStorageLimitReached: onLimit,
  );

  Future<void> writeTile(String name, int bytes) async {
    final file = File(p.join(root.path, 'tiles', '9', name));
    await file.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(bytes, 1));
  }

  test('storage counts every file under the atlas', () async {
    await writeTile('1.skt', 1000);
    await writeTile('layers/ha/2.skt', 500);
    final service = serviceWith(limitBytes: null);
    expect(await service.storageBytes(), 1500);
  });

  test(
    'a full atlas folds nothing, deletes nothing, and says so once',
    () async {
      await writeTile('1.skt', 4000);
      final reports = <(int, int)>[];
      final service = serviceWith(
        limitBytes: 3000,
        onLimit: (used, limit) => reports.add((used, limit)),
      );

      for (var i = 1; i <= 3; i++) {
        final summary = await service.autoFoldCapturedImage(
          image: _light(i),
          imageWidth: 1000,
          imageHeight: 800,
        );
        expect(summary, isNull);
      }
      expect(seam.dispatched.where((a) => a['action'] == 'fold'), isEmpty);
      expect(reports, [(4000, 3000)]);
      expect(
        File(p.join(root.path, 'tiles', '9', '1.skt')).existsSync(),
        isTrue,
      );
    },
  );

  test('below the limit, or with no limit, frames still fold', () async {
    await writeTile('1.skt', 1000);
    for (final limit in [3000, 0, null]) {
      seam.dispatched.clear();
      final service = serviceWith(limitBytes: limit);
      await service.autoFoldCapturedImage(
        image: _light(1),
        imageWidth: 1000,
        imageHeight: 800,
      );
      expect(
        seam.dispatched.where((a) => a['action'] == 'fold'),
        isNotEmpty,
        reason: 'limit $limit',
      );
    }
  });

  test('compaction asks the native side to rewrite old tiles', () async {
    final service = serviceWith(limitBytes: null);
    final outcome = await service.compactTiles();
    expect(seam.dispatched.single['action'], 'compact');
    expect(seam.dispatched.single['atlasRoot'], root.path);
    expect(outcome.compacted, 3);
    expect(outcome.bytesBefore, 125000000);
    expect(outcome.bytesAfter, 31000000);
  });

  test('an unset or bad stored limit reads as the default', () {
    expect(parseSkyAtlasLimitGb(null), defaultSkyAtlasLimitGb);
    expect(parseSkyAtlasLimitGb('nope'), defaultSkyAtlasLimitGb);
    expect(parseSkyAtlasLimitGb('-2'), defaultSkyAtlasLimitGb);
    expect(parseSkyAtlasLimitGb('0'), 0);
    expect(parseSkyAtlasLimitGb('80'), 80);
  });
}

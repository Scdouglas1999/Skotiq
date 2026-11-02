// With Your Sky off nothing is folded, merged or rendered under the atlas
// root, and the data kept from before can be deleted on request.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';

class _RecordingSeam implements SkyAtlasSeam {
  final List<Map<String, dynamic>> calls = [];

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    calls.add(args);
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) async {
    calls.add({'action': 'cutout'});
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async {
    calls.add({'action': 'merge'});
    return {'ok': true};
  }
}

DbCapturedImage _light() => DbCapturedImage(
  id: 1,
  filePath: '/tmp/light_1.fits',
  fileName: 'light_1.fits',
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
  late SkyAtlasService service;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('atlas-off-');
    seam = _RecordingSeam();
    service = SkyAtlasService(
      dao: SkyAtlasDao(db),
      seam: seam,
      logger: LoggingService(),
      atlasRootResolver: () async => root.path,
      autoFoldEnabled: () async => false,
    );
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('a solved frame is not folded while Your sky is off', () async {
    final summary = await service.autoFoldCapturedImage(
      image: _light(),
      imageWidth: 1000,
      imageHeight: 800,
    );
    expect(summary, isNull);
    expect(seam.calls, isEmpty);
  });

  test('merges and renders are refused, not written', () async {
    await expectLater(
      service.mergeSwarmDelta(tileId: 1, deltaPath: '/tmp/d.skt'),
      throwsA(isA<SkyAtlasOffException>()),
    );
    await expectLater(
      service.cutout(centerRaDeg: 1, centerDecDeg: 2, radiusDeg: 1),
      throwsA(isA<SkyAtlasOffException>()),
    );
    await expectLater(
      service.finalizeTilePng(1),
      throwsA(isA<SkyAtlasOffException>()),
    );
    expect(seam.calls, isEmpty);
    expect(root.listSync(), isEmpty);
  });

  test('delete removes the tiles and resets what pointed at them', () async {
    final tile = File(p.join(root.path, 'tiles', '9', '1.skt'));
    await tile.create(recursive: true);
    await service.deleteAllData();
    expect(root.existsSync(), isFalse);
  });

  test('a profile with no stored choice does not fold', () async {
    await db.customStatement(
      "DELETE FROM app_settings WHERE key = 'science.feature.sky_atlas'",
    );
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    expect(await container.read(skyAtlasServiceProvider).isEnabled(), isFalse);
    await SettingsDao(db).setSetting('science.feature.sky_atlas', 'true');
    expect(await container.read(skyAtlasServiceProvider).isEnabled(), isTrue);
  });
}

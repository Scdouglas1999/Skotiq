import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A seam whose cone scans block until released, so the test can hold many
/// concurrent requests open and count how many reach the native side and how
/// many run at once.
class _SlowConeSeam implements SkyAtlasSeam {
  int growthCalls = 0;
  int regionInfoCalls = 0;
  int cutoutCalls = 0;
  int running = 0;
  int maxRunning = 0;
  Completer<void> gate = Completer<void>();

  Future<Map<String, dynamic>> _scan(Map<String, dynamic> result) async {
    running++;
    if (running > maxRunning) maxRunning = running;
    try {
      await gate.future;
      return result;
    } finally {
      running--;
    }
  }

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) {
    growthCalls++;
    return _scan({'ok': true, 'totalFrames': growthCalls});
  }

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) {
    regionInfoCalls++;
    return _scan({'ok': true, 'tilesWithData': regionInfoCalls});
  }

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) {
    cutoutCalls++;
    return _scan({'ok': true, 'pngPath': '/tmp/cutout.png'});
  }

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async => {
    'ok': true,
  };
}

void main() {
  late SkotiqDatabase db;
  late _SlowConeSeam seam;
  late SkyAtlasService service;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    await db
        .into(db.imagingSessions)
        .insert(
          ImagingSessionsCompanion.insert(
            id: const Value(7),
            startTime: DateTime.utc(2026, 6, 11, 21),
          ),
        );
    seam = _SlowConeSeam();
    service = SkyAtlasService(
      dao: SkyAtlasDao(db),
      seam: seam,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
    );
  });

  tearDown(() async {
    if (!seam.gate.isCompleted) seam.gate.complete();
    await db.close();
  });

  Future<Map<String, dynamic>> growthOf(double ra) =>
      service.growth(centerRaDeg: ra, centerDecDeg: 41.27, radiusDeg: 1.0);

  test('a burst of identical growth queries runs one native scan', () async {
    final burst = List.generate(120, (_) => growthOf(10.68));
    await Future<void>.delayed(Duration.zero);
    seam.gate.complete();
    final results = await Future.wait(burst);

    expect(seam.growthCalls, 1);
    expect(results.every((r) => r['totalFrames'] == 1), isTrue);

    // Served from the cache while the atlas is unchanged.
    await growthOf(10.68);
    expect(seam.growthCalls, 1);
  });

  test('a fold invalidates cached cone results', () async {
    seam.gate.complete();
    expect((await growthOf(10.68))['totalFrames'], 1);
    await service.foldFrame(
      sessionId: 7,
      frame: SolvedFrameRef.fromSolvedWcs(
        framePath: '/tmp/light_001.fits',
        exposureSec: 300.0,
        wcs: const SolvedWcs(
          raHours: 0.712,
          decDegrees: 41.27,
          rotationDeg: 0.0,
          pixelScaleArcsec: 1.5,
          imageWidth: 1000,
          imageHeight: 800,
        ),
      ),
    );
    expect((await growthOf(10.68))['totalFrames'], 2);
    expect(seam.growthCalls, 2);
  });

  test('different cones never scan concurrently', () async {
    final pending = [
      for (var i = 0; i < 6; i++) growthOf(10.0 + i),
      for (var i = 0; i < 6; i++)
        service.regionCoverage(
          centerRaDeg: 50.0 + i,
          centerDecDeg: 0,
          radiusDeg: 1,
        ),
      service.cutout(centerRaDeg: 1, centerDecDeg: 2, radiusDeg: 1),
    ];
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(seam.maxRunning, 1);
    seam.gate.complete();
    await Future.wait(pending);
    expect(seam.maxRunning, 1);
    expect(seam.growthCalls, 6);
    expect(seam.regionInfoCalls, 6);
    expect(seam.cutoutCalls, 1);
  });

  test('a failed scan is not cached', () async {
    final failing = _FailingOnceSeam();
    final svc = SkyAtlasService(
      dao: SkyAtlasDao(db),
      seam: failing,
      logger: LoggingService(),
      atlasRootResolver: () async => '/tmp/test_atlas',
    );
    await expectLater(
      svc.growth(centerRaDeg: 1, centerDecDeg: 2, radiusDeg: 1),
      throwsA(isA<SkyAtlasSeamException>()),
    );
    final ok = await svc.growth(centerRaDeg: 1, centerDecDeg: 2, radiusDeg: 1);
    expect(ok['ok'], isTrue);
    expect(failing.calls, 2);
  });
}

class _FailingOnceSeam extends _SlowConeSeam {
  int calls = 0;

  _FailingOnceSeam() {
    gate.complete();
  }

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async {
    calls++;
    if (calls == 1) throw const SkyAtlasSeamException('busy');
    return {'ok': true};
  }
}

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Records the frames handed to the pipeline; frames listed in [failing]
/// come back failed.
class _FakePipeline extends ScienceProcessingService {
  _FakePipeline(super.ref, {this.failing = const {}, this.gate});

  final Set<String> failing;
  final Completer<void>? gate;
  final calls = <({String path, int? id, int? sessionId})>[];

  @override
  Future<ScienceFrameOutcome> processFrame({
    required String imagePath,
    String? deviceId,
    int? capturedImageId,
    int? sessionId,
    bool solveIfUnsolved = true,
  }) async {
    if (gate != null) await gate!.future;
    calls.add((path: imagePath, id: capturedImageId, sessionId: sessionId));
    if (failing.contains(imagePath)) {
      return const ScienceFrameOutcome.failed('no stars');
    }
    return const ScienceFrameOutcome.processed();
  }
}

final _refProbe = Provider<Ref>((ref) => ref);

void main() {
  late SkotiqDatabase db;
  late ImagesDao images;
  late ProviderContainer container;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    images = ImagesDao(db);
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    for (final id in [92, 93]) {
      await db
          .into(db.imagingSessions)
          .insert(
            ImagingSessionsCompanion.insert(
              id: Value(id),
              startTime: DateTime.utc(2026, 10, 25, 1),
            ),
          );
    }
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<int> frame(
    String name, {
    required int minute,
    String frameType = 'light',
    int sessionId = 92,
  }) => images.insertSequenceFrame(
    filePath: '/lights/$name',
    fileName: name,
    fileFormat: 'fits',
    exposureDuration: 120.0,
    capturedAt: DateTime.utc(2026, 10, 25, 2, minute),
    isAccepted: true,
    producingNodeId: 'node-a',
    frameType: frameType,
    sessionId: sessionId,
  );

  ScienceReprocessService service(
    _FakePipeline pipeline, {
    Set<String> missing = const {},
  }) => ScienceReprocessService(
    images: () => images,
    science: () => db.scienceDao,
    pipeline: () => pipeline,
    logger: () => container.read(loggingServiceProvider),
    fileExists: (path) async => !missing.contains(path),
  );

  test('walks the session lights in capture order, one at a time, and '
      'reports progress', () async {
    // Inserted out of order: the walk follows capture time, not row id.
    final last = await frame('L_0003.fits', minute: 30);
    final early = await frame('L_0001.fits', minute: 10);
    await frame('D_0001.fits', minute: 20, frameType: 'dark');
    final missing = await frame('L_0002.fits', minute: 20);
    await frame('L_other.fits', minute: 15, sessionId: 93);

    final pipeline = _FakePipeline(container.read(_refProbe));
    final svc = service(pipeline, missing: {'/lights/L_0002.fits'});

    final started = await svc.start(92);
    expect(started.state, 'running');
    expect(started.total, 3);
    await svc.jobFuture(92);

    expect(pipeline.calls.map((c) => c.id), [early, last]);
    expect(pipeline.calls.every((c) => c.sessionId == 92), isTrue);

    final done = svc.progress(92)!;
    expect(done.state, 'completed');
    expect(done.done, 3);
    expect(done.processed, 2);
    expect(done.failed, 1);
    expect(done.failures.single.capturedImageId, missing);
    expect(done.failures.single.reason, contains('File not found'));
    expect(done.lastError, contains('L_0002.fits'));
    expect(done.currentFile, isNull);
    expect(done.toJson()['finishedAt'], isNotNull);
  });

  test('frames that already have science results are skipped unless '
      'forced', () async {
    final processed = await frame('L_0001.fits', minute: 1);
    final fresh = await frame('L_0002.fits', minute: 2);
    await db.scienceDao.replaceFrameQualityMetricsForImage(
      processed,
      ScienceFrameQualityMetricsCompanion.insert(
        capturedImageId: Value(processed),
        sessionId: const Value(92),
      ),
    );

    var pipeline = _FakePipeline(container.read(_refProbe));
    var svc = service(pipeline);
    final first = await svc.start(92);
    await svc.jobFuture(92);
    expect(first.total, 1);
    expect(first.alreadyProcessed, 1);
    expect(pipeline.calls.map((c) => c.id), [fresh]);

    pipeline = _FakePipeline(container.read(_refProbe));
    svc = service(pipeline);
    final forced = await svc.start(92, force: true);
    await svc.jobFuture(92);
    expect(forced.total, 2);
    expect(pipeline.calls.map((c) => c.id), [processed, fresh]);
  });

  test('a pipeline failure is counted with its reason and the walk goes '
      'on', () async {
    await frame('L_0001.fits', minute: 1);
    await frame('L_0002.fits', minute: 2);
    final pipeline = _FakePipeline(
      container.read(_refProbe),
      failing: {'/lights/L_0001.fits'},
    );
    final svc = service(pipeline);
    await svc.start(92);
    await svc.jobFuture(92);

    final p = svc.progress(92)!;
    expect(p.failed, 1);
    expect(p.processed, 1);
    expect(p.lastError, 'no stars');
    expect(pipeline.calls, hasLength(2));
  });

  test('starting while a job runs returns the running job', () async {
    await frame('L_0001.fits', minute: 1);
    final gate = Completer<void>();
    final pipeline = _FakePipeline(container.read(_refProbe), gate: gate);
    final svc = service(pipeline);

    final first = await svc.start(92);
    await Future<void>.delayed(Duration.zero);
    final second = await svc.start(92, force: true);
    expect(second.jobId, first.jobId);
    expect(svc.progress(92)!.currentFile, '/lights/L_0001.fits');

    gate.complete();
    await svc.jobFuture(92);
    expect(pipeline.calls, hasLength(1));
  });

  test('no job has run for a session: no progress', () {
    final svc = service(_FakePipeline(container.read(_refProbe)));
    expect(svc.progress(92), isNull);
  });

  test('replacing a frame\'s science rows twice keeps one set', () async {
    final id = await frame('L_0001.fits', minute: 1);
    final dao = db.scienceDao;
    for (var pass = 0; pass < 2; pass++) {
      await dao.replaceFrameQualityMetricsForImage(
        id,
        ScienceFrameQualityMetricsCompanion.insert(
          capturedImageId: Value(id),
          sessionId: const Value(92),
        ),
      );
      await dao.replacePsfTilesForImage(id, [
        for (var r = 0; r < 2; r++)
          PsfFieldTilesCompanion.insert(
            capturedImageId: Value(id),
            sessionId: const Value(92),
            tileRow: r,
            tileCol: 0,
          ),
      ]);
      await dao.replaceFrameCalibrationForImage(
        id,
        FramePhotometricCalibrationCompanion.insert(
          capturedImageId: Value(id),
          sessionId: const Value(92),
          zeroPoint: const Value(21.3),
        ),
      );
    }
    expect(await dao.getFrameQualityMetricsForSession(92), hasLength(1));
    expect(await dao.getPsfTilesForSession(92), hasLength(2));
    expect(await dao.getCalibrationsForSession(92), hasLength(1));
    expect(await dao.getCapturedImageIdsWithScience(92), {id});
  });
}

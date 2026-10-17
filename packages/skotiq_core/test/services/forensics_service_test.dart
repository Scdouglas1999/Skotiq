/// Frame-Failure Forensics: ForensicsService unit tests.
///
/// Exercises the DB round-trip path (persist + read back the same
/// record) and the cause-aggregation summary path.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ForensicsService service;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    service = ForensicsService(db);
  });

  tearDown(() async {
    await service.dispose();
    await db.close();
  });

  test(
    'LikelyCauseExt.fromLabel maps every wire label and rejects unknowns',
    () {
      for (final cause in LikelyCause.values) {
        expect(
          LikelyCauseExt.fromLabel(cause.label),
          cause,
          reason: 'round-trip label "${cause.label}"',
        );
      }
      expect(LikelyCauseExt.fromLabel('not_a_real_cause'), isNull);
      expect(LikelyCauseExt.fromLabel(null), isNull);
    },
  );

  test('record + load round-trip preserves every forensic field', () async {
    final inserted = await service.recordRejection(
      sessionId: 'session-abc',
      sequenceRunId: 42,
      nodeId: 'node-7',
      frameIndex: 3,
      totalFrames: 10,
      rejectPath: '/captures/Reject/m31_L_0003.fits',
      reason: 'HFR 5.21 px exceeds absolute threshold 3.50 px',
      causeLabel: 'cloud_passage',
      evidence: const <String>[
        'Sky brightness dropped 0.70 mag in last 60s',
        'Cloud cover spiked from 12% to 78%',
        '8 other frames in same window also rejected',
      ],
      environment: const ForensicEnvironment(
        skyBrightnessMag: 20.5,
        cloudCoverPercent: 78.0,
        windKph: 12.5,
        guideRmsArcsec: 0.85,
        sensorTempC: -10.0,
      ),
      hfr: 5.21,
      eccentricity: 0.61,
      starCount: 15,
    );

    expect(inserted.likelyCause, LikelyCause.cloudPassage);
    expect(inserted.evidence, hasLength(3));
    expect(inserted.environment.cloudCoverPercent, closeTo(78.0, 1e-9));

    final loaded = await service.loadRecentForSession('session-abc');
    expect(loaded, hasLength(1));
    final r = loaded.first;
    expect(r.id, inserted.id);
    expect(r.likelyCause, LikelyCause.cloudPassage);
    expect(r.evidence, [
      'Sky brightness dropped 0.70 mag in last 60s',
      'Cloud cover spiked from 12% to 78%',
      '8 other frames in same window also rejected',
    ]);
    expect(r.environment.skyBrightnessMag, closeTo(20.5, 1e-9));
    expect(r.environment.cloudCoverPercent, closeTo(78.0, 1e-9));
    expect(r.environment.windKph, closeTo(12.5, 1e-9));
    expect(r.environment.guideRmsArcsec, closeTo(0.85, 1e-9));
    expect(r.environment.sensorTempC, closeTo(-10.0, 1e-9));
    expect(r.hfr, closeTo(5.21, 1e-9));
    expect(r.eccentricity, closeTo(0.61, 1e-9));
    expect(r.starCount, 15);
    expect(r.frameIndex, 3);
    expect(r.totalFrames, 10);
    expect(r.nodeId, 'node-7');
    expect(r.sequenceRunId, 42);
    expect(r.rejectPath, '/captures/Reject/m31_L_0003.fits');
  });

  test('null cause label defaults to unknown', () async {
    final r = await service.recordRejection(
      sessionId: 's',
      frameIndex: 1,
      totalFrames: 1,
      rejectPath: '/x',
      reason: 'r',
      causeLabel: null,
    );
    expect(r.likelyCause, LikelyCause.unknown);
  });

  test('loadByCause filters correctly', () async {
    for (final cause in [
      LikelyCause.cloudPassage,
      LikelyCause.cloudPassage,
      LikelyCause.seeingSpike,
      LikelyCause.focusDrift,
    ]) {
      await service.recordRejection(
        sessionId: 's',
        sequenceRunId: 1,
        frameIndex: 1,
        totalFrames: 10,
        rejectPath: '/x',
        reason: 'r',
        causeLabel: cause.label,
      );
    }
    final cloud = await service.loadByCause(
      LikelyCause.cloudPassage,
      sequenceRunId: 1,
    );
    expect(cloud, hasLength(2));
    final seeing = await service.loadByCause(
      LikelyCause.seeingSpike,
      sequenceRunId: 1,
    );
    expect(seeing, hasLength(1));
    final focus = await service.loadByCause(
      LikelyCause.focusDrift,
      sequenceRunId: 1,
    );
    expect(focus, hasLength(1));
  });

  test('summarize groups by cause and ranks descending', () async {
    final records = <FrameForensicsRecord>[];
    for (final cause in [
      LikelyCause.cloudPassage,
      LikelyCause.cloudPassage,
      LikelyCause.cloudPassage,
      LikelyCause.seeingSpike,
      LikelyCause.focusDrift,
      LikelyCause.focusDrift,
    ]) {
      records.add(
        await service.recordRejection(
          sessionId: 's',
          sequenceRunId: 9,
          frameIndex: 1,
          totalFrames: 10,
          rejectPath: '/x',
          reason: 'r',
          causeLabel: cause.label,
        ),
      );
    }
    final summary = ForensicsService.summarize(records);
    expect(summary.total, 6);
    expect(summary.countsByCause[LikelyCause.cloudPassage], 3);
    expect(summary.countsByCause[LikelyCause.focusDrift], 2);
    expect(summary.countsByCause[LikelyCause.seeingSpike], 1);
    final ranked = summary.rankedCauses;
    expect(ranked.first.key, LikelyCause.cloudPassage);
    expect(ranked.first.value, 3);
    expect(ranked.last.value, lessThanOrEqualTo(ranked.first.value));
  });

  test('broadcast stream emits a record after recordRejection', () async {
    final received = <FrameForensicsRecord>[];
    final sub = service.stream.listen(received.add);
    await service.recordRejection(
      sessionId: 's',
      frameIndex: 1,
      totalFrames: 5,
      rejectPath: '/x',
      reason: 'r',
      causeLabel: LikelyCause.seeingSpike.label,
    );
    // Wait one microtask for the broadcast to deliver.
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received.first.likelyCause, LikelyCause.seeingSpike);
    await sub.cancel();
  });

  test('empty environment serialises and deserialises cleanly', () async {
    final r = await service.recordRejection(
      sessionId: 's',
      frameIndex: 1,
      totalFrames: 1,
      rejectPath: '/x',
      reason: 'r',
      causeLabel: 'unknown',
      // environment defaults to const ForensicEnvironment() — all nulls.
    );
    expect(r.environment.isEmpty, isTrue);
    final loaded = await service.loadRecentForSession('s');
    expect(loaded.first.environment.isEmpty, isTrue);
  });

  test(
    'cause column stores the wire-stable label, not the display name',
    () async {
      await service.recordRejection(
        sessionId: 's',
        frameIndex: 1,
        totalFrames: 1,
        rejectPath: '/x',
        reason: 'r',
        causeLabel: 'wind_gust',
      );
      final rows = await db
          .customSelect(
            'SELECT likely_cause FROM frame_forensics',
            variables: const <Variable<Object>>[],
          )
          .get();
      expect(rows, hasLength(1));
      expect(rows.first.data['likely_cause'], 'wind_gust');
    },
  );
}

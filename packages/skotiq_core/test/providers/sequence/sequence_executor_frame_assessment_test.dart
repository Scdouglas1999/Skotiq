// The run record of a night is built from the grader's verdicts and the frame
// watch's later assessment of each frame. Run 37 (2026-10-23/24) recorded
// 192 frames with 49 rejects, yet its session row read 192 successful, 0
// failed, no autofocus and no guide RMS, and no frame carried its solve.
// These tests replay that night's counts through the executor's event path.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

const _nodeId = 'lights-node';

bridge_event.SkotiqEvent _event(String type, Map<String, dynamic> data) =>
    bridge_event.SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: bridge_event.EventSeverity.info,
      category: bridge_event.EventCategory.sequencer,
      eventType: type,
      data: data,
    );

bridge_event.SkotiqEvent _graded({
  required String path,
  required String filter,
  required double secs,
  required bool accepted,
}) => _event(accepted ? 'FrameAccepted' : 'FrameRejected', {
  'node_id': _nodeId,
  'filter': filter,
  'hfr': 2.3,
  'star_count': 900,
  'exposure_secs': secs,
  if (accepted) 'save_path': path else 'reject_path': path,
  if (!accepted) 'reason': 'eccentricity 0.84 exceeds threshold 0.80',
});

bridge_event.SkotiqEvent _assessed(Map<String, Object?> detail) =>
    _event('InstructionProgressStructured', {
      'node_id': _nodeId,
      'instruction': 'Frame watch',
      'progress_percent': 100.0,
      'detail_kind': frameAssessedDetailKind,
      'detail_json': jsonEncode(detail),
    });

bridge_event.SkotiqEvent _autofocus(String nodeId) =>
    _event('InstructionProgressStructured', {
      'node_id': nodeId,
      'instruction': 'Autofocus',
      'progress_percent': 100.0,
      'detail_kind': 'Autofocus',
      'detail_json': jsonEncode({'step': 9, 'total_steps': 9}),
    });

/// Run 37's frames per filter: (count, rejected, exposure seconds).
const _run37 = <String, (int, int, double)>{
  'L': (48, 10, 90),
  'R': (48, 17, 120),
  'G': (48, 14, 120),
  'B': (48, 8, 120),
};

String _path(String filter, int i, {required bool accepted}) => accepted
    ? '/captures/NGC0891/${filter}_$i.fits'
    : '/captures/NGC0891/Reject/${filter}_$i.fits';

void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  (ProviderContainer, SequenceExecutor) build() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(liveSequenceStatsProvider.notifier).state =
        SequenceRunStats();
    return (container, container.read(sequenceExecutorProvider));
  }

  Future<void> settle() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Pump run 37's 192 graded frames and seven autofocus sweeps.
  void pumpRun37(SequenceExecutor executor) {
    for (final entry in _run37.entries) {
      final (count, rejected, secs) = entry.value;
      for (var i = 0; i < count; i++) {
        final accepted = i >= rejected;
        executor.handleSequencerEventForTest(
          _graded(
            path: _path(entry.key, i, accepted: accepted),
            filter: entry.key,
            secs: secs,
            accepted: accepted,
          ),
        );
      }
    }
    for (var i = 0; i < 7; i++) {
      final node = 'trigger:af-interval:autofocus-$i';
      executor.handleSequencerEventForTest(_autofocus(node));
      executor.handleSequencerEventForTest(
        _event('NodeCompleted', {'node_id': node, 'status': 'success'}),
      );
    }
  }

  test('the session row counts run 37 the way the run stats do', () async {
    final (container, executor) = build();
    final session = container.read(sessionStateProvider.notifier);
    await session.startSession(targetName: 'NGC0891');
    final sessionId = container.read(sessionStateProvider).dbSessionId!;

    pumpRun37(executor);
    await settle();
    await session.endSession(status: 'aborted');
    await settle();

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(stats.framesCaptured, 192);
    expect(stats.framesRejected, 49);
    expect(stats.integrationSecs, closeTo(16020, 1e-6));
    expect(stats.autofocusRuns, 7);

    final row = (await db.sessionsDao.getSessionById(sessionId))!;
    expect(row.totalExposures, 192);
    expect(row.successfulExposures, 143);
    expect(row.failedExposures, 49);
    expect(row.totalIntegrationSecs, closeTo(16020, 1e-6));
    expect(row.autofocusCount, 7);
  });

  test('an excluded frame leaves integration in the stats, the session and '
      'its row; the rest of the assessment lands on the rows', () async {
    final (container, executor) = build();
    final session = container.read(sessionStateProvider.notifier);
    await session.startSession(targetName: 'NGC0891');
    final sessionId = container.read(sessionStateProvider).dbSessionId!;

    pumpRun37(executor);
    // Every accepted frame reports its guide RMS: half at 0.8, half at 1.2.
    var n = 0;
    for (final entry in _run37.entries) {
      final (count, rejected, secs) = entry.value;
      for (var i = rejected; i < count; i++) {
        final obstructed = entry.key == 'B' && i >= count - 5;
        executor.handleSequencerEventForTest(
          _assessed({
            'save_path': _path(entry.key, i, accepted: true),
            'filter': entry.key,
            'exposure_secs': secs,
            'was_accepted': true,
            'solve_attempted': true,
            'plate_solved': true,
            'solved_ra_deg': 35.639,
            'solved_dec_deg': 42.349,
            'solved_rotation_deg': 12.5,
            'solved_pixel_scale': 1.12,
            'offset_arcmin': 0.4,
            'guide_rms_total': (n++).isEven ? 0.8 : 1.2,
            'guide_rms_samples': 40,
            'background_adu': 812.0,
            'star_count': obstructed ? 120 : 900,
            'altitude_deg': 64.0,
            'azimuth_deg': 286.0,
            'pier_side': 'East',
            'off_target': false,
            'obstructed': obstructed,
            'exclusion_reason': obstructed
                ? '$frameExclusionObstructedPrefix star count fell to 13% '
                      'with the sky background unchanged'
                : null,
          }),
        );
      }
    }
    await settle();
    await session.endSession(status: 'aborted');
    await settle();

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(stats.framesRejected, 54);
    expect(stats.integrationSecs, closeTo(16020 - 5 * 120, 1e-6));
    final blue = stats.targetBreakdown.values.single['B']!;
    expect(blue.rejected, 13);
    expect(blue.integrationSecs, closeTo(4800 - 600, 1e-6));

    final row = (await db.sessionsDao.getSessionById(sessionId))!;
    expect(row.totalExposures, 192);
    expect(row.successfulExposures, 138);
    expect(row.failedExposures, 54);
    expect(row.totalIntegrationSecs, closeTo(15420, 1e-6));
    // 143 frames reported guide RMS: 72 at 0.8 and 71 at 1.2.
    expect(row.avgGuidingRms, closeTo((72 * 0.8 + 71 * 1.2) / 143, 1e-9));

    final obstructedRow = (await db.imagesDao.getLatestImageByFilePath(
      _path('B', 47, accepted: true),
    ))!;
    expect(obstructedRow.isAccepted, isFalse);
    expect(
      frameExclusionKindOf(obstructedRow.rejectionReason),
      FrameExclusionKind.obstructed,
    );

    final keptRow = (await db.imagesDao.getLatestImageByFilePath(
      _path('L', 20, accepted: true),
    ))!;
    expect(keptRow.isAccepted, isTrue);
    expect(keptRow.isPlateSolved, isTrue);
    // Rows keep RA in hours.
    expect(keptRow.solvedRa, closeTo(35.639 / 15, 1e-9));
    expect(keptRow.solvedDec, closeTo(42.349, 1e-9));
    expect(keptRow.solvedPixelScale, closeTo(1.12, 1e-9));
    expect(keptRow.background, closeTo(812, 1e-9));
    expect(
      keptRow.guidingRmsTotal,
      anyOf(closeTo(0.8, 1e-9), closeTo(1.2, 1e-9)),
    );
  });

  test('an exclusion of a graded reject keeps its grader reason and moves no '
      'count', () async {
    final (container, executor) = build();
    const path = '/captures/NGC0891/Reject/R_3.fits';
    executor.handleSequencerEventForTest(
      _graded(path: path, filter: 'R', secs: 120, accepted: false),
    );
    executor.handleSequencerEventForTest(
      _assessed({
        'save_path': path,
        'was_accepted': false,
        'solve_attempted': true,
        'plate_solved': false,
        'off_target': true,
        'obstructed': false,
        'exclusion_reason':
            '$frameExclusionOffTargetPrefix 31.6 arcmin from '
            'NGC 891',
      }),
    );
    await settle();

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(stats.framesRejected, 1);
    final row = (await db.imagesDao.getLatestImageByFilePath(path))!;
    expect(row.isAccepted, isFalse);
    expect(row.isPlateSolved, isFalse);
    expect(
      row.rejectionReason,
      'eccentricity 0.84 exceeds threshold 0.80; '
      '$frameExclusionOffTargetPrefix 31.6 arcmin from NGC 891',
    );
    expect(
      frameExclusionKindOf(row.rejectionReason),
      FrameExclusionKind.offTarget,
    );
  });

  test('an assessment for a frame with no row is logged, not dropped '
      'silently', () async {
    final (container, executor) = build();
    final messages = <String>[];
    final sub = container
        .read(loggingServiceProvider)
        .logEntryStream
        .listen((e) => messages.add(e.message));
    addTearDown(sub.cancel);
    executor.handleSequencerEventForTest(
      _assessed({
        'save_path': '/captures/never/recorded.fits',
        'was_accepted': true,
        'solve_attempted': false,
        'plate_solved': false,
        'off_target': false,
        'obstructed': false,
      }),
    );
    await settle();
    expect(
      messages.any((m) => m.contains('matched no recorded frame')),
      isTrue,
    );
  });

  test('a confirmed obstruction is learned for the run\'s site', () async {
    final (container, executor) = build();
    await container.read(frameWatchSettingsProvider.future);
    executor.handleSequencerEventForTest(
      _event('InstructionProgressStructured', {
        'node_id': _nodeId,
        'instruction': 'Frame watch',
        'progress_percent': 100.0,
        'detail_kind': horizonObstructionDetailKind,
        'detail_json': jsonEncode({
          'altitude_deg': 64.0,
          'azimuth_deg': 286.2,
          'target_name': 'NGC 891',
          'latitude': 43.1,
          'longitude': -77.6,
          'verdict': 'obstruction',
          'action': 'next_target',
          'message': 'Trees at alt 64.0 deg, az 286.2 deg. Moving on.',
        }),
      }),
    );
    await settle();

    final settings = container.read(frameWatchSettingsProvider).value!;
    final points = settings.pointsForSite(43.12, -77.58);
    expect(points, hasLength(1));
    expect(points.single.azimuthDeg, closeTo(286.2, 1e-9));
    expect(points.single.targetName, 'NGC 891');
    expect(settings.pointsForSite(44.0, -77.6), isEmpty);
    expect(
      container.read(liveSequenceStatsProvider)!.warningMessages,
      contains('Trees at alt 64.0 deg, az 286.2 deg. Moving on.'),
    );
    final stored = await db.settingsDao.getSetting(learnedHorizonPointsKey);
    expect(stored, contains('286.2'));
  });
}

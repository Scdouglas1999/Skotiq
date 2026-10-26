// Frames a sequence records go through the same per-frame science pipeline as
// manual captures. A light frame is queued once its row exists and the frame
// watch has assessed it (so its stored solve is reused); calibration frames
// are not; a failing science step never touches the frame's registration.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;
import 'package:skotiq_core/src/providers/sequence/sequence_executor/run_frame_science.dart';

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

typedef _Call = ({
  String imagePath,
  int? capturedImageId,
  int? sessionId,
  bool solveIfUnsolved,
  bool rowSolvedAtCall,
});

/// Records each frame handed to the pipeline, and what the frame's row held
/// at that moment.
class _RecordingScience extends ScienceProcessingService {
  _RecordingScience(super.ref, this.db, {this.fail = false});

  final SkotiqDatabase db;
  final bool fail;
  final calls = <_Call>[];

  @override
  Future<ScienceFrameOutcome> processFrame({
    required String imagePath,
    String? deviceId,
    int? capturedImageId,
    int? sessionId,
    bool solveIfUnsolved = true,
  }) async {
    final row = capturedImageId == null
        ? null
        : await ImagesDao(db).getImageById(capturedImageId);
    calls.add((
      imagePath: imagePath,
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      solveIfUnsolved: solveIfUnsolved,
      rowSolvedAtCall: row?.isPlateSolved ?? false,
    ));
    if (fail) throw StateError('science backend exploded');
    return const ScienceFrameOutcome.processed();
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

bridge_event.SkotiqEvent _accepted(String path, {String? frameType}) =>
    _event('FrameAccepted', {
      'node_id': _nodeId,
      'frame': 1,
      'filter': 'L',
      'hfr': 2.3,
      'star_count': 900,
      'exposure_secs': 120.0,
      'save_path': path,
      if (frameType != null) 'frame_type': frameType,
    });

bridge_event.SkotiqEvent _assessed(
  String path, {
  required bool solveAttempted,
  required bool solved,
}) => _event('InstructionProgressStructured', {
  'node_id': _nodeId,
  'instruction': 'Frame watch',
  'progress_percent': 100.0,
  'detail_kind': frameAssessedDetailKind,
  'detail_json': jsonEncode({
    'save_path': path,
    'filter': 'L',
    'exposure_secs': 120,
    'was_accepted': true,
    'solve_attempted': solveAttempted,
    'plate_solved': solved,
    if (solved) 'solved_ra_deg': 35.64,
    if (solved) 'solved_dec_deg': 42.35,
    if (solved) 'solved_rotation_deg': 12.0,
    if (solved) 'solved_pixel_scale': 1.12,
    'off_target': false,
    'obstructed': false,
  }),
});

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

  (SequenceExecutor, _RecordingScience) build({bool fail = false}) {
    late _RecordingScience science;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        scienceProcessingServiceProvider.overrideWith(
          (ref) => science = _RecordingScience(ref, db, fail: fail),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(liveSequenceStatsProvider.notifier).state =
        SequenceRunStats();
    container.read(scienceProcessingServiceProvider);
    return (container.read(sequenceExecutorProvider), science);
  }

  Future<void> settle() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('a light frame is processed after the frame watch solved it, '
      'reusing the stored solve', () async {
    final (executor, science) = build();
    const path = '/captures/NGC0891/L_0001.fits';

    executor.handleSequencerEventForTest(_accepted(path));
    await settle();
    expect(
      science.calls,
      isEmpty,
      reason: 'science waits for the frame watch so it does not solve twice',
    );

    executor.handleSequencerEventForTest(
      _assessed(path, solveAttempted: true, solved: true),
    );
    await settle();

    final row = await ImagesDao(db).getLatestImageByFilePath(path);
    expect(row, isNotNull);
    expect(science.calls, hasLength(1));
    final call = science.calls.single;
    expect(call.imagePath, path);
    expect(call.capturedImageId, row!.id);
    expect(call.rowSolvedAtCall, isTrue);
    expect(call.solveIfUnsolved, isTrue);
  });

  test('a frame whose frame-watch solve failed is not solved again', () async {
    final (executor, science) = build();
    const path = '/captures/NGC0891/L_0002.fits';

    executor.handleSequencerEventForTest(_accepted(path));
    executor.handleSequencerEventForTest(
      _assessed(path, solveAttempted: true, solved: false),
    );
    await settle();

    expect(science.calls, hasLength(1));
    expect(science.calls.single.solveIfUnsolved, isFalse);
  });

  test('a dark frame is not sent to the science pipeline', () async {
    final (executor, science) = build();
    const path = '/captures/darks/D_0001.fits';

    executor.handleSequencerEventForTest(_accepted(path, frameType: 'Dark'));
    executor.handleSequencerEventForTest(
      _assessed(path, solveAttempted: false, solved: false),
    );
    await settle();

    final row = await ImagesDao(db).getLatestImageByFilePath(path);
    expect(row?.frameType, 'dark');
    expect(science.calls, isEmpty);
  });

  test('a failing science step leaves the frame registered', () async {
    final (executor, science) = build(fail: true);
    const path = '/captures/NGC0891/L_0003.fits';

    executor.handleSequencerEventForTest(_accepted(path));
    executor.handleSequencerEventForTest(
      _assessed(path, solveAttempted: true, solved: true),
    );
    await settle();

    expect(science.calls, hasLength(1));
    final row = await ImagesDao(db).getLatestImageByFilePath(path);
    expect(row, isNotNull);
    expect(row!.isAccepted, isTrue);
    expect(row.isPlateSolved, isTrue);
  });

  test('without an assessment the frame is processed after the wait and '
      'may be solved by the pipeline', () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final feed = RunFrameScience(
      logger: () => container.read(loggingServiceProvider),
      assessmentWait: (_) => const Duration(milliseconds: 30),
    );
    final science = _RecordingScience(container.read(_refProbe), db);

    final assessment = feed.expectAssessment('/f.fits', 60);
    final done = feed.queue(
      science: science,
      assessment: assessment,
      filePath: '/f.fits',
      capturedImageId: 7,
      sessionId: 3,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(science.calls, isEmpty);
    await done;
    expect(science.calls.single.solveIfUnsolved, isTrue);
    expect(science.calls.single.sessionId, 3);
  });

  test('the assessment wait covers two long exposures', () {
    expect(
      RunFrameScience.defaultAssessmentWait(null),
      const Duration(seconds: 120),
    );
    expect(
      RunFrameScience.defaultAssessmentWait(300),
      const Duration(seconds: 900),
    );
  });
}

/// A [Ref] for constructing a service outside a provider.
final _refProbe = Provider<Ref>((ref) => ref);

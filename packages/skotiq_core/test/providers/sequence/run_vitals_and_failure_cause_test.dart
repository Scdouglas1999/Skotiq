import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    as backend_events;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _ConnectedCameraNotifier extends CameraStateNotifier {
  _ConnectedCameraNotifier(super.ref) {
    setConnecting(_cameraId, 'Test Camera');
    setConnected();
  }
}

const _cameraId = 'simulator:test-camera-1';

/// What a run that captured and rejected frames reports about itself, and what
/// a run that failed says the reason was.
///
/// Both questions were answered wrongly on the owner's rig on the night of
/// 2026-09-14/15, on the same run:
///
///  * `GET /api/sequencer/status` returned `framesCaptured: 0,
///    framesRejected: 0` for ten minutes while the grader logged "Accepted so
///    far: 0, rejected: 3" and wrote three FITS into a Reject folder. The
///    counters moved only on `ExposureCompleted`, which the executor
///    synthesises for `TakeExposure` nodes and for advancing frame indices —
///    and the run was a Smart Exposure node whose delegated single-frame
///    bursts report frame 1 of 1 over and over, so not one was ever emitted.
///
///  * The only failure the operator was shown was "Change Filter: Operation
///    cancelled" — the filter wheel's wait loop noticing the cancellation
///    token one second after recovery had already abandoned the run.
void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<backend_events.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  setUp(() {
    backend = MockBackend();
    eventController =
        StreamController<backend_events.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.cameraGetLastImage(any())).thenAnswer((_) async => null);
    when(
      () => backend.getLastRawImageData(any()),
    ).thenAnswer((_) async => <int>[]);
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  (ProviderContainer, SequenceExecutor) build({Sequence? sequence}) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(liveSequenceStatsProvider.notifier).state =
        SequenceRunStats();
    if (sequence != null) {
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(sequence, discardUnsaved: true);
    }
    return (container, container.read(sequenceExecutorProvider));
  }

  backend_events.SkotiqEvent sequencerEvent(
    String type,
    Map<String, dynamic> data,
  ) => backend_events.SkotiqEvent(
    timestamp: DateTime.now().microsecondsSinceEpoch,
    severity: backend_events.EventSeverity.info,
    category: backend_events.EventCategory.sequencer,
    eventType: type,
    data: data,
  );

  /// The shape of the owner's sequence: a Smart Exposure node under a target,
  /// cycling Ha / SII / OIII.
  Sequence smartExposureSequence() {
    final smart = SmartExposureNode(
      id: 'smart1',
      name: 'Smart Exposure',
      parentId: 'target1',
      plans: const [
        FilterPlan(filterName: 'Ha', durationSecs: 180, count: 1),
        FilterPlan(filterName: 'SII', durationSecs: 180, count: 1),
        FilterPlan(filterName: 'OIII', durationSecs: 180, count: 1),
      ],
    );
    final target = TargetHeaderNode(
      id: 'target1',
      name: 'Target',
      targetName: 'NGC7380',
      raHours: 22.79,
      decDegrees: 58.13,
      childIds: const ['smart1'],
    );
    return Sequence.create(
      name: 'Night',
      rootNodeId: 'target1',
      nodes: {'target1': target, 'smart1': smart},
    );
  }

  /// One rejected frame off a Smart Exposure burst. The frame index is 1 every
  /// time because each batch is one frame of one.
  Map<String, dynamic> rejectedFrame(String filter, int index) =>
      <String, dynamic>{
        'node_id': 'smart1',
        'frame': 1,
        'total': 1,
        'exposure_secs': 180.0,
        'gain': 120,
        'offset': 30,
        'bin_x': 2,
        'bin_y': 2,
        'frame_type': 'Light',
        'reason': 'HFR 15.61 px exceeds absolute threshold 3.50 px',
        'reject_path':
            r'C:\Images\NGC7380\Reject\NGC7380_' + filter + '_000$index.fits',
      };

  group('a run that captured and rejected frames says so', () {
    test(
      'three rejects with no ExposureCompleted still count as three captured',
      () async {
        final (container, executor) = build(sequence: smartExposureSequence());

        executor.handleSequencerEventForTest(
          sequencerEvent('NodeStarted', {
            'node_id': 'smart1',
            'node_type': 'Smart Exposure',
          }),
        );
        // A Smart Exposure node emits no ExposureCompleted at all: it is absent
        // from the executor's `exposure_node_metadata`, and its frame index
        // never advances past 1. Only the grader's verdicts arrive.
        for (final (i, filter) in ['Ha', 'SII', 'OIII'].indexed) {
          executor.handleSequencerEventForTest(
            sequencerEvent('FrameRejected', rejectedFrame(filter, i + 1)),
          );
        }
        await pumpEventQueue();

        final stats = container.read(liveSequenceStatsProvider)!;
        expect(
          stats.framesCaptured,
          3,
          reason:
              'three frames came off the sensor and are on disk; a run that '
              'reports 0 tells a remote operator it is idle',
        );
        expect(
          stats.framesRejected,
          3,
          reason: 'the grader rejected all three and logged exactly that',
        );
        expect(stats.integrationSecs, 0.0, reason: 'none of it is usable data');
      },
    );

    test('the reject folder reaches the run record', () async {
      final (container, executor) = build(sequence: smartExposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'smart1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameRejected', rejectedFrame('OIII', 1)),
      );
      await pumpEventQueue();

      expect(
        container.read(liveSequenceStatsProvider)!.rejectFolder,
        r'C:\Images\NGC7380\Reject',
        reason:
            'the folder is the first thing an operator opens after a reject '
            'storm',
      );
    });

    test('a healthy run names no reject folder and no cause', () async {
      final (container, executor) = build(sequence: smartExposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'smart1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameAccepted', {
          'node_id': 'smart1',
          'frame': 1,
          'total': 1,
          'exposure_secs': 180.0,
          'save_path': r'C:\Images\NGC7380\NGC7380_Ha_0001.fits',
        }),
      );
      await pumpEventQueue();

      final stats = container.read(liveSequenceStatsProvider)!;
      expect(stats.framesCaptured, 1);
      expect(stats.framesRejected, 0);
      expect(stats.integrationSecs, 180.0);
      expect(stats.rejectFolder, isNull);
      expect(stats.terminalCause, isNull);
    });
  });

  group('a failed run reports its cause, not its teardown', () {
    // The native executor chooses the cause (see
    // `native/skotiq_native/sequencer/src/executor/failure_cause.rs`) and
    // ships it on `SequenceFailed.error`. What is asserted here is that the
    // Dart side files it AS the cause, and does not print it twice because the
    // cascade already recorded it.
    const rejectStorm =
        'Image grading: 3 consecutive rejects (limit 3). Sequence paused for '
        'inspection. Frame 1/1, last reason: HFR 15.61 px exceeds absolute '
        r'threshold 3.50 px. Most recent reject: C:\Images\NGC7380\Reject'
        r'\NGC7380_OIII_0001.fits. Accepted so far: 0, rejected: 3.';

    test('the cause is the fault, and the cascade is kept behind it', () async {
      final (container, executor) = build(sequence: smartExposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'smart1'}),
      );
      // The cascade as the run reported it, in order.
      executor.handleSequencerEventForTest(
        sequencerEvent('Error', {'message': rejectStorm}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('Error', {
          'message': 'Change Filter failed: Operation cancelled',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('SequenceFailed', {'error': rejectStorm}),
      );
      await pumpEventQueue();

      final stats = container.read(liveSequenceStatsProvider)!;
      expect(
        stats.terminalCause,
        rejectStorm,
        reason: 'the reason must be the fault that ended the run',
      );
      expect(
        stats.terminalCause,
        isNot(contains('Operation cancelled')),
        reason:
            'an operation cancelled because the run was already failing is '
            'never the failure reason',
      );
      expect(
        stats.errorMessages,
        [rejectStorm, 'Change Filter failed: Operation cancelled'],
        reason:
            'the whole cascade stays available underneath the cause, in the '
            'order it happened',
      );
    });

    test(
      'the terminal reason is not printed twice when the cascade already holds it',
      () async {
        final (container, executor) = build(sequence: smartExposureSequence());

        executor.handleSequencerEventForTest(
          sequencerEvent('Error', {'message': rejectStorm}),
        );
        executor.handleSequencerEventForTest(
          sequencerEvent('Error', {
            'message': 'Change Filter failed: Operation cancelled',
          }),
        );
        executor.handleSequencerEventForTest(
          sequencerEvent('SequenceFailed', {'error': rejectStorm}),
        );
        await pumpEventQueue();

        final errors = container.read(liveSequenceStatsProvider)!.errorMessages;
        expect(
          errors.where((e) => e == rejectStorm).length,
          1,
          reason:
              'the cause is now the FIRST fault, so there are later entries '
              'behind it — comparing only the last entry would append it again '
              'and stack two identical critical banners',
        );
      },
    );

    test(
      'a failure with no known reason files no cause, not the placeholder',
      () async {
        final (container, executor) = build(sequence: smartExposureSequence());

        executor.handleSequencerEventForTest(
          sequencerEvent('Error', {
            'message': 'Change Filter failed: Operation cancelled',
          }),
        );
        // The native executor sends this literal when it found no fault to
        // blame (only cancellations survived). It is a placeholder, not a
        // reason, and must not be headlined under "Why it ended".
        executor.handleSequencerEventForTest(
          sequencerEvent('SequenceFailed', {'error': 'Sequence failed'}),
        );
        await pumpEventQueue();

        expect(
          container.read(liveSequenceStatsProvider)!.terminalCause,
          isNull,
          reason: 'a placeholder is not a cause',
        );
      },
    );

    test('a SequenceFailed with no error field files no cause', () async {
      final (container, executor) = build(sequence: smartExposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('SequenceFailed', <String, dynamic>{}),
      );
      await pumpEventQueue();

      expect(container.read(liveSequenceStatsProvider)!.terminalCause, isNull);
    });

    test('a node that really fails twice still records two errors', () {
      final stats = SequenceRunStats();
      stats.recordError('Slew failed: mount reported a limit');
      stats.recordError('Center failed: no solve');
      stats.recordError('Slew failed: mount reported a limit');

      expect(
        stats.errorMessages.length,
        3,
        reason:
            'only the TERMINAL reason is a restatement; real faults are not '
            'deduplicated',
      );
    });
  });

  group('a rig path is read with the rig\'s separator', () {
    // `package:path`'s dirname resolves against the LOCAL platform, so a
    // Windows reject path read on Linux came back as `.` — which would point
    // the operator at the app's working directory instead of his images.
    test('a Windows path keeps its Windows folder', () {
      expect(
        parentDirectoryOf(r'C:\Images\NGC7380\Reject\NGC7380_OIII_0001.fits'),
        r'C:\Images\NGC7380\Reject',
      );
    });

    test('a POSIX path keeps its POSIX folder', () {
      expect(
        parentDirectoryOf('/home/rig/Images/NGC7380/Reject/f_0001.fits'),
        '/home/rig/Images/NGC7380/Reject',
      );
      expect(
        parentDirectoryOf('/f_0001.fits'),
        '/',
        reason: 'a file at the root lives in the root',
      );
    });

    test('a bare filename names no folder rather than the CWD', () {
      expect(parentDirectoryOf('f_0001.fits'), isNull);
      expect(parentDirectoryOf(''), isNull);
    });
  });

  group('the run record round-trips the cause and the reject folder', () {
    test('both survive serialization', () {
      final stats = SequenceRunStats();
      stats.recordFrame(
        target: 'NGC7380',
        filter: 'OIII',
        exposureSecs: 180,
        accepted: false,
      );
      stats.recordRejectFolder(r'C:\Images\NGC7380\Reject');
      stats.recordTerminalError('Image grading: 3 consecutive rejects');

      final parsed = ParsedRunStats.fromJson(stats.toJson());
      expect(parsed.framesCaptured, 1);
      expect(parsed.framesRejected, 1);
      expect(parsed.rejectFolder, r'C:\Images\NGC7380\Reject');
      expect(parsed.terminalCause, 'Image grading: 3 consecutive rejects');
    });

    test('both survive the remote run-vitals wire', () {
      final stats = SequenceRunStats();
      stats.recordFrame(
        target: 'NGC7380',
        filter: 'OIII',
        exposureSecs: 180,
        accepted: false,
      );
      stats.recordRejectFolder(r'C:\Images\NGC7380\Reject');
      stats.recordTerminalError('Image grading: 3 consecutive rejects');

      final vitals = SequencerRunVitals(
        startTime: stats.startTime,
        framesCaptured: stats.framesCaptured,
        framesRejected: stats.framesRejected,
        integrationSecs: stats.integrationSecs,
        triggerFires: stats.triggerFires,
        autofocusRuns: stats.autofocusRuns,
        meridianFlips: stats.meridianFlips,
        ditherCount: stats.ditherCount,
        errorMessages: stats.errorMessages,
        rejectFolder: stats.rejectFolder,
        terminalCause: stats.terminalCause,
      );
      final mirrored = SequenceRunStats.fromRemoteVitals(
        SequencerRunVitals.fromJson(vitals.toJson()),
      );

      expect(mirrored.framesCaptured, 1);
      expect(mirrored.framesRejected, 1);
      expect(mirrored.rejectFolder, r'C:\Images\NGC7380\Reject');
      expect(mirrored.terminalCause, 'Image grading: 3 consecutive rejects');
    });
  });
}

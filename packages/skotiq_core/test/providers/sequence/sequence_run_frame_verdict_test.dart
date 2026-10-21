import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as backend_events;

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

/// What the run record says about the frames a night actually produced.
///
/// Three claims the record must be able to make truthfully:
///
///  1. `framesRejected` counts the frames the grader rejected — the same
///     frames that carry `runtime_grade='reject'` in `captured_images`.
///  2. `ditherCount` counts the dithers that actually settled.
///  3. The preview published for a frame is stamped from that frame's own
///     capture payload, never from literals: the imaging `ExposureComplete`
///     payload carries no capture metadata, so a preview sourced from it
///     labels a 300 s sub "2 s, gain 0".
void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<backend_events.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<backend_events.SkotiqEvent>.broadcast();
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

  backend_events.SkotiqEvent event(
    backend_events.EventCategory category,
    String type,
    Map<String, dynamic> data,
  ) => backend_events.SkotiqEvent(
    timestamp: DateTime.now().microsecondsSinceEpoch,
    severity: backend_events.EventSeverity.info,
    category: category,
    eventType: type,
    data: data,
  );

  backend_events.SkotiqEvent sequencerEvent(
    String type,
    Map<String, dynamic> data,
  ) => event(backend_events.EventCategory.sequencer, type, data);

  Sequence exposureSequence() {
    final exposure = ExposureNode(
      id: 'expo1',
      name: 'Take Exposures',
      durationSecs: 300,
      count: 4,
      gain: 120,
      offset: 30,
      binning: BinningMode.two,
      parentId: 'target1',
    );
    final target = TargetHeaderNode(
      id: 'target1',
      name: 'Target',
      targetName: 'M31',
      raHours: 0,
      decDegrees: 0,
      childIds: const ['expo1'],
    );
    return Sequence.create(
      name: 'Night',
      rootNodeId: 'target1',
      nodes: {'target1': target, 'expo1': exposure},
    );
  }

  Map<String, dynamic> frameData({
    required int frame,
    double exposureSecs = 300.0,
    int gain = 120,
    int offset = 30,
    int bin = 2,
  }) => <String, dynamic>{
    'node_id': 'expo1',
    'frame': frame,
    'total': 4,
    'exposure_secs': exposureSecs,
    'gain': gain,
    'offset': offset,
    'bin_x': bin,
    'bin_y': bin,
    'frame_type': 'Light',
  };

  group('the run record counts the frames the grader rejected', () {
    test('a rejected frame is recorded as rejected', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameRejected', {
          ...frameData(frame: 1),
          'reason': 'HFR 6.2 above threshold 4.0',
          'reject_path': '/tmp/rejected_0001.fits',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      final stats = container.read(liveSequenceStatsProvider)!;
      expect(
        stats.framesRejected,
        1,
        reason: 'the grader rejected this frame; the run record must say so',
      );
      expect(
        stats.framesCaptured,
        1,
        reason: 'a rejected frame was still captured',
      );
    });

    test('the per-filter breakdown carries the rejection', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('InstructionProgressStructured', {
          'node_id': 'expo1',
          'detail_kind': 'Filter',
          'detail_json': '{"name":"Ha"}',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameRejected', {
          ...frameData(frame: 1),
          'reason': 'too few stars',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      final filterStats = container
          .read(liveSequenceStatsProvider)!
          .targetBreakdown['M31']!['Ha']!;
      expect(filterStats.rejected, 1);
      expect(filterStats.captured, 1);
    });

    test('an accepted frame is not counted as rejected', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameAccepted', {
          ...frameData(frame: 1),
          'save_path': '/tmp/light_0001.fits',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      final stats = container.read(liveSequenceStatsProvider)!;
      expect(stats.framesCaptured, 1);
      expect(stats.framesRejected, 0);
    });

    test('a frame no grader ruled on still counts as captured', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      final stats = container.read(liveSequenceStatsProvider)!;
      expect(
        stats.framesCaptured,
        1,
        reason:
            'a run with no save path emits no grader event at all; the frame '
            'still completed',
      );
      expect(stats.framesRejected, 0);
      expect(stats.integrationSecs, 300.0);
    });

    test('a rejection does not leak onto the next frame', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameRejected', {
          ...frameData(frame: 1),
          'reason': 'clouds',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameAccepted', {
          ...frameData(frame: 2),
          'save_path': '/tmp/light_0002.fits',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 2,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      final stats = container.read(liveSequenceStatsProvider)!;
      expect(stats.framesCaptured, 2);
      expect(stats.framesRejected, 1);
    });
  });

  group('the integration total agrees with the verdicts beside it', () {
    // The counters learned the grader's verdict but the integration total did
    // not: `recordFrame` credited `integrationSecs` unconditionally, so a run
    // that rejected 2 of 3 subs printed "2 of 3 rejected" and "900 s
    // integrated" in the same Session Report. Native has always excluded
    // rejected exposure time from the integration budget
    // (native/skotiq_native/sequencer/src/node/progress.rs, FrameRejected:
    // "the integration budget tracker ... skips counting the exposure time"),
    // so the run record contradicted both the operator and the executor.
    test('rejected exposure time is not credited as integration', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      for (final (frame, verdict) in const [
        (1, 'FrameAccepted'),
        (2, 'FrameRejected'),
        (3, 'FrameRejected'),
      ]) {
        executor.handleSequencerEventForTest(
          sequencerEvent(verdict, {
            ...frameData(frame: frame),
            if (verdict == 'FrameAccepted')
              'save_path': '/tmp/light_000$frame.fits'
            else
              'reason': 'HFR 6.2 above threshold 4.0',
          }),
        );
        executor.handleSequencerEventForTest(
          sequencerEvent('ExposureCompleted', {
            'frame': frame,
            'total': 4,
            'duration_secs': 300.0,
          }),
        );
      }
      await pumpEventQueue();

      final stats = container.read(liveSequenceStatsProvider)!;
      expect(stats.framesCaptured, 3);
      expect(stats.framesRejected, 2);
      expect(
        stats.integrationSecs,
        300.0,
        reason:
            'only the one accepted 300 s sub is usable data; 900 s would '
            'contradict the "2 of 3 rejected" printed beside it',
      );
      expect(
        stats.targetBreakdown['M31']!['Unknown']!.integrationSecs,
        300.0,
        reason: 'the per-filter breakdown shares the same sentence',
      );
      expect(stats.targetBreakdown['M31']!['Unknown']!.captured, 3);
      expect(stats.targetBreakdown['M31']!['Unknown']!.rejected, 2);
    });

    test('an all-rejected node integrates nothing', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameRejected', {
          ...frameData(frame: 1),
          'reason': 'clouds',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      final stats = container.read(liveSequenceStatsProvider)!;
      expect(stats.framesRejected, 1);
      expect(stats.integrationSecs, 0.0);
    });

    test('the persisted run record carries the accepted-only total', () {
      final stats = SequenceRunStats();
      stats.recordFrame(
        target: 'M31',
        filter: 'L',
        exposureSecs: 300,
        accepted: true,
      );
      stats.recordFrame(
        target: 'M31',
        filter: 'L',
        exposureSecs: 300,
        accepted: false,
      );

      final parsed = ParsedRunStats.fromJson(stats.toJson());
      expect(parsed.framesCaptured, 2);
      expect(parsed.framesRejected, 1);
      expect(parsed.integrationSecs, 300.0);
      expect(parsed.targetBreakdown['M31']!['L']!['integrationSecs'], 300.0);
      expect(
        parsed.overheadSecs,
        parsed.wallClockSecs - 300.0,
        reason: 'rejected exposure time is overhead, not integration',
      );
    });
  });

  group('the run record counts dithers', () {
    test('a completed dither is counted', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        event(backend_events.EventCategory.guiding, 'DitherCompleted', {}),
      );
      await pumpEventQueue();

      expect(
        container.read(liveSequenceStatsProvider)!.ditherCount,
        1,
        reason: 'the Session Report reads this figure',
      );
    });

    test('two dithers are counted twice', () async {
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        event(backend_events.EventCategory.guiding, 'DitherCompleted', {}),
      );
      executor.handleSequencerEventForTest(
        event(backend_events.EventCategory.guiding, 'DitherCompleted', {}),
      );
      await pumpEventQueue();

      expect(container.read(liveSequenceStatsProvider)!.ditherCount, 2);
    });
  });

  group('one preview fetch per frame, stamped with the truth', () {
    test(
      'the imaging duplicate of ExposureCompleted fetches nothing',
      () async {
        final (_, executor) = build(sequence: exposureSequence());

        executor.handleSequencerEventForTest(
          event(backend_events.EventCategory.imaging, 'ExposureComplete', {
            'success': true,
          }),
        );
        await pumpEventQueue();

        verifyNever(() => backend.cameraGetLastImage(any()));
      },
    );

    test('a frame fetches the full image exactly once', () async {
      final (_, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameAccepted', {
          ...frameData(frame: 1),
          'save_path': '/tmp/light_0001.fits',
        }),
      );
      // Native emits BOTH for the same exposure.
      executor.handleSequencerEventForTest(
        event(backend_events.EventCategory.imaging, 'ExposureComplete', {
          'success': true,
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      verify(() => backend.cameraGetLastImage(_cameraId)).called(1);
    });

    // A Smart Exposure frame gets a verdict but never an ExposureCompleted;
    // the preview hung on that event, so a whole run on the rig showed the
    // pre-run snapshot (2026-10-20).
    test('a frame with only a verdict still goes on screen', () async {
      final (_, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('FrameAccepted', {
          ...frameData(frame: 1),
          'save_path': '/tmp/light_0001.fits',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameRejected', {
          ...frameData(frame: 1),
          'reason': 'HFR',
          'reject_path': '/tmp/rejects/light_0002.fits',
        }),
      );
      await pumpEventQueue();

      verify(() => backend.cameraGetLastImage(_cameraId)).called(2);
    });

    test('an ungraded frame goes on screen at its completion', () async {
      final (_, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      verify(() => backend.cameraGetLastImage(_cameraId)).called(1);
    });

    test('the published preview carries the frame it was taken with', () async {
      when(() => backend.cameraGetLastImage(any())).thenAnswer(
        (_) async => CapturedImageResult(
          width: 2,
          height: 2,
          displayData: List<int>.filled(2 * 2 * 4, 64),
          histogram: List<int>.filled(256, 1),
          stats: const ImageStatsResult(
            min: 0,
            max: 1,
            mean: 0.5,
            median: 0.5,
            stdDev: 0.1,
            starCount: 0,
          ),
          exposureTime: 300.0,
          timestamp: DateTime.now().toUtc().toIso8601String(),
          isColor: false,
        ),
      );
      final (container, executor) = build(sequence: exposureSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {'node_id': 'expo1'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('FrameAccepted', {
          ...frameData(frame: 1),
          'save_path': '/tmp/light_0001.fits',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 300.0,
        }),
      );
      await pumpEventQueue();

      final settings = container.read(currentImageProvider)!.settings;
      expect(settings.exposureTime, 300.0);
      expect(settings.gain, 120, reason: 'gain 0 was a literal, not a reading');
      expect(settings.offset, 30);
      expect(settings.binningX, 2);
      expect(settings.binningY, 2);
    });
  });
}

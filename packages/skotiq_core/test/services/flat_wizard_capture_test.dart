// Deterministic tests for the authoritative capture primitive
// [FlatWizardService.exposeAndAwait] and the cancel-aware calibration solver.
//
// These exercise the correctness guarantees that a fixed-delay capture cannot
// provide:
//   * Completion is driven by the real terminal exposure EVENT, not a timer —
//     so a slow readout is waited out (never a stale/wrong image).
//   * A terminal event tagged with a DIFFERENT device id is ignored (multi
//     camera event streams cannot cross-satisfy a wait).
//   * A cancel that lands mid-exposure aborts the hardware EXACTLY once and is
//     reported as cancelled — through both the low-level primitive and the
//     calibration loop.
//
// The backend is a hand-driven double: exposures do NOT auto-complete, so each
// test emits the terminal event (or cancels) at a controlled moment. Abort
// models real hardware by emitting `ExposureCancelled`.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/services/flat_wizard_service.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';

import '../harness/event_wire.dart';
import '../harness/imaging_event_rows.dart';

/// Let queued microtasks/timers drain so an in-flight `exposeAndAwait` reaches
/// its wait state before the test emits an event or cancels.
Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  const cam = 'native:asi:0';

  group('exposeAndAwait: authoritative completion', () {
    test('waits for the completion EVENT, not a fixed delay', () async {
      final backend = _ManualBackend();
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final future = service.exposeAndAwait(
        deviceId: cam,
        exposureTime: 0.1,
        gain: 0,
        offset: 0,
      );

      var settled = false;
      unawaited(future.then((_) => settled = true));
      await _pump();

      // A completion timer would already have fired for a 0.1s exposure; the
      // event-driven wait must NOT have settled yet.
      expect(
        settled,
        isFalse,
        reason: 'capture settled before the completion event arrived',
      );
      expect(backend.startCalls.single, cam);

      backend.emitCompleted(cam, mean: 25000);
      final result = await future;

      expect(settled, isTrue);
      expect(result.outcome, FlatFrameOutcome.completed);
      expect(result.adu, 25000);
    });

    test('ignores a terminal event tagged with a different device', () async {
      final backend = _ManualBackend();
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final future = service.exposeAndAwait(
        deviceId: cam,
        exposureTime: 0.1,
        gain: 0,
        offset: 0,
      );
      var settled = false;
      unawaited(future.then((_) => settled = true));
      await _pump();

      // An unrelated camera's completion must not wake our wait.
      backend.emitCompleted('native:qhy:1', mean: 9999);
      await _pump();
      expect(
        settled,
        isFalse,
        reason: 'an unrelated-device completion satisfied the wait',
      );

      // Our own completion does.
      backend.emitCompleted(cam, mean: 32000);
      final result = await future;
      expect(result.outcome, FlatFrameOutcome.completed);
      expect(result.adu, 32000);
    });

    test(
      'a null image on completion is a failure, not a silent success',
      () async {
        final backend = _ManualBackend(imageMean: null);
        addTearDown(backend.dispose);
        final service = FlatWizardService(backend);

        final future = service.exposeAndAwait(
          deviceId: cam,
          exposureTime: 0.05,
          gain: 0,
          offset: 0,
        );
        await _pump();
        backend.emitCompleted(cam, mean: null);
        final result = await future;

        expect(result.outcome, FlatFrameOutcome.failed);
        expect(result.adu, isNull);
      },
    );
  });

  // Which events end a flat's wait and how, over both transports, and with
  // the camera named in the data (ours or another's). Pinned on the
  // classifier that compared event names.
  test('the events that end a flat exposure wait', () async {
    Future<String> outcomeOf(SkotiqEvent event) async {
      final backend = _ManualBackend();
      addTearDown(backend.dispose);
      final token = FlatCancelToken();
      final future = FlatWizardService(backend).exposeAndAwait(
        deviceId: cam,
        exposureTime: 5.0,
        gain: 0,
        offset: 0,
        cancelToken: token,
      );
      await _pump();
      backend.emit(event);
      await _pump();
      String? settled;
      unawaited(future.then((r) => settled ??= r.outcome.name));
      await _pump();
      final shown = settled ?? 'waiting';
      token.cancel();
      await future;
      return shown;
    }

    final table = <String, String>{};
    for (final row in imagingEventRows.entries) {
      final ffi = await outcomeOf(ffiWireEvent(row.value));
      final network = await outcomeOf(networkWireEvent(row.value));
      expect(network, ffi, reason: '${row.key}: the transports disagree');
      final ours = await outcomeOf(
        cameraTaggedWireEvent(row.value, deviceId: cam),
      );
      final theirs = await outcomeOf(
        cameraTaggedWireEvent(
          row.value,
          deviceId: 'native:qhy:1',
          key: 'camera_id',
        ),
      );
      table[row.key] = '$ffi ours=$ours theirs=$theirs';
    }
    expect(table, {
      'exposureStarted': 'waiting ours=waiting theirs=waiting',
      'exposureStartedWithFrame': 'waiting ours=waiting theirs=waiting',
      'exposureProgress': 'waiting ours=waiting theirs=waiting',
      'exposureCompleted': 'completed ours=completed theirs=waiting',
      'exposureCompletedWithFrame': 'completed ours=completed theirs=waiting',
      'exposureFailed': 'failed ours=failed theirs=waiting',
      'exposureFailedOld': 'failed ours=failed theirs=waiting',
      'exposureCancelled': 'cancelled ours=cancelled theirs=waiting',
      'downloadStarted': 'waiting ours=waiting theirs=waiting',
      'downloadCompleted': 'waiting ours=waiting theirs=waiting',
      'imageReady': 'waiting ours=waiting theirs=waiting',
      'imageSaved': 'waiting ours=waiting theirs=waiting',
      'integrationProgress': 'waiting ours=waiting theirs=waiting',
      'integrationTelemetry': 'waiting ours=waiting theirs=waiting',
      'temperatureChanged': 'waiting ours=waiting theirs=waiting',
      'exposureComplete ok': 'completed ours=completed theirs=waiting',
      'exposureComplete failed': 'failed ours=failed theirs=waiting',
      'depthLock goalChanged': 'waiting ours=waiting theirs=waiting',
      'sequencer ExposureCompleted': 'waiting ours=waiting theirs=waiting',
    });
  });

  group('exposeAndAwait: cooperative cancel', () {
    test(
      'cancel mid-exposure aborts EXACTLY once and reports canceled',
      () async {
        final backend = _ManualBackend();
        addTearDown(backend.dispose);
        final service = FlatWizardService(backend);

        final token = FlatCancelToken();
        final future = service.exposeAndAwait(
          deviceId: cam,
          exposureTime: 5.0, // long; only a cancel will end it
          gain: 0,
          offset: 0,
          cancelToken: token,
        );
        await _pump();
        expect(backend.startCalls.single, cam);

        token.cancel();
        final result = await future;

        expect(result.outcome, FlatFrameOutcome.cancelled);
        expect(
          backend.abortCalls,
          equals([cam]),
          reason:
              'abort must be issued exactly once for the in-flight exposure',
        );
      },
    );

    test('a cancel requested BEFORE start never touches the camera', () async {
      final backend = _ManualBackend();
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final token = FlatCancelToken()..cancel();
      final result = await service.exposeAndAwait(
        deviceId: cam,
        exposureTime: 1.0,
        gain: 0,
        offset: 0,
        cancelToken: token,
      );

      expect(result.outcome, FlatFrameOutcome.cancelled);
      expect(backend.startCalls, isEmpty);
      expect(backend.abortCalls, isEmpty);
    });
  });

  group('calibrateFilter: cancel-aware', () {
    test(
      'cancel during the calibration exposure returns a canceled result',
      () async {
        final backend = _ManualBackend();
        addTearDown(backend.dispose);
        final service = FlatWizardService(backend);

        final token = FlatCancelToken();
        final future = service.calibrateFilter(
          deviceId: cam,
          filter: 'L',
          gain: 0,
          offset: 0,
          targetAdu: 30000,
          tolerance: 5,
          minExposure: 0.01,
          maxExposure: 10,
          cancelToken: token,
        );

        // Let the first test-frame exposure start and reach its wait.
        await _pump();
        expect(backend.startCalls, isNotEmpty);

        token.cancel();
        final result = await future;

        expect(result.cancelled, isTrue);
        expect(result.success, isFalse);
        expect(
          backend.abortCalls,
          equals([cam]),
          reason: 'the in-flight calibration exposure must be aborted once',
        );
      },
    );
  });

  group('captureTestFrame: outcome travels with the call', () {
    test('two overlapping captures each get their own outcome', () async {
      // `flatWizardServiceProvider` is a plain Provider, so the GUI wizard and
      // the headless API drive ONE instance with nothing serialising them. The
      // outcome therefore has to come back from the call; a field on the
      // service would let the second capture's result answer the first's read.
      const other = 'native:asi:1';
      final backend = _ManualBackend();
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final first = service.captureTestFrame(
        deviceId: cam,
        exposureTime: 0.1,
        gain: 0,
        offset: 0,
      );
      final second = service.captureTestFrame(
        deviceId: other,
        exposureTime: 0.1,
        gain: 0,
        offset: 0,
      );
      await _pump();
      expect(backend.startCalls, equals([cam, other]));

      // Settle them in the opposite order to the one they were started in:
      // the second capture fails, the first completes.
      backend.emitFailed(other);
      await _pump();
      backend.emitCompleted(cam);

      final firstFrame = await first;
      final secondFrame = await second;

      expect(firstFrame.outcome!.isCompleted, isTrue);
      expect(firstFrame.adu, isNotNull);
      expect(secondFrame.outcome!.outcome, FlatFrameOutcome.failed);
      expect(secondFrame.adu, isNull);
    });
  });
}

/// Hand-driven camera double. Exposures do NOT auto-complete — the test emits
/// the terminal event (or cancels) explicitly. `cameraAbortExposure` models
/// real hardware by emitting `ExposureCancelled` so the settle wait resolves.
class _ManualBackend extends Mock implements SkotiqBackend {
  _ManualBackend({this.imageMean = 25000});

  /// Mean ADU reported by `cameraGetLastImage`; null => no image (failure).
  final double? imageMean;

  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  final List<String> startCalls = [];
  final List<String> abortCalls = [];
  int _seq = 0;

  @override
  void dispose() {
    if (!_events.isClosed) _events.close();
  }

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

  SkotiqEvent _event(bridge.ImagingEvent event, String deviceId) =>
      cameraTaggedWireEvent(
        bridge.EventPayload.imaging(event),
        deviceId: deviceId,
        timestamp: ++_seq,
      );

  void emit(SkotiqEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void emitCompleted(String deviceId, {double? mean}) {
    if (_events.isClosed) return;
    _lastMean = mean ?? imageMean;
    _events.add(
      _event(
        const bridge.ImagingEvent.exposureCompleted(hfr: 2, starsDetected: 0),
        deviceId,
      ),
    );
  }

  void emitFailed(String deviceId) {
    if (_events.isClosed) return;
    _events.add(
      _event(
        const bridge.ImagingEvent.exposureFailed(error: 'failed'),
        deviceId,
      ),
    );
  }

  double? _lastMean;

  @override
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    startCalls.add(deviceId);
    _lastMean = imageMean;
  }

  @override
  Future<void> cameraAbortExposure(String deviceId) async {
    abortCalls.add(deviceId);
    // Real drivers emit a cancellation event once the abort takes effect.
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events.add(
        _event(const bridge.ImagingEvent.exposureCancelled(), deviceId),
      );
    });
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    final mean = _lastMean;
    if (mean == null) return null;
    return CapturedImageResult(
      width: 4,
      height: 4,
      displayData: List<int>.filled(4 * 4 * 4, 128),
      histogram: List<int>.filled(256, 1),
      stats: ImageStatsResult(
        min: mean * 0.9,
        max: mean * 1.1,
        mean: mean,
        median: mean,
        stdDev: mean * 0.05,
        starCount: 0,
      ),
      exposureTime: 1.0,
      timestamp: DateTime.now().toUtc().toIso8601String(),
    );
  }
}

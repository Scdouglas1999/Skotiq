// Deterministic tests for the fail-safe timeout / abort / settle lifecycle of
// [FlatWizardService.exposeAndAwait] and the calibration solvers.
//
// The bug being fixed: a timed-out (or cancelled) exposure used to abort then
// immediately continue / `getLastImage`, handing back a STALE prior frame or
// overlapping the next exposure. The contract pinned here:
//   * A timeout aborts the hardware EXACTLY once and waits (bounded) for the
//     camera to settle — it NEVER reads `getLastImage` (no stale frame).
//   * When the abort throws or idle cannot be confirmed, the capture reports
//     `cameraQuiescent == false` and the solver HALTS the whole run.
//   * A timeout in a batch stops after the current filter — no next exposure is
//     started while the prior one may still be active.
//
// The backend is hand-driven: exposures never auto-complete, so a tiny
// `overallTimeout` forces the timeout branch deterministically.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/services/flat_wizard_service.dart';

Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

enum _AbortMode { settle, noSettle, throwError }

/// Hand-driven camera that never auto-completes an exposure. `cameraAbort`
/// behaves per [abortMode]: emit a terminal ExposureCancelled (settle), emit
/// nothing (settle times out), or throw (abort failed).
class _StallBackend extends Mock implements SkotiqBackend {
  _StallBackend({this.abortMode = _AbortMode.settle});

  final _AbortMode abortMode;

  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  final List<String> startCalls = [];
  final List<String> abortCalls = [];
  final List<String> getLastImageCalls = [];
  int _seq = 0;

  @override
  void dispose() {
    if (!_events.isClosed) _events.close();
  }

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

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
    // Never completes.
  }

  @override
  Future<void> cameraAbortExposure(String deviceId) async {
    abortCalls.add(deviceId);
    switch (abortMode) {
      case _AbortMode.throwError:
        throw StateError('abort failed');
      case _AbortMode.noSettle:
        return; // no terminal event ever arrives
      case _AbortMode.settle:
        Future<void>.delayed(const Duration(milliseconds: 5), () {
          if (_events.isClosed) return;
          _events.add(
            SkotiqEvent(
              timestamp: ++_seq,
              severity: EventSeverity.info,
              category: EventCategory.imaging,
              eventType: 'ExposureCancelled',
              data: {'deviceId': deviceId},
            ),
          );
        });
    }
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    getLastImageCalls.add(deviceId);
    // A STALE prior frame — must never be surfaced as the timed-out frame.
    return CapturedImageResult(
      width: 2,
      height: 2,
      displayData: List<int>.filled(2 * 2 * 4, 9),
      histogram: List<int>.filled(256, 1),
      stats: const ImageStatsResult(
        min: 0,
        max: 100,
        mean: 12345,
        median: 12345,
        stdDev: 1,
        starCount: 0,
      ),
      exposureTime: 1.0,
      timestamp: DateTime.now().toUtc().toIso8601String(),
    );
  }
}

void main() {
  const cam = 'native:cam:0';

  group('exposeAndAwait — timeout is fail-safe', () {
    test(
      'timeout aborts exactly once, settles, and reads NO stale image',
      () async {
        final backend = _StallBackend(abortMode: _AbortMode.settle);
        addTearDown(backend.dispose);
        final service = FlatWizardService(backend);

        final capture = await service.exposeAndAwait(
          deviceId: cam,
          exposureTime: 0.01,
          gain: 0,
          offset: 0,
          overallTimeout: const Duration(milliseconds: 40),
          abortSettleTimeout: const Duration(seconds: 1),
        );

        expect(capture.outcome, FlatFrameOutcome.timedOut);
        expect(capture.cameraQuiescent, isTrue, reason: 'settle event arrived');
        expect(capture.image, isNull);
        expect(
          backend.abortCalls,
          equals([cam]),
          reason: 'abort must be issued exactly once',
        );
        expect(
          backend.getLastImageCalls,
          isEmpty,
          reason:
              'a timed-out frame must NEVER read getLastImage (stale frame)',
        );
      },
    );

    test('abort failure → camera state unknown (not quiescent)', () async {
      final backend = _StallBackend(abortMode: _AbortMode.throwError);
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final capture = await service.exposeAndAwait(
        deviceId: cam,
        exposureTime: 0.01,
        gain: 0,
        offset: 0,
        overallTimeout: const Duration(milliseconds: 40),
        abortSettleTimeout: const Duration(seconds: 1),
      );

      expect(capture.outcome, FlatFrameOutcome.timedOut);
      expect(capture.cameraQuiescent, isFalse);
      expect(backend.abortCalls, equals([cam]));
    });

    test('settle timeout → camera state unknown (not quiescent)', () async {
      final backend = _StallBackend(abortMode: _AbortMode.noSettle);
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final capture = await service.exposeAndAwait(
        deviceId: cam,
        exposureTime: 0.01,
        gain: 0,
        offset: 0,
        overallTimeout: const Duration(milliseconds: 40),
        abortSettleTimeout: const Duration(milliseconds: 40),
      );

      expect(capture.outcome, FlatFrameOutcome.timedOut);
      expect(capture.cameraQuiescent, isFalse);
    });
  });

  group('calibration halts on timeout', () {
    test('calibrateFilter returns haltRun on a timed-out exposure', () async {
      final backend = _StallBackend(abortMode: _AbortMode.settle);
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final result = await service.calibrateFilter(
        deviceId: cam,
        filter: 'L',
        gain: 0,
        offset: 0,
        targetAdu: 30000,
        tolerance: 5,
        minExposure: 0.01,
        maxExposure: 1,
        overallTimeout: const Duration(milliseconds: 40),
        abortSettleTimeout: const Duration(seconds: 1),
      );

      expect(result.haltRun, isTrue);
      expect(result.success, isFalse);
      expect(result.cameraStateUnknown, isFalse, reason: 'settle confirmed');
      expect(backend.startCalls, hasLength(1));
    });

    test('abort failure surfaces cameraStateUnknown', () async {
      final backend = _StallBackend(abortMode: _AbortMode.throwError);
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final result = await service.calibrateFilter(
        deviceId: cam,
        filter: 'L',
        gain: 0,
        offset: 0,
        targetAdu: 30000,
        tolerance: 5,
        minExposure: 0.01,
        maxExposure: 1,
        overallTimeout: const Duration(milliseconds: 40),
        abortSettleTimeout: const Duration(seconds: 1),
      );

      expect(result.haltRun, isTrue);
      expect(result.cameraStateUnknown, isTrue);
    });

    test('calibrateMultipleFilters stops after the timed-out filter — '
        'no next exposure', () async {
      final backend = _StallBackend(abortMode: _AbortMode.settle);
      addTearDown(backend.dispose);
      final service = FlatWizardService(backend);

      final results = await service.calibrateMultipleFilters(
        deviceId: cam,
        filters: const ['L', 'R', 'G'],
        gain: 0,
        offset: 0,
        targetAdu: 30000,
        tolerance: 5,
        minExposure: 0.01,
        maxExposure: 1,
        overallTimeout: const Duration(milliseconds: 40),
        abortSettleTimeout: const Duration(seconds: 1),
      );

      expect(results, hasLength(1), reason: 'only the first filter ran');
      expect(results.single.haltRun, isTrue);
      expect(
        backend.startCalls,
        hasLength(1),
        reason: 'no exposure started for R or G after the timeout',
      );
    });
  });

  group('cancel + timeout idempotency', () {
    test(
      'a cancel that arrives during the timeout window still aborts once',
      () async {
        final backend = _StallBackend(abortMode: _AbortMode.settle);
        addTearDown(backend.dispose);
        final service = FlatWizardService(backend);

        final token = FlatCancelToken();
        final future = service.exposeAndAwait(
          deviceId: cam,
          exposureTime: 0.01,
          gain: 0,
          offset: 0,
          cancelToken: token,
          overallTimeout: const Duration(milliseconds: 60),
          abortSettleTimeout: const Duration(seconds: 1),
        );
        await _pump();
        token.cancel();
        final capture = await future;

        expect(
          capture.outcome,
          anyOf(FlatFrameOutcome.cancelled, FlatFrameOutcome.timedOut),
        );
        expect(
          backend.abortCalls.length,
          1,
          reason: 'abort is issued at most once across the cancel/timeout race',
        );
        expect(backend.getLastImageCalls, isEmpty);
      },
    );
  });
}

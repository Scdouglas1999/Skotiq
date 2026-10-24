// The frame on screen is plate solved in the background, one frame at a
// time with only the newest queued, and its stars are detected on demand.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

PlateSolveResult _result({
  required double ra,
  bool success = true,
  String? error,
}) => PlateSolveResult(
  success: success,
  ra: ra,
  dec: 22.5,
  rotation: 12,
  pixelScale: success ? 1.2 : 0,
  fieldWidth: 1,
  fieldHeight: 1,
  solveTimeSecs: 1,
  error: error,
  cd11: 0,
  cd12: 0,
  cd21: 0,
  cd22: 0,
  sipAOrder: 0,
  sipBOrder: 0,
  sipACoeffs: Float64List(0),
  sipBCoeffs: Float64List(0),
  sipApOrder: 0,
  sipBpOrder: 0,
  sipApCoeffs: Float64List(0),
  sipBpCoeffs: Float64List(0),
);

CapturedImageData _frame(
  int second, {
  String? path,
  FrameType type = FrameType.light,
}) => CapturedImageData(
  width: 40,
  height: 30,
  displayData: Uint8List(40 * 30 * 4),
  histogram: const <int>[],
  stats: const ImageStats(),
  capturedAt: DateTime.utc(2026, 10, 21, 3, 0, second),
  settings: ExposureSettings(
    exposureTime: 30,
    gain: 100,
    offset: 10,
    frameType: type,
  ),
  filePath: path,
);

class _FakeSolver {
  final calls = <({String path, double? ra, double? dec})>[];
  final pending = <String, Completer<PlateSolveResult?>>{};
  Object? throwOnCall;

  Future<PlateSolveResult?> call({
    required String imagePath,
    required bool Function() isCurrent,
    double? hintRaHours,
    double? hintDecDegrees,
  }) {
    calls.add((path: imagePath, ra: hintRaHours, dec: hintDecDegrees));
    final error = throwOnCall;
    if (error != null) return Future<PlateSolveResult?>.error(error);
    return (pending[imagePath] = Completer<PlateSolveResult?>()).future;
  }
}

void main() {
  late _FakeSolver solver;
  late ProviderContainer container;
  SavedFrameSolution? saved;
  late List<({String path, PlateSolveResult result})> recorded;

  setUp(() {
    solver = _FakeSolver();
    saved = null;
    recorded = [];
    container = ProviderContainer(
      overrides: [
        backgroundFrameSolverProvider.overrideWithValue(solver.call),
        backgroundSolveRecorderProvider.overrideWithValue(
          (path, result) async => recorded.add((path: path, result: result)),
        ),
        savedFrameSolutionProvider.overrideWithValue((_) async => saved),
        mountPointingHintProvider.overrideWithValue((2.5, 30.0)),
      ],
    );
    addTearDown(container.dispose);
    // Keep the queue alive, as a screen watching it does.
    container.listen(frameAutoSolveProvider, (_, __) {});
  });

  void show(CapturedImageData frame) =>
      container.read(currentImageProvider.notifier).state = frame;

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('a light frame with a file is solved, hinted by the mount', () async {
    final frame = _frame(1, path: '/lights/a.fits');
    show(frame);
    await settle();
    expect(solver.calls.single.path, '/lights/a.fits');
    expect(solver.calls.single.ra, 2.5);
    expect(
      container.read(currentFrameSolveProvider)?.status,
      FrameSolveStatus.solving,
    );

    solver.pending['/lights/a.fits']!.complete(_result(ra: 150));
    await settle();
    final solve = container.read(currentFrameSolveProvider)!;
    expect(solve.status, FrameSolveStatus.solved);
    expect(solve.raDegrees, 150);
    final wcs = solve.wcsFor(width: 40, height: 30)!;
    expect(wcs.raHours, 10);
    expect(wcs.pixelScaleArcsec, 1.2);
    // The solve is kept with the frame's record too.
    expect(recorded.single.path, '/lights/a.fits');
    expect(recorded.single.result.ra, 150);
  });

  test('a failed solve is not written to the frame record', () async {
    show(_frame(1, path: '/lights/f.fits'));
    await settle();
    solver.pending['/lights/f.fits']!.complete(
      _result(ra: 0, success: false, error: 'no solution'),
    );
    await settle();
    expect(
      container.read(currentFrameSolveProvider)?.status,
      FrameSolveStatus.failed,
    );
    expect(recorded, isEmpty);
  });

  test('the frame already on screen is solved when the queue starts', () async {
    final late = ProviderContainer(
      overrides: [
        backgroundFrameSolverProvider.overrideWithValue(solver.call),
        savedFrameSolutionProvider.overrideWithValue((_) async => null),
        mountPointingHintProvider.overrideWithValue((null, null)),
      ],
    );
    addTearDown(late.dispose);
    late.read(currentImageProvider.notifier).state = _frame(
      9,
      path: '/lights/first.fits',
    );
    // A screen opens and reads the solve of the frame it shows.
    late.listen(currentFrameSolveProvider, (_, __) {});
    await settle();
    expect(solver.calls.map((c) => c.path), ['/lights/first.fits']);
    expect(
      late.read(currentFrameSolveProvider)?.status,
      FrameSolveStatus.solving,
    );
  });

  test('the path arriving after the frame starts its solve', () async {
    show(_frame(1));
    await settle();
    expect(solver.calls, isEmpty);
    show(_frame(1, path: '/lights/a.fits'));
    await settle();
    expect(solver.calls.map((c) => c.path), ['/lights/a.fits']);
  });

  test('only the newest frame waits behind a running solve', () async {
    show(_frame(1, path: '/lights/1.fits'));
    await settle();
    show(_frame(2, path: '/lights/2.fits'));
    await settle();
    show(_frame(3, path: '/lights/3.fits'));
    await settle();
    expect(
      container.read(currentFrameSolveProvider)?.status,
      FrameSolveStatus.waiting,
    );

    solver.pending['/lights/1.fits']!.complete(_result(ra: 100));
    await settle();
    expect(
      solver.calls.map((c) => c.path),
      ['/lights/1.fits', '/lights/3.fits'],
      reason: 'frame 2 was replaced before its turn and is never solved',
    );
    // The next solve starts from the last solved field.
    expect(solver.calls.last.ra, closeTo(100 / 15, 1e-9));
    expect(
      container.read(frameAutoSolveProvider).keys,
      isNot(contains(DateTime.utc(2026, 10, 21, 3, 0, 2))),
    );
  });

  test('dark frames are not solved', () async {
    show(_frame(1, path: '/darks/d.fits', type: FrameType.dark));
    await settle();
    expect(solver.calls, isEmpty);
    expect(container.read(currentFrameSolveProvider), isNull);
  });

  test('a solution saved with the frame is used without solving', () async {
    saved = (
      raDegrees: 30.0,
      decDegrees: 40.0,
      rotationDeg: 5.0,
      pixelScaleArcsec: 2.0,
    );
    show(_frame(1, path: '/lights/a.fits'));
    await settle();
    expect(solver.calls, isEmpty);
    final solve = container.read(currentFrameSolveProvider)!;
    expect(solve.status, FrameSolveStatus.solved);
    expect(solve.fromSavedSolution, isTrue);
    expect(solve.raDegrees, 30);
  });

  test('a failed solve and a missing solver say so', () async {
    show(_frame(1, path: '/lights/a.fits'));
    await settle();
    solver.pending['/lights/a.fits']!.complete(
      _result(ra: 0, success: false, error: 'Only 4 stars found'),
    );
    await settle();
    var solve = container.read(currentFrameSolveProvider)!;
    expect(solve.status, FrameSolveStatus.failed);
    expect(solve.message, 'Only 4 stars found');

    solver.throwOnCall = const SolverNotAvailableError('No solver');
    show(_frame(2, path: '/lights/b.fits'));
    await settle();
    solve = container.read(currentFrameSolveProvider)!;
    expect(solve.status, FrameSolveStatus.noSolver);
  });

  group('stars', () {
    test('detected from the frame file, and nothing without one', () async {
      final detected = <String>[];
      final stars = ProviderContainer(
        overrides: [
          frameStarDetectorProvider.overrideWithValue((path) async {
            detected.add(path);
            return const StarDetectionResult(
              stars: <DetectedStar>[
                DetectedStar(
                  x: 10,
                  y: 12,
                  flux: 900,
                  hfr: 2.1,
                  fwhm: 4,
                  peak: 300,
                  background: 100,
                  snr: 40,
                ),
              ],
              starCount: 1,
              medianHfr: 2.1,
              medianFwhm: 4,
              medianSnr: 40,
              background: 100,
              noise: 5,
            );
          }),
        ],
      );
      addTearDown(stars.dispose);
      final sub = stars.listen(currentFrameStarsProvider, (_, __) {});
      addTearDown(sub.close);

      stars.read(currentImageProvider.notifier).state = _frame(1);
      expect(await stars.read(currentFrameStarsProvider.future), isNull);

      stars.read(currentImageProvider.notifier).state = _frame(
        1,
        path: '/lights/a.fits',
      );
      final result = await stars.read(currentFrameStarsProvider.future);
      expect(result!.stars.single.hfr, 2.1);
      expect(detected, ['/lights/a.fits']);
    });
  });
}

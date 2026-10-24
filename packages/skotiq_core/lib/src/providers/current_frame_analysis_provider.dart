// What the app works out about the frame on screen without being asked: where
// on the sky it points (a background plate solve) and where its stars are (a
// star detection, run only while a star overlay is shown).
//
// Both run off the UI isolate: the solve is ASTAP or astrometry.net in their
// own process under the native solve gate, and the detection is the native
// detector on a bridge worker thread. Both read the frame's FITS file, so a
// frame without one (a remote preview, a frame still being written) waits
// until its path arrives.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../backend/ffi_backend.dart' show FfiBackend;
import '../backend/skotiq_backend.dart';
import '../models/imaging/imaging_models.dart';
import '../services/imaging_service.dart';
import '../services/logging_service.dart';
import '../services/plate_solve_service.dart';
import '../services/wcs/gnomonic_projection.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'equipment/mount_state_provider.dart';
import 'frame_record_updates.dart';

// ---------------------------------------------------------------------------
// Background plate solve
// ---------------------------------------------------------------------------

/// Where a frame's background solve stands.
enum FrameSolveStatus {
  /// Queued behind another frame's solve.
  waiting,

  /// The solver is running on it.
  solving,

  /// Solved; the solution is on the [FrameSolveVm].
  solved,

  /// The solver ran and found no solution, or failed.
  failed,

  /// No plate solver is set up, so nothing was tried.
  noSolver,
}

/// A frame's background solve, keyed by [CapturedImageData.capturedAt].
@immutable
class FrameSolveVm {
  const FrameSolveVm({
    required this.frameCapturedAt,
    required this.status,
    this.raDegrees,
    this.decDegrees,
    this.rotationDeg,
    this.pixelScaleArcsec,
    this.message,
    this.fromSavedSolution = false,
  });

  final DateTime frameCapturedAt;
  final FrameSolveStatus status;

  /// The solution; all four are set exactly when [status] is solved.
  final double? raDegrees;
  final double? decDegrees;
  final double? rotationDeg;
  final double? pixelScaleArcsec;

  /// Why a solve failed or could not run.
  final String? message;

  /// The solution was already saved with the frame, so no solver ran.
  final bool fromSavedSolution;

  bool get isSolved => status == FrameSolveStatus.solved;

  /// The same solve, recorded against another window's copy of the frame.
  FrameSolveVm forFrame(DateTime key) => FrameSolveVm(
    frameCapturedAt: key,
    status: status,
    raDegrees: raDegrees,
    decDegrees: decDegrees,
    rotationDeg: rotationDeg,
    pixelScaleArcsec: pixelScaleArcsec,
    message: message,
    fromSavedSolution: fromSavedSolution,
  );

  /// The solution as the catalog overlay takes it; null unless solved.
  SolvedWcs? wcsFor({required int width, required int height}) {
    final ra = raDegrees;
    final dec = decDegrees;
    final rot = rotationDeg;
    final scale = pixelScaleArcsec;
    if (!isSolved ||
        ra == null ||
        dec == null ||
        rot == null ||
        scale == null) {
      return null;
    }
    final wcs = SolvedWcs(
      raHours: ra / 15,
      decDegrees: dec,
      rotationDeg: rot,
      pixelScaleArcsec: scale,
      imageWidth: width,
      imageHeight: height,
    );
    return wcs.isValid ? wcs : null;
  }

  @override
  bool operator ==(Object other) =>
      other is FrameSolveVm &&
      other.frameCapturedAt == frameCapturedAt &&
      other.status == status &&
      other.raDegrees == raDegrees &&
      other.decDegrees == decDegrees &&
      other.rotationDeg == rotationDeg &&
      other.pixelScaleArcsec == pixelScaleArcsec &&
      other.message == message &&
      other.fromSavedSolution == fromSavedSolution;

  @override
  int get hashCode => Object.hash(
    frameCapturedAt,
    status,
    raDegrees,
    decDegrees,
    rotationDeg,
    pixelScaleArcsec,
    message,
    fromSavedSolution,
  );
}

/// Runs one background solve. Returns null when the frame was replaced
/// before the solver started; throws [SolverNotAvailableError] when no
/// solver is set up.
typedef BackgroundFrameSolver =
    Future<PlateSolveResult?> Function({
      required String imagePath,
      required bool Function() isCurrent,
      double? hintRaHours,
      double? hintDecDegrees,
    });

/// The solver the background queue uses: the app's plate-solve service.
final backgroundFrameSolverProvider = Provider<BackgroundFrameSolver>((ref) {
  final service = ref.watch(plateSolveServiceProvider);
  return service.solveInBackground;
});

/// A solution already saved for the frame at a path, in the units of
/// [FrameSolveVm] (RA in degrees).
typedef SavedFrameSolution = ({
  double raDegrees,
  double decDegrees,
  double rotationDeg,
  double pixelScaleArcsec,
});

/// Looks up a solution saved with a frame's database row, so a frame that
/// was solved already (by the science pipeline, or an earlier session) is
/// not solved again. Null when there is none or the database is not local.
final savedFrameSolutionProvider =
    Provider<Future<SavedFrameSolution?> Function(String filePath)>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is! FfiBackend) return (_) async => null;
      final dao = ref.watch(imagesDaoProvider);
      return (filePath) async {
        final row = await dao.getImageByFilePath(filePath);
        if (row == null || !row.isPlateSolved) return null;
        final ra = row.solvedRa;
        final dec = row.solvedDec;
        final rot = row.solvedRotation;
        final scale = row.solvedPixelScale;
        if (ra == null || dec == null || rot == null || scale == null) {
          return null;
        }
        // The row keeps RA in hours.
        return (
          raDegrees: ra * 15,
          decDegrees: dec,
          rotationDeg: rot,
          pixelScaleArcsec: scale,
        );
      };
    });

/// Where the mount says it points, RA hours and Dec degrees, as a solve
/// hint; nulls when it does not say.
final mountPointingHintProvider = Provider<(double?, double?)>((ref) {
  final ra = ref.watch(mountStateProvider.select((m) => m.ra));
  final dec = ref.watch(mountStateProvider.select((m) => m.dec));
  return (ra, dec);
});

/// How many frames' solves are remembered. The frame on screen is the one
/// that matters; a few more cover a frame shown again from a quick switch.
const int _rememberedSolves = 12;

/// The background solve of every light frame that reaches the screen.
///
/// One solve at a time. A frame that arrives while one runs waits, and a
/// newer frame replaces it in the queue, so a fast loop never builds a
/// backlog: only the newest frame is ever solved next. Results are kept per
/// frame in memory, and a successful solve is also written to the frame's
/// `captured_images` row when it has one ([backgroundSolveRecorderProvider]).
/// The frame on screen that a linked client fetched because the imaging host
/// showed it, and the background solve the host made of it, by host path.
///
/// The host solves every frame on its own screen. A client that solved the
/// same frame again sent the host a second solve per frame, which doubled the
/// solver load on the imaging machine and the traffic on its link; the client
/// takes the host's solve instead.
class HostFrameSolves {
  DateTime? mirroredFrame;
  final Map<String, FrameSolveVm> byPath = {};
}

final hostFrameSolvesProvider = Provider<HostFrameSolves>(
  (ref) => HostFrameSolves(),
);

final frameAutoSolveProvider =
    NotifierProvider<FrameAutoSolver, Map<DateTime, FrameSolveVm>>(
      FrameAutoSolver.new,
    );

class FrameAutoSolver extends Notifier<Map<DateTime, FrameSolveVm>> {
  DateTime? _inFlight;
  CapturedImageData? _queued;

  /// The last frame that solved, as the hint for the next one: consecutive
  /// frames point at the same field, and a near solve is much faster than
  /// a blind one.
  FrameSolveVm? _lastSolved;

  @override
  Map<DateTime, FrameSolveVm> build() {
    ref.listen<CapturedImageData?>(
      currentImageProvider,
      (_, next) => _consider(next),
    );
    // The frame already on screen when this is first read. Not through
    // fireImmediately: that runs inside build, before there is a state to
    // record the solve in.
    scheduleMicrotask(() => _consider(ref.read(currentImageProvider)));
    return const <DateTime, FrameSolveVm>{};
  }

  static bool _isLight(CapturedImageData image) =>
      image.settings.frameType == FrameType.light ||
      image.settings.frameType == FrameType.snapshot;

  bool _isCurrent(DateTime key) =>
      ref.read(currentImageProvider)?.capturedAt == key;

  void _consider(CapturedImageData? image) {
    if (image == null || !_isLight(image)) return;
    final path = image.filePath;
    if (path == null || path.isEmpty) return;
    final key = image.capturedAt;
    if (state.containsKey(key)) return;
    final host = ref.read(hostFrameSolvesProvider);
    if (host.mirroredFrame == key) {
      // The host is solving this frame; its result arrives on its own.
      final solved = host.byPath[path];
      _put(
        solved == null
            ? FrameSolveVm(
                frameCapturedAt: key,
                status: FrameSolveStatus.waiting,
              )
            : solved.forFrame(key),
      );
      return;
    }
    _put(FrameSolveVm(frameCapturedAt: key, status: FrameSolveStatus.waiting));
    if (_inFlight != null) {
      final replaced = _queued;
      if (replaced != null) _remove(replaced.capturedAt);
      _queued = image;
      return;
    }
    unawaited(_solve(image));
  }

  Future<void> _solve(CapturedImageData image) async {
    final key = image.capturedAt;
    final path = image.filePath!;
    _inFlight = key;
    try {
      final saved = await _savedSolution(path);
      if (saved != null) {
        _put(
          FrameSolveVm(
            frameCapturedAt: key,
            status: FrameSolveStatus.solved,
            raDegrees: saved.raDegrees,
            decDegrees: saved.decDegrees,
            rotationDeg: saved.rotationDeg,
            pixelScaleArcsec: saved.pixelScaleArcsec,
            fromSavedSolution: true,
          ),
        );
        return;
      }
      if (!_isCurrent(key)) {
        _remove(key);
        return;
      }
      _put(
        FrameSolveVm(frameCapturedAt: key, status: FrameSolveStatus.solving),
      );
      final (hintRa, hintDec) = _hint();
      final result = await ref.read(backgroundFrameSolverProvider)(
        imagePath: path,
        isCurrent: () => _isCurrent(key),
        hintRaHours: hintRa,
        hintDecDegrees: hintDec,
      );
      if (result == null) {
        _remove(key);
        return;
      }
      if (result.success &&
          result.pixelScale.isFinite &&
          result.pixelScale > 0 &&
          result.ra.isFinite &&
          result.dec.isFinite) {
        final solved = FrameSolveVm(
          frameCapturedAt: key,
          status: FrameSolveStatus.solved,
          raDegrees: result.ra,
          decDegrees: result.dec,
          rotationDeg: result.rotation,
          pixelScaleArcsec: result.pixelScale,
        );
        _lastSolved = solved;
        _put(solved);
        unawaited(ref.read(backgroundSolveRecorderProvider)(path, result));
      } else {
        _put(
          FrameSolveVm(
            frameCapturedAt: key,
            status: FrameSolveStatus.failed,
            message: result.success
                ? 'The solver returned no usable scale.'
                : (result.error ?? 'The solver found no solution.'),
          ),
        );
      }
    } on SolverNotAvailableError catch (e) {
      _put(
        FrameSolveVm(
          frameCapturedAt: key,
          status: FrameSolveStatus.noSolver,
          message: e.message,
        ),
      );
    } catch (e) {
      _put(
        FrameSolveVm(
          frameCapturedAt: key,
          status: FrameSolveStatus.failed,
          message: '$e',
        ),
      );
    } finally {
      _inFlight = null;
      final next = _queued;
      _queued = null;
      if (next != null) {
        if (_isCurrent(next.capturedAt)) {
          unawaited(_solve(next));
        } else {
          _remove(next.capturedAt);
        }
      }
    }
  }

  /// Record the imaging host's solve of the frame at [hostPath], for the
  /// frame on screen when it is that frame.
  void adoptHostSolve(String hostPath, FrameSolveVm solve) {
    final image = ref.read(currentImageProvider);
    if (image == null || image.filePath != hostPath) return;
    if (_inFlight == image.capturedAt) return;
    _put(solve.forFrame(image.capturedAt));
  }

  Future<SavedFrameSolution?> _savedSolution(String path) async {
    try {
      return await ref.read(savedFrameSolutionProvider)(path);
    } catch (e) {
      // A lookup failure only costs a solve; the frame is solved instead.
      ref
          .read(loggingServiceProvider)
          .warning(
            'Could not read the saved solve of $path, solving it: $e',
            source: 'FrameAutoSolver',
          );
      return null;
    }
  }

  /// RA hours and Dec degrees to start the search from: the last solved
  /// frame, else where the mount says it points.
  (double?, double?) _hint() {
    final last = _lastSolved;
    if (last != null && last.raDegrees != null && last.decDegrees != null) {
      return (last.raDegrees! / 15, last.decDegrees);
    }
    return ref.read(mountPointingHintProvider);
  }

  void _put(FrameSolveVm vm) {
    final next = LinkedHashMap<DateTime, FrameSolveVm>.of(state)
      ..remove(vm.frameCapturedAt)
      ..[vm.frameCapturedAt] = vm;
    while (next.length > _rememberedSolves) {
      final oldest = next.keys.first;
      if (oldest == _inFlight || oldest == _queued?.capturedAt) break;
      next.remove(oldest);
    }
    state = Map<DateTime, FrameSolveVm>.unmodifiable(next);
  }

  void _remove(DateTime key) {
    if (!state.containsKey(key)) return;
    state = Map<DateTime, FrameSolveVm>.unmodifiable(
      LinkedHashMap<DateTime, FrameSolveVm>.of(state)..remove(key),
    );
  }
}

/// The background solve of the frame on screen; null for a frame that is
/// not solved in the background (no file, or not a light frame).
final currentFrameSolveProvider = Provider<FrameSolveVm?>((ref) {
  final key = ref.watch(currentImageProvider.select((i) => i?.capturedAt));
  if (key == null) return null;
  return ref.watch(frameAutoSolveProvider.select((solves) => solves[key]));
});

// ---------------------------------------------------------------------------
// Star detection
// ---------------------------------------------------------------------------

/// Detects the stars in a FITS file, off the UI isolate.
typedef FrameStarDetector =
    Future<StarDetectionResult> Function(String filePath);

/// The native star detector, the same one that measures each frame's HFR.
final frameStarDetectorProvider = Provider<FrameStarDetector>((ref) {
  return (filePath) async {
    final result = await bridge.apiDetectStarsInFile(filePath: filePath);
    return StarDetectionResult(
      stars: <DetectedStar>[
        for (final s in result.stars)
          DetectedStar(
            x: s.x,
            y: s.y,
            flux: s.flux,
            hfr: s.hfr,
            fwhm: s.fwhm,
            peak: s.peak,
            background: s.background,
            snr: s.snr,
          ),
      ],
      starCount: result.starCount,
      medianHfr: result.medianHfr,
      medianFwhm: result.medianFwhm,
      medianSnr: result.medianSnr,
      background: result.background,
      noise: result.noise,
    );
  };
});

/// The stars of the frame on screen, detected while something watches.
///
/// Null while the frame has no file yet (its path arrives after the FITS is
/// written) and when no frame is shown. Watch it only while a star overlay is
/// on: each new frame runs one detection, and the result is dropped with the
/// last watcher.
final currentFrameStarsProvider =
    FutureProvider.autoDispose<StarDetectionResult?>((ref) async {
      final frame = ref.watch(
        currentImageProvider.select(
          (i) => i == null ? null : (i.capturedAt, i.filePath),
        ),
      );
      final path = frame?.$2;
      if (frame == null || path == null || path.isEmpty) return null;
      return ref.read(frameStarDetectorProvider)(path);
    });

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;

import '../../models/annotation_data.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import '../../models/imaging/imaging_models.dart';
import '../../providers/auto_stretch_provider.dart';
import '../../providers/equipment_provider.dart';
import '../../providers/imaging_provider.dart';
import '../annotation_service.dart';
import '../imaging_service.dart';
import '../logging_service.dart';
import '../plate_solve_service.dart';
import '../wcs/plate_solve_data_from_result.dart';

/// Builds catalog annotations for a captured frame given its plate solve.
///
/// This narrow seam exists because [AnnotationService.annotateImage] is an
/// extension method (`part of annotation_service.dart`) and therefore cannot
/// be overridden by subclassing for tests — extension calls bind to the static
/// type. Routing the orchestrator's annotation step through this typedef keeps
/// production behaviour identical (the default delegates straight to the real
/// service) while giving tests a clean override point.
typedef FirstLightAnnotator =
    Future<ImageAnnotation> Function({
      required String imagePath,
      required PlateSolveData plateSolve,
    });

/// Default annotator provider: delegates to the production
/// [AnnotationService]. Override [firstLightAnnotatorProvider] in tests to
/// supply a fake.
final firstLightAnnotatorProvider = Provider<FirstLightAnnotator>((ref) {
  return ({required String imagePath, required PlateSolveData plateSolve}) {
    return ref
        .read(annotationServiceProvider)
        .annotateImage(imagePath: imagePath, plateSolve: plateSolve);
  };
});

/// Stages of the one-click first-light "wow" flow.
///
/// The flow always advances forward through the happy-path stages; any stage
/// that throws short-circuits to [failed] with the real error attached. There
/// is no silent fallback — a stage that cannot do its job either advances the
/// state to a legitimately positive end ([success] with an explanatory note,
/// e.g. when no plate solver is configured) or fails loudly.
enum FirstLightPhase {
  /// Nothing has run yet.
  idle,

  /// Camera exposure in flight.
  exposing,

  /// Auto-stretch being applied to the captured frame for a punchy preview.
  stretching,

  /// Plate solver running against the captured frame.
  solving,

  /// Catalog annotations being built from a successful solve.
  annotating,

  /// The flow finished with a presentable result.
  success,

  /// A stage failed; [FirstLightState.errorMessage] carries the cause.
  failed,
}

/// Immutable snapshot of the first-light flow.
///
/// Every field reflects work that *actually completed* — `stretched`,
/// `annotated`, and `solveResult` are only set once the corresponding stage
/// genuinely succeeded. Nothing here is faked to make the UI look further
/// along than the real pipeline is.
class FirstLightState {
  /// Current stage of the flow.
  final FirstLightPhase phase;

  /// Exposure length used for the capture, in seconds. `null` until [run]
  /// begins.
  final double? exposureSeconds;

  /// Stable identifier of the captured frame (its on-disk file path when the
  /// host writes a file; otherwise a synthetic id). `null` until the capture
  /// completes.
  final String? capturedImageId;

  /// On-disk path of the captured frame, when the host wrote one. `null` for
  /// in-memory-only previews or before the capture completes.
  final String? capturedImagePath;

  /// `true` once auto-stretch has produced a stretched preview for the frame.
  final bool stretched;

  /// Plate-solve result. `null` when the solver was not configured (a
  /// non-failure end with [note] explaining how to enable it) or before the
  /// solve stage runs.
  final PlateSolveResult? solveResult;

  /// `true` once catalog annotations were built from a successful solve.
  final bool annotated;

  /// The raw error string when [phase] is [FirstLightPhase.failed]. `null`
  /// otherwise.
  final String? errorMessage;

  /// A positive, non-error explanatory message surfaced on a [success] end
  /// that skipped an optional stage — e.g. "plate solver not configured".
  /// `null` when the flow ran end-to-end with no caveats.
  final String? note;

  /// Driver protocol of the camera the flow ran against, derived from the
  /// connected camera's device id. Carried so a connection failure can hand
  /// the troubleshooter the correct protocol-specific remediation steps
  /// instead of guessing. `null` when no camera was connected when the flow
  /// started (the most common connection-failure case), in which case the
  /// troubleshooter falls back to its generic camera guidance.
  final DriverType? cameraDriverType;

  const FirstLightState({
    this.phase = FirstLightPhase.idle,
    this.exposureSeconds,
    this.capturedImageId,
    this.capturedImagePath,
    this.stretched = false,
    this.solveResult,
    this.annotated = false,
    this.errorMessage,
    this.note,
    this.cameraDriverType,
  });

  /// `true` while the flow is actively running a stage (i.e. not idle and not
  /// at a terminal phase).
  bool get isRunning =>
      phase != FirstLightPhase.idle &&
      phase != FirstLightPhase.success &&
      phase != FirstLightPhase.failed;

  /// `true` when the flow reached a terminal phase.
  bool get isTerminal =>
      phase == FirstLightPhase.success || phase == FirstLightPhase.failed;

  FirstLightState copyWith({
    FirstLightPhase? phase,
    double? exposureSeconds,
    String? capturedImageId,
    String? capturedImagePath,
    bool? stretched,
    PlateSolveResult? solveResult,
    bool? annotated,
    String? errorMessage,
    String? note,
    DriverType? cameraDriverType,
  }) {
    return FirstLightState(
      phase: phase ?? this.phase,
      exposureSeconds: exposureSeconds ?? this.exposureSeconds,
      capturedImageId: capturedImageId ?? this.capturedImageId,
      capturedImagePath: capturedImagePath ?? this.capturedImagePath,
      stretched: stretched ?? this.stretched,
      solveResult: solveResult ?? this.solveResult,
      annotated: annotated ?? this.annotated,
      errorMessage: errorMessage ?? this.errorMessage,
      note: note ?? this.note,
      cameraDriverType: cameraDriverType ?? this.cameraDriverType,
    );
  }

  @override
  String toString() =>
      'FirstLightState(phase: $phase, '
      'exposureSeconds: $exposureSeconds, '
      'capturedImageId: $capturedImageId, '
      'stretched: $stretched, '
      'solveSuccess: ${solveResult?.success}, '
      'annotated: $annotated, '
      'errorMessage: $errorMessage, note: $note)';
}

/// Thrown internally when a stage fails. Carries the real, user-facing
/// message; the controller maps it onto [FirstLightPhase.failed]. Never leaks
/// out of [FirstLightOrchestrator.run].
class _FirstLightStageError implements Exception {
  final String message;
  const _FirstLightStageError(this.message);
  @override
  String toString() => message;
}

/// Thrown internally when [FirstLightOrchestrator.cancel] latches mid-run.
///
/// Distinct from [_FirstLightStageError] because a cancel is not a failure:
/// it unwinds the flow back to idle rather than to
/// [FirstLightPhase.failed] with a "capture failed" message the operator did
/// not cause.
class _FirstLightCancelled implements Exception {
  const _FirstLightCancelled();
}

/// Chains the existing imaging, auto-stretch, plate-solve and annotation
/// services into a single guided "first light" flow.
///
/// Design rules:
///  * Every stage either advances the flow or surfaces its real error. There
///    are no silent fallbacks that fake success.
///  * The only stage allowed to "succeed without doing its work" is plate
///    solving, and only when no solver is configured: that is a legitimate,
///    expected setup state for a first-time user, so the flow ends in
///    [FirstLightPhase.success] with an explanatory [FirstLightState.note]
///    rather than an error.
///
/// The orchestrator emits state through [onState]; the controller wraps it so
/// the writes are mounted-guarded. Reusing the production providers
/// (`imagingServiceProvider`, `stretchedImageProvider`,
/// `plateSolveServiceProvider`, `annotationServiceProvider`) means the flow
/// behaves identically to the manual imaging-screen path and stays correct as
/// those services evolve.
class FirstLightOrchestrator {
  final Ref _ref;
  final void Function(FirstLightState) _onState;

  FirstLightOrchestrator(
    this._ref, {
    required void Function(FirstLightState) onState,
  }) : _onState = onState;

  LoggingService get _logger => _ref.read(loggingServiceProvider);

  /// Latched by [cancel] for the duration of one [run].
  bool _cancelRequested = false;

  /// Message shown on the positive end when ASTAP is not yet configured.
  static const solverNotConfiguredNote =
      'Plate solver not configured — set it up to label your image';

  /// Abort an in-flight run AT THE CAMERA.
  ///
  /// Without this there was no way to stop a first-light exposure at all:
  /// dismissing the flow left the sensor exposing with nothing holding a
  /// handle on it, so the camera stayed busy until the process was restarted.
  /// The abort is dispatched through the same [ImagingService] seam the
  /// exposure was started through — `cancelExposure` resolves the pending
  /// exposure completer AND sends the driver-level abort — and the latch
  /// short-circuits the remaining stages so a cancel during
  /// stretch/solve/annotate stops there too.
  void cancel() {
    if (_cancelRequested) return;
    _cancelRequested = true;
    _ref.read(imagingServiceProvider).cancelExposure();
  }

  void _throwIfCancelled() {
    if (_cancelRequested) throw const _FirstLightCancelled();
  }

  /// Run the full first-light flow for a single [exposureSeconds] exposure.
  ///
  /// Updates state at every stage. Never throws: a failed stage resolves to
  /// [FirstLightPhase.failed] with the real error string in
  /// [FirstLightState.errorMessage].
  Future<void> run({required double exposureSeconds}) async {
    if (exposureSeconds <= 0) {
      throw ArgumentError.value(
        exposureSeconds,
        'exposureSeconds',
        'First-light exposure length must be positive',
      );
    }

    // Fresh latch per run: a cancel belongs to the run it interrupted, and a
    // stale one would abort the next run before it started.
    _cancelRequested = false;

    var state = FirstLightState(
      phase: FirstLightPhase.exposing,
      exposureSeconds: exposureSeconds,
      // Capture the camera's driver protocol up-front so a connection failure
      // at any stage can hand the troubleshooter accurate, protocol-specific
      // remediation steps. Derived from the connected camera's device id; null
      // when no camera is connected.
      cameraDriverType: _activeCameraDriverType(),
    );
    _emit(state);

    try {
      // STAGE 1 — verify the camera is connected.
      _requireCameraConnected();

      // STAGE 2 — expose (snapshot) via the same imaging service the imaging
      // screen's snapshot button uses.
      final captured = await _expose(exposureSeconds);
      final imageId = _deriveImageId(captured);
      state = state.copyWith(
        capturedImageId: imageId,
        capturedImagePath: captured.filePath,
      );
      _emit(state);

      // STAGE 3 — auto-stretch the frame for a punchy first look.
      state = state.copyWith(phase: FirstLightPhase.stretching);
      _emit(state);
      await _autoStretch(captured);
      _throwIfCancelled();
      state = state.copyWith(stretched: true);
      _emit(state);

      // STAGE 4 — plate solve, only when a usable solver is configured.
      //
      // Gate on whether the user's selected solver can actually run. Auto may
      // use either engine; an explicit broken ASTAP selection must not be
      // masked by an unrelated astrometry.net install.
      final plateSolve = _ref.read(plateSolveServiceProvider);
      final detection = await _detect(plateSolve);
      _throwIfCancelled();

      if (!detection.selectedSolverReady) {
        // Legitimate positive end for a first-time user who hasn't set up a
        // solver yet. We do NOT fabricate a solve — solveResult stays null and
        // the note tells them how to unlock labelling.
        _logger.info(
          'First-light: selected plate solver is not usable; '
          'finishing without a solve.',
          source: 'FirstLight',
        );
        state = state.copyWith(
          phase: FirstLightPhase.success,
          note: solverNotConfiguredNote,
        );
        _emit(state);
        return;
      }

      state = state.copyWith(phase: FirstLightPhase.solving);
      _emit(state);
      final solveResult = await _solve(
        plateSolve,
        imagePath: captured.filePath,
      );
      _throwIfCancelled();
      state = state.copyWith(solveResult: solveResult);
      _emit(state);

      // STAGE 5 — build annotations from the successful solve.
      state = state.copyWith(phase: FirstLightPhase.annotating);
      _emit(state);
      await _annotate(captured, solveResult);
      state = state.copyWith(phase: FirstLightPhase.success, annotated: true);
      _emit(state);
    } on _FirstLightCancelled {
      // The operator stopped it; the exposure has already been aborted at the
      // camera by `cancel()`. Unwind to idle rather than to `failed`, so the
      // flow does not report a failure the operator caused deliberately.
      _logger.info(
        'First-light flow cancelled by the operator.',
        source: 'FirstLight',
      );
      _emit(const FirstLightState());
    } on _FirstLightStageError catch (e) {
      _logger.warning(
        'First-light flow failed: ${e.message}',
        source: 'FirstLight',
      );
      _emit(
        state.copyWith(phase: FirstLightPhase.failed, errorMessage: e.message),
      );
    } catch (e, st) {
      // Defensive: any unexpected exception from a stage still surfaces — it
      // must never be swallowed. The raw message is carried verbatim.
      _logger.error(
        'First-light flow failed unexpectedly: $e\n$st',
        source: 'FirstLight',
      );
      _emit(
        state.copyWith(
          phase: FirstLightPhase.failed,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  void _emit(FirstLightState state) => _onState(state);

  // Stage implementations.

  void _requireCameraConnected() {
    final camera = _ref.read(cameraStateProvider);
    if (camera.connectionState != DeviceConnectionState.connected) {
      throw const _FirstLightStageError(
        'No camera connected. Connect a camera on the Equipment screen, '
        'then start first light again.',
      );
    }
  }

  Future<CapturedImageData> _expose(double exposureSeconds) async {
    // Honour the user's current gain/offset/binning (set from the active
    // profile by the imaging screen) but pin the exposure length to the
    // requested first-light value and force a light frame.
    final base = _ref.read(exposureSettingsProvider);
    final settings = base.copyWith(
      exposureTime: exposureSeconds,
      frameType: FrameType.light,
    );

    final CapturedImageData? captured;
    try {
      captured = await _ref
          .read(imagingServiceProvider)
          .captureImage(settings: settings);
    } catch (e) {
      // A cancel takes the capture down through this same path; report it as a
      // cancel, not as "Capture failed".
      _throwIfCancelled();
      throw _FirstLightStageError('Capture failed: $e');
    }

    _throwIfCancelled();

    if (captured == null) {
      throw const _FirstLightStageError(
        'Capture failed: the camera returned no image. The exposure may have '
        'been cancelled or the camera disconnected mid-frame.',
      );
    }

    // Publish the frame so the rest of the app (preview, stretch, annotation
    // overlay) sees it exactly as a manual snapshot would.
    _ref.read(currentImageProvider.notifier).state = captured;
    _ref.read(lastImageStatsProvider.notifier).state = captured.stats;
    return captured;
  }

  Future<void> _autoStretch(CapturedImageData captured) async {
    try {
      // `stretchedImageProvider` watches `currentImageProvider` (set in
      // `_expose`) and produces the stretched RGBA buffer used by the preview.
      // Awaiting its future runs the stretch and surfaces any failure.
      await _ref.read(stretchedImageProvider.future);
    } catch (e) {
      throw _FirstLightStageError('Auto-stretch failed: $e');
    }
  }

  Future<PlateSolverDetectionResult> _detect(PlateSolveService service) async {
    try {
      final detection = await service.detect();
      final preference = await service.getConfig();
      return PlateSolverDetectionResult(
        astapReady: detection.astapReady,
        selectedSolverReady: detection.supports(preference.choice),
      );
    } catch (e) {
      throw _FirstLightStageError('Plate-solver detection failed: $e');
    }
  }

  /// Derive the connected camera's driver protocol from its device id prefix.
  ///
  /// Device ids are namespaced by protocol (`ascom:`, `alpaca:`, `indi:`,
  /// `native:`, `simulator:`), so the prefix is the authoritative protocol
  /// signal without a backend round-trip. Returns `null` when no camera is
  /// connected or the id is empty/unrecognised — the troubleshooter then uses
  /// its generic camera guidance rather than asserting a wrong protocol.
  DriverType? _activeCameraDriverType() {
    final deviceId = _ref.read(cameraStateProvider).deviceId;
    return driverTypeFromDeviceId(deviceId);
  }

  Future<PlateSolveResult> _solve(
    PlateSolveService service, {
    required String? imagePath,
  }) async {
    if (imagePath == null || imagePath.isEmpty) {
      throw const _FirstLightStageError(
        'Plate solve needs an image file on disk, but the capture produced '
        'an in-memory preview only. Enable saving frames to disk to plate '
        'solve first light.',
      );
    }

    final PlateSolveResult result;
    try {
      result = await service.solveWithFallback(imagePath: imagePath);
    } catch (e) {
      throw _FirstLightStageError('Plate solve failed: $e');
    }

    if (!result.success) {
      throw _FirstLightStageError(
        'Plate solve failed: ${result.error ?? 'no solution found'}',
      );
    }
    return result;
  }

  Future<void> _annotate(
    CapturedImageData captured,
    PlateSolveResult solveResult,
  ) async {
    final imagePath = captured.filePath;
    if (imagePath == null || imagePath.isEmpty) {
      // We only reach annotation after a successful solve, which itself
      // requires a file path; this is a defensive guard against future
      // refactors decoupling those preconditions.
      throw const _FirstLightStageError(
        'Cannot annotate: the captured frame has no file path on disk.',
      );
    }

    final plateSolveData = plateSolveDataFromResult(
      solveResult,
      imageWidth: captured.width,
      imageHeight: captured.height,
      fieldWidth: solveResult.fieldWidth > 0
          ? solveResult.fieldWidth
          : captured.width * solveResult.pixelScale / 3600.0,
      fieldHeight: solveResult.fieldHeight > 0
          ? solveResult.fieldHeight
          : captured.height * solveResult.pixelScale / 3600.0,
    );

    final ImageAnnotation annotation;
    try {
      final annotate = _ref.read(firstLightAnnotatorProvider);
      annotation = await annotate(
        imagePath: imagePath,
        plateSolve: plateSolveData,
      );
    } catch (e) {
      throw _FirstLightStageError('Annotation failed: $e');
    }

    // Publish the annotation so the preview overlay renders the labels, just
    // like the auto-annotate pipeline would.
    _ref.read(currentAnnotationProvider.notifier).state = annotation;
  }

  /// Derive a stable identifier for the captured frame. Prefer the on-disk
  /// file path (unique per capture); fall back to the capture timestamp when
  /// the frame is an in-memory-only preview so the id is never empty.
  String _deriveImageId(CapturedImageData captured) {
    final path = captured.filePath;
    if (path != null && path.isNotEmpty) {
      return path;
    }
    return 'inmemory-${captured.capturedAt.microsecondsSinceEpoch}';
  }
}

/// Minimal detection summary the orchestrator needs from the plate solver.
///
/// Keeping this tiny value type at the seam (rather than passing the full
/// `PlateSolverDetection`) keeps the orchestrator's contract narrow and makes
/// the "solver ready?" decision trivial to reason about in tests.
class PlateSolverDetectionResult {
  /// `true` when ASTAP plus a catalog are present. Retained for callers that
  /// care specifically about ASTAP readiness; the first-light solve gate keys
  /// off [selectedSolverReady].
  final bool astapReady;

  /// `true` when the user's explicit selection is usable. In Auto mode either
  /// ASTAP or astrometry.net satisfies this.
  final bool selectedSolverReady;

  const PlateSolverDetectionResult({
    required this.astapReady,
    required this.selectedSolverReady,
  });
}

/// Maps a namespaced device id (`ascom:…`, `alpaca:…`, `indi:…`, `native:…`,
/// `simulator:…`) to its [DriverType]. Returns `null` when the id is `null`,
/// empty, or carries an unrecognised prefix — callers treat that as "protocol
/// unknown" rather than guessing.
DriverType? driverTypeFromDeviceId(String? deviceId) {
  if (deviceId == null || deviceId.isEmpty) return null;
  final prefix = deviceId.split(':').first.toLowerCase();
  switch (prefix) {
    case 'ascom':
      return DriverType.ascom;
    case 'alpaca':
      return DriverType.alpaca;
    case 'indi':
      return DriverType.indi;
    case 'native':
      return DriverType.native;
    case 'simulator':
    case 'sim':
      return DriverType.simulator;
    default:
      return null;
  }
}

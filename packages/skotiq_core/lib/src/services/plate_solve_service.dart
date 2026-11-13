// ignore_for_file: unused_local_variable

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/skotiq_backend.dart';
import '../errors/error_text.dart';
import '../models/plate_solver.dart' as ps_model;
import '../providers/async_scope.dart';
import '../providers/backend_provider.dart';
import '../providers/profiles_provider.dart' show opticalConfigProvider;
import '../providers/settings_provider.dart';
import 'logging_service.dart';

final _kEmptyCoeffs = Float64List(0);

/// Thrown by `PlateSolveService.solveWithFallback()` when no plate solver
/// is reachable on disk. The settings UI catches this to render the
/// `PlateSolverRequiredBanner` rather than treating it as a generic error.
class SolverNotAvailableError implements Exception {
  final String message;
  const SolverNotAvailableError(this.message);

  @override
  String toString() => 'SolverNotAvailableError: $message';
}

/// What one solve is told. Which solver runs, and where it is installed, is the
/// host's persisted choice (`PlateSolverPreference`), read by the native side.
class PlateSolverConfig {
  final int timeoutSeconds;
  final double? searchRadius; // degrees
  final double? hintRa; // hours
  final double? hintDec; // degrees

  /// Field HEIGHT the frame covers, in degrees — the scale hint, distinct from
  /// [searchRadius] (which bounds WHERE to look, not how big the field is).
  ///
  /// ASTAP's `-fov` takes exactly this. Without it the solver has to determine
  /// the scale itself, which is the slow part of a solve and the part that
  /// fails on a sparse field, even though the app has known the scale since
  /// onboarding computed it from the optical train (`arcsec/px × height ÷
  /// 3600`).
  final double? fieldHeightDegrees;

  const PlateSolverConfig({
    this.timeoutSeconds = 60,
    this.searchRadius,
    this.hintRa,
    this.hintDec,
    this.fieldHeightDegrees,
  });
}

class PlateSolveService {
  final Ref _ref;
  final AsyncScope<SkotiqBackend> _host;
  final StateController<PlateSolveState> _stateController;
  bool _solveInFlight = false;
  Completer<void>? _solveFinished;

  /// The background solve running now, if any (see [solveInBackground]).
  Future<PlateSolveResult>? _backgroundSolve;

  PlateSolveService(this._ref)
    : _host = _ref.providerBackendScope(),
      _stateController = _ref.read(plateSolveStateProvider.notifier);

  /// Solve an image using the backend (works for both local and remote).
  ///
  /// Every solve — manual, framing, centering, or an unattended sequencer
  /// step — flows through here, so this is the single choke point where the
  /// outcome is recorded: [plateSolveStateProvider] is updated (so any UI can
  /// reflect "solving…" / last result) and the result is logged. The log line
  /// is the one place an unattended sequence's plate-solve outcome surfaces to
  /// the operator, who otherwise only saw a node flip green/red.
  Future<PlateSolveResult> solve(String imagePath, PlateSolverConfig config) {
    return _runExclusiveSolve(imagePath, () => _runSolve(imagePath, config));
  }

  Future<PlateSolveResult> _runExclusiveSolve(
    String imagePath,
    Future<PlateSolveResult> Function() operation,
  ) async {
    // A background solve of the frame on screen never turns an operator's
    // solve away: the operator's waits for it to finish, which is one solve
    // at most because the background queue keeps only the newest frame.
    while (_backgroundSolve != null) {
      try {
        await _backgroundSolve;
      } catch (_) {
        // Its outcome is its own caller's to report.
      }
    }
    if (_solveInFlight) {
      return _failureResult(
        'Another plate solve is already running. Wait for it to finish before '
        'starting a new solve.',
      );
    }

    _solveInFlight = true;
    final finished = _solveFinished = Completer<void>();
    try {
      _ref.read(plateSolveStateProvider.notifier).state = _ref
          .read(plateSolveStateProvider)
          .copyWith(isSolving: true, currentImage: imagePath);
      final result = await operation();
      if (_hasAuthority) _announceSolveResult(imagePath, result);
      return result;
    } finally {
      // Detection/configuration/backend errors can throw before a result
      // exists. Always release both the UI state and the process-local gate.
      try {
        if (_hasAuthority) {
          final state = _ref.read(plateSolveStateProvider);
          if (state.isSolving) {
            _ref.read(plateSolveStateProvider.notifier).state = state.copyWith(
              isSolving: false,
            );
          }
        }
      } finally {
        _solveInFlight = false;
        finished.complete();
      }
    }
  }

  bool get _hasAuthority => _host.isCurrent;

  void retire() {
    _solveInFlight = false;
    _stateController.state = const PlateSolveState();
  }

  Future<PlateSolveResult> _runSolve(
    String imagePath,
    PlateSolverConfig config,
  ) async {
    try {
      // Use backend's plateSolve - works for both local (FFI) and remote (Network)
      return await _host.value.plateSolve(
        imagePath: imagePath,
        // PlateSolverConfig is app-canonical HOURS; the native bridge and
        // sequencer DeviceOps contract take solver hints in DEGREES.
        ra: config.hintRa == null ? null : config.hintRa! * 15.0,
        dec: config.hintDec,
        fovDegrees: config.searchRadius,
        timeoutSeconds: config.timeoutSeconds,
      );
    } catch (e) {
      // The native solver's own answer is the one shown. A second solver in
      // Dart used to run here and reported a worse solution than the one the
      // native side would have (no `--crpix-center`, CD/PC rotation lost).
      return _failureResult('Plate solve failed: ${userFacingError(e)}');
    }
  }

  /// Every failed solve returns the same shape: zeroed astrometry, empty SIP
  /// coefficients, and the reason in [error]. Building it here keeps the 25
  /// fields in one place, so a new field on `PlateSolveResult` cannot be
  /// half-populated on some failure paths and not others.
  PlateSolveResult _failureResult(String error) {
    return PlateSolveResult(
      success: false,
      ra: 0,
      dec: 0,
      pixelScale: 0,
      rotation: 0,
      fieldWidth: 0,
      fieldHeight: 0,
      solveTimeSecs: 0,
      error: error,
      cd11: 0,
      cd12: 0,
      cd21: 0,
      cd22: 0,
      sipAOrder: 0,
      sipBOrder: 0,
      sipACoeffs: _kEmptyCoeffs,
      sipBCoeffs: _kEmptyCoeffs,
      sipApOrder: 0,
      sipBpOrder: 0,
      sipApCoeffs: _kEmptyCoeffs,
      sipBpCoeffs: _kEmptyCoeffs,
    );
  }

  /// Record the outcome of a solve: update the shared state provider and emit
  /// a log line so the result is visible app-wide (activity log) even when the
  /// caller is an unattended sequence with no inline UI of its own.
  void _announceSolveResult(String imagePath, PlateSolveResult result) {
    final state = _ref.read(plateSolveStateProvider);
    // A linked client can already hold this outcome from the host's broadcast
    // of the same solve; keeping that object stops identity-keyed listeners
    // from recording one solve twice.
    final previous = state.lastResult;
    final kept = previous != null && samePlateSolveOutcome(previous, result)
        ? previous
        : result;
    _ref.read(plateSolveStateProvider.notifier).state = state.copyWith(
      isSolving: false,
      lastResult: kept,
    );
    _logSolveResult(result);
  }

  void _logSolveResult(PlateSolveResult result, {String prefix = ''}) {
    final logging = _ref.read(loggingServiceProvider);
    if (result.success) {
      // `PlateSolveResult.ra` is in DEGREES on every solve path (FFI and
      // network host), so log it as degrees.
      logging.info(
        '${prefix}Plate solve succeeded: RA ${result.ra.toStringAsFixed(4)}° '
        'Dec ${result.dec.toStringAsFixed(4)}° · '
        'scale ${result.pixelScale.toStringAsFixed(2)}"/px · '
        'rot ${result.rotation.toStringAsFixed(1)}° · '
        '${result.solveTimeSecs.toStringAsFixed(1)}s',
        source: 'PlateSolveService',
      );
    } else {
      logging.warning(
        '${prefix}Plate solve failed: ${result.error ?? 'unknown error'}',
        source: 'PlateSolveService',
      );
    }
  }

  /// Probe disk for installed solvers + ASTAP catalog. Returns a snapshot
  /// the UI can render directly.
  ///
  /// Routed through the imaging backend so it runs against the machine that
  /// owns the solver binaries: locally on the host (FFI), and on the HOST
  /// (over HTTP) when this is a remote phone client. A phone that probes its
  /// own (empty) filesystem instead shows a false "Set up plate solver"
  /// banner. The host-side detection ultimately calls the Rust
  /// `api_platesolve_detect` so platform-specific path enumeration stays in
  /// one place (`platesolve/src/paths.rs`).
  Future<ps_model.PlateSolverDetection> detect() async {
    final logging = _ref.read(loggingServiceProvider);
    try {
      return await _host.value.detectPlateSolvers();
    } catch (e) {
      logging.error(
        'plate-solver detection failed: $e',
        source: 'PlateSolveService',
      );
      rethrow;
    }
  }

  /// Run the given solver binary's `--help` to confirm the install is
  /// healthy. Surfaces the version banner so the settings UI can display
  /// "ASTAP 2024.05.10" alongside the path.
  ///
  /// Routed through the backend so a remote phone verifies the binary on the
  /// HOST (where the path is meaningful), not on the phone.
  Future<ps_model.PlateSolverInfo> verify(String executablePath) async {
    final logging = _ref.read(loggingServiceProvider);
    try {
      return await _host.value.verifyPlateSolver(executablePath);
    } catch (e) {
      logging.warning(
        'plate-solver verify failed for $executablePath: $e',
        source: 'PlateSolveService',
      );
      rethrow;
    }
  }

  /// Load persisted plate-solver UX configuration. Falls back to defaults
  /// when no `platesolver.json` exists yet.
  ///
  /// Routed through the backend so the phone reads the HOST's persisted
  /// config rather than its own.
  Future<ps_model.PlateSolverPreference> getConfig() async {
    return _host.value.getPlateSolverConfig();
  }

  /// Persist plate-solver UX configuration. Invalidates the solver-
  /// availability cache so the next `is_plate_solver_available` call
  /// re-probes the filesystem with the new paths.
  ///
  /// Routed through the backend so the phone writes config to the HOST (the
  /// machine that actually runs the solver), not to the phone.
  Future<void> setConfig(ps_model.PlateSolverPreference pref) async {
    await _host.value.setPlateSolverConfig(pref);
  }

  /// Validate the selected solver before callers capture an image or move
  /// hardware. Centering uses this preflight so a missing executable/catalog
  /// fails immediately instead of wasting a camera exposure first.
  Future<void> ensureSolverAvailable() async {
    final detection = await detect();
    final pref = await getConfig();
    _validateSolverAvailability(detection, pref);
  }

  void _validateSolverAvailability(
    ps_model.PlateSolverDetection detection,
    ps_model.PlateSolverPreference pref,
  ) {
    switch (pref.choice) {
      case ps_model.PlateSolverChoice.astap:
        if (!detection.astapReady) {
          throw const SolverNotAvailableError(
            'ASTAP is selected but its executable or star catalog is not '
            'configured. Configure it in Settings → Plate Solving.',
          );
        }
        return;
      case ps_model.PlateSolverChoice.astrometry:
        if (detection.astrometryPath == null) {
          throw const SolverNotAvailableError(
            'Astrometry.net is selected but not installed. Configure it in '
            'Settings → Plate Solving.',
          );
        }
        return;
      case ps_model.PlateSolverChoice.auto:
        if (!detection.hasAnySolver) {
          throw const SolverNotAvailableError(
            'No usable plate solver configured. Set one up in Settings → Plate '
            'Solving.',
          );
        }
        return;
    }
  }

  /// Background annotations wait for interactive solves and keep only the
  /// current frame. File paths alone cannot identify an image: live-view FITS
  /// files are reused, so an older result must not be reused by path.
  Future<PlateSolveResult?> solveForAnnotation({
    required String imagePath,
    required bool Function() isCurrent,
    double? hintRaHours,
    double? hintDecDegrees,
  }) async {
    while (_solveInFlight) {
      await _solveFinished!.future;
      if (!_hasAuthority || !isCurrent()) return null;
    }
    if (!_hasAuthority || !isCurrent()) return null;
    return solveWithFallback(
      imagePath: imagePath,
      hintRaHours: hintRaHours,
      hintDecDegrees: hintDecDegrees,
    );
  }

  /// Solve the frame on screen in the background, so its overlays and its
  /// "Solved" readout need no button press.
  ///
  /// Unlike [solve] it neither shows as the operator's solve in
  /// [plateSolveStateProvider] nor competes with one: it waits while an
  /// operator's solve runs, and an operator's solve that arrives while it
  /// runs waits for it (see [_runExclusiveSolve]). The solver itself runs out
  /// of process (ASTAP or astrometry.net, under the native solve gate), so
  /// nothing here blocks the UI isolate. Returns null when [isCurrent] says
  /// the frame was replaced before the solve could start.
  ///
  /// Throws [SolverNotAvailableError] when no solver is set up.
  Future<PlateSolveResult?> solveInBackground({
    required String imagePath,
    required bool Function() isCurrent,
    double? hintRaHours,
    double? hintDecDegrees,
  }) async {
    while (_solveInFlight || _backgroundSolve != null) {
      final waitFor = _solveInFlight
          ? _solveFinished?.future
          : _backgroundSolve;
      try {
        await waitFor;
      } catch (_) {
        // Another caller's failure; this solve still runs.
      }
      if (!_hasAuthority || !isCurrent()) return null;
    }
    if (!_hasAuthority || !isCurrent()) return null;
    final run = _solveWithFallbackInternal(
      imagePath: imagePath,
      hintRaHours: hintRaHours,
      hintDecDegrees: hintDecDegrees,
    );
    _backgroundSolve = run;
    try {
      final result = await run;
      if (_hasAuthority) _logSolveResult(result, prefix: 'Background ');
      return result;
    } finally {
      if (identical(_backgroundSolve, run)) _backgroundSolve = null;
    }
  }

  /// Solve `imagePath` honouring the user's `PlateSolverChoice`.
  ///
  /// - `astap` runs ASTAP only. Failure surfaces verbatim.
  /// - `astrometry` runs astrometry.net only.
  /// - `auto` tries ASTAP first; on failure (and only if astrometry.net is
  ///   reachable) retries with astrometry.net so a missing/broken ASTAP
  ///   doesn't end the session.
  ///
  /// Throws `SolverNotAvailableError` when no solver matches the choice.
  /// Callers (centering dialog, framing wizard, polar alignment) catch
  /// this to render the "Set up plate solver" banner instead of treating
  /// it as a generic solver failure.
  Future<PlateSolveResult> solveWithFallback({
    required String imagePath,
    double? hintRaHours,
    double? hintDecDegrees,
    double? searchRadiusDegrees,
    int? timeoutSeconds,
  }) {
    return _runExclusiveSolve(
      imagePath,
      () => _solveWithFallbackInternal(
        imagePath: imagePath,
        hintRaHours: hintRaHours,
        hintDecDegrees: hintDecDegrees,
        searchRadiusDegrees: searchRadiusDegrees,
        timeoutSeconds: timeoutSeconds,
      ),
    );
  }

  Future<PlateSolveResult> _solveWithFallbackInternal({
    required String imagePath,
    double? hintRaHours,
    double? hintDecDegrees,
    double? searchRadiusDegrees,
    int? timeoutSeconds,
  }) async {
    await ensureSolverAvailable();

    // Fall back to the user-configured defaults (Settings → Plate Solving →
    // Solve parameters) when the caller doesn't pin an explicit value, so the
    // desktop solve path honours the same knobs as the headless handlers.
    final appSettings = _ref.read(appSettingsProvider).valueOrNull;
    final effectiveTimeout =
        timeoutSeconds ?? appSettings?.plateSolveTimeout ?? 60;
    final effectiveRadius =
        searchRadiusDegrees ?? appSettings?.plateSolveSearchRadius;
    final forceBlind = appSettings?.blindSolve ?? false;
    // Scale hint, from the optical train the operator configured: ASTAP's
    // `-fov` is the field HEIGHT in degrees, and `OpticalConfig.fieldOfView`
    // is that same number computed from focal length + sensor. The app has
    // had it since onboarding (it prints `1.29"/px` on the profile card) and
    // never told the solver — a whole session's log carried no `-fov` at all.
    // Read here rather than taken as a parameter so EVERY caller of this entry
    // (annotate, centering, framing, the polar wizard) hints identically.
    final fieldHeightDegrees = _ref
        .read(opticalConfigProvider)
        ?.fieldOfView
        ?.$2;
    final effectiveHintRa = forceBlind ? null : hintRaHours;
    final effectiveHintDec = forceBlind ? null : hintDecDegrees;

    // One backend solve, against the host's persisted solver choice: the
    // native host runs Auto's ASTAP -> astrometry.net ladder itself.
    return _runSolve(
      imagePath,
      PlateSolverConfig(
        timeoutSeconds: effectiveTimeout,
        searchRadius: effectiveRadius,
        hintRa: effectiveHintRa,
        hintDec: effectiveHintDec,
        fieldHeightDegrees: fieldHeightDegrees,
      ),
    );
  }
}

final plateSolveServiceProvider = Provider<PlateSolveService>((ref) {
  ref.watch(backendProvider);
  final service = PlateSolveService(ref);
  ref.onDispose(service.retire);
  return service;
});

/// Whether two results describe the same solve outcome.
///
/// `PlateSolveResult ==` compares its SIP coefficient lists by identity, so a
/// result that crossed the wire never equals the original; this compares the
/// fields a solve is identified by instead.
bool samePlateSolveOutcome(PlateSolveResult a, PlateSolveResult b) =>
    a.success == b.success &&
    a.ra == b.ra &&
    a.dec == b.dec &&
    a.pixelScale == b.pixelScale &&
    a.rotation == b.rotation &&
    a.solveTimeSecs == b.solveTimeSecs &&
    a.error == b.error;

class PlateSolveState {
  final bool isSolving;
  final PlateSolveResult? lastResult;
  final String? currentImage;

  const PlateSolveState({
    this.isSolving = false,
    this.lastResult,
    this.currentImage,
  });

  PlateSolveState copyWith({
    bool? isSolving,
    PlateSolveResult? lastResult,
    String? currentImage,
  }) {
    return PlateSolveState(
      isSolving: isSolving ?? this.isSolving,
      lastResult: lastResult ?? this.lastResult,
      currentImage: currentImage ?? this.currentImage,
    );
  }
}

final plateSolveStateProvider = StateProvider<PlateSolveState>((ref) {
  return const PlateSolveState();
});

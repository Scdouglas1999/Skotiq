// ignore_for_file: unused_local_variable

import 'dart:async';
import 'dart:convert' show LineSplitter;
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../backend/ffi_backend.dart' show FfiBackend;
import '../backend/network_backend.dart' show NetworkBackend;
import '../backend/skotiq_backend.dart';
import '../models/plate_solver.dart' as ps_model;
import '../providers/backend_provider.dart';
import '../providers/profiles_provider.dart' show opticalConfigProvider;
import '../providers/settings_provider.dart';
import 'logging_service.dart';

final _kEmptyCoeffs = Float64List(0);

/// Length of one FITS header card, fixed by the standard.
const int _fitsCardLength = 80;

/// Split a FITS header into its 80-character cards.
///
/// A `.wcs` file is a raw FITS header: fixed-width cards packed end to end
/// with **no line terminators at all**. Iterating it by line therefore yields
/// the whole header as one enormous "line", so only the very first card
/// (`SIMPLE`) is ever inspected and every keyword after it — `CRVAL1`,
/// `CDELT1/2`, `CROTA2` — is invisible. ASTAP would solve, the parse would then
/// report the solution as missing `CRVAL1`, and the caller counted a successful
/// solve as a failed one.
///
/// Newlines are still honoured first, because some solvers (and this repo's own
/// fixtures) do write one card per line; only segments longer than a single card
/// are split further. This mirrors `fits_header_cards` in
/// `native/skotiq_native/imaging/src/platesolve.rs`.
List<String> _fitsHeaderCards(String content) {
  final cards = <String>[];
  for (final segment in const LineSplitter().convert(content)) {
    if (segment.length <= _fitsCardLength) {
      cards.add(segment);
      continue;
    }
    for (var start = 0; start < segment.length; start += _fitsCardLength) {
      final end = (start + _fitsCardLength).clamp(0, segment.length);
      cards.add(segment.substring(start, end));
    }
  }
  return cards;
}

/// Test seam over [_fitsHeaderCards]. The card split is the half of the `.wcs`
/// contract that is genuinely identical in both languages, so it is pinned
/// against the Rust `fits_header_cards` by the shared golden fixture in
/// `test_fixtures/wcs_conformance/` (see
/// `packages/skotiq_core/test/services/wcs_conformance_test.dart`).
@visibleForTesting
List<String> fitsHeaderCardsForTest(String content) =>
    _fitsHeaderCards(content);

/// Thrown by `PlateSolveService.solveWithFallback()` when no plate solver
/// is reachable on disk. The settings UI catches this to render the
/// `PlateSolverRequiredBanner` rather than treating it as a generic error.
class SolverNotAvailableError implements Exception {
  final String message;
  const SolverNotAvailableError(this.message);

  @override
  String toString() => 'SolverNotAvailableError: $message';
}

/// Plate solver type
enum PlateSolverType { astap, astrometryNet }

/// Plate solver configuration
class PlateSolverConfig {
  final PlateSolverType type;
  final String executablePath;
  final String? catalogPath;
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
    required this.type,
    required this.executablePath,
    this.catalogPath,
    this.timeoutSeconds = 60,
    this.searchRadius,
    this.hintRa,
    this.hintDec,
    this.fieldHeightDegrees,
  });
}

class _SolverProcessResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const _SolverProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

/// Plate solve service
class PlateSolveService {
  final Ref _ref;
  final SkotiqBackend _backend;
  final StateController<PlateSolveState> _stateController;
  bool _solveInFlight = false;
  Completer<void>? _solveFinished;
  bool _retired = false;

  /// The background solve running now, if any (see [solveInBackground]).
  Future<PlateSolveResult>? _backgroundSolve;

  PlateSolveService(this._ref, {SkotiqBackend? backend})
    : _backend = backend ?? _ref.read(backendProvider),
      _stateController = _ref.read(plateSolveStateProvider.notifier);

  /// Test seam: parse an ASTAP `.wcs` sidecar. Pins the unit contract
  /// (RA in degrees). Delegates to the private parser used by the local
  /// ASTAP fallback.
  @visibleForTesting
  Future<PlateSolveResult> parseWcsFileForTest(String wcsPath) =>
      _parseWcsFile(wcsPath);

  /// Test seam: parse astrometry.net console output. Pins the unit contract
  /// (RA in degrees).
  @visibleForTesting
  PlateSolveResult parseAstrometryOutputForTest(String output) =>
      _parseAstrometryOutput(output);

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

  bool get _hasAuthority =>
      !_retired && identical(_ref.read(backendProvider), _backend);

  void retire() {
    if (_retired) return;
    _retired = true;
    _solveInFlight = false;
    _stateController.state = const PlateSolveState();
  }

  Future<PlateSolveResult> _runSolve(
    String imagePath,
    PlateSolverConfig config,
  ) async {
    try {
      // Use backend's plateSolve - works for both local (FFI) and remote (Network)
      return await _backend.plateSolve(
        imagePath: imagePath,
        // PlateSolverConfig is app-canonical HOURS; the native bridge and
        // sequencer DeviceOps contract take solver hints in DEGREES.
        ra: config.hintRa == null ? null : config.hintRa! * 15.0,
        dec: config.hintDec,
        fovDegrees: config.searchRadius,
        timeoutSeconds: config.timeoutSeconds,
      );
    } catch (e) {
      // A NetworkBackend runs the solver on the desktop host. Its executable
      // path and image path are not meaningful on the remote client, so a
      // transport/backend failure must be surfaced instead of trying to spawn
      // that binary on the phone's local filesystem.
      if (_backend is NetworkBackend) {
        return _failureResult('Remote host plate solve failed: $e');
      }

      final fallbackResult = await _solveLocally(imagePath, config);
      if (fallbackResult.success) {
        return fallbackResult;
      }

      return _failureResult(
        'Backend solve failed: $e. Local fallback failed: '
        '${fallbackResult.error ?? 'unknown error'}',
      );
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

  /// The success counterpart of [_failureResult]. The local fallback parsers
  /// recover position and (for ASTAP) scale/rotation only; the CD matrix and
  /// SIP terms come from the native solver, so they stay zeroed here.
  PlateSolveResult _successResult({
    required double ra,
    required double dec,
    double pixelScale = 0,
    double rotation = 0,
  }) {
    return PlateSolveResult(
      success: true,
      ra: ra,
      dec: dec,
      pixelScale: pixelScale,
      rotation: rotation,
      fieldWidth: 0,
      fieldHeight: 0,
      solveTimeSecs: 0,
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

  /// Run a local solver while retaining a process handle so timeout can
  /// actually terminate it. `Process.run(...).timeout(...)` only abandons the
  /// Dart Future; the solver keeps running and can write a stale solution after
  /// the caller has already reported failure.
  Future<_SolverProcessResult> _runSolverProcess(
    String executable,
    List<String> args, {
    String? workingDirectory,
    required Duration timeout,
  }) async {
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
    );
    final stdoutFuture = systemEncoding
        .decodeStream(process.stdout)
        .catchError((Object _) => '');
    final stderrFuture = systemEncoding
        .decodeStream(process.stderr)
        .catchError((Object _) => '');

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      await _terminateSolverProcess(process);
      throw TimeoutException('Plate solve timed out', timeout);
    }

    return _SolverProcessResult(
      exitCode: exitCode,
      stdout: await stdoutFuture,
      stderr: await stderrFuture,
    );
  }

  Future<void> _terminateSolverProcess(Process process) async {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
      return;
    } on TimeoutException {
      if (!Platform.isWindows) {
        process.kill(ProcessSignal.sigkill);
      }
      await process.exitCode.timeout(const Duration(seconds: 2));
    }
  }

  /// Record the outcome of a solve: update the shared state provider and emit
  /// a log line so the result is visible app-wide (activity log) even when the
  /// caller is an unattended sequence with no inline UI of its own.
  void _announceSolveResult(String imagePath, PlateSolveResult result) {
    _ref.read(plateSolveStateProvider.notifier).state = _ref
        .read(plateSolveStateProvider)
        .copyWith(isSolving: false, lastResult: result);
    _logSolveResult(result);
  }

  void _logSolveResult(PlateSolveResult result, {String prefix = ''}) {
    final logging = _ref.read(loggingServiceProvider);
    if (result.success) {
      // `PlateSolveResult.ra` is in DEGREES across every solve path (FFI,
      // network host, and the local fallback parsers), so log it as degrees.
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

  /// Local fallback solver
  Future<PlateSolveResult> _solveLocally(
    String imagePath,
    PlateSolverConfig config,
  ) async {
    switch (config.type) {
      case PlateSolverType.astap:
        return _solveWithAstap(imagePath, config);
      case PlateSolverType.astrometryNet:
        return _solveWithAstrometryNet(imagePath, config);
    }
  }

  /// Solve with ASTAP.
  ///
  /// Argument list mirrors the native Rust solver in
  /// `imaging/src/platesolve.rs` so this Dart fallback is a *real* solve and
  /// not a no-op that silently masks a backend failure:
  ///   * `-f <image>`        — input frame.
  ///   * `-ra` / `-spd`      — hint position (RA in degrees, south-pole
  ///                           distance) when a hint is supplied.
  ///   * `-r <deg>`          — search radius.
  ///   * `-d <catalog dir>`  — REQUIRED when the user configured a catalog
  ///                           directory; without it ASTAP cannot match stars
  ///                           and never writes a `.wcs`.
  ///   * `-wcs`              — REQUIRED so ASTAP emits the `.wcs` sidecar this
  ///                           parser reads. Without it ASTAP runs, writes
  ///                           nothing, and the missing sidecar reads as "No
  ///                           WCS file created" rather than the real error.
  Future<PlateSolveResult> _solveWithAstap(
    String imagePath,
    PlateSolverConfig config,
  ) async {
    try {
      // Delete any stale `.wcs` from a previous solve before invoking ASTAP.
      // Otherwise a no-op run (e.g. ASTAP failing to match) would "succeed"
      // by parsing the previous frame's sidecar — a silent, wrong-answer
      // fallback, which we forbid. The presence of a freshly written
      // `.wcs` is our only proof the solve actually ran.
      final wcsPath = imagePath.replaceAll(RegExp(r'\.[^.]+$'), '.wcs');
      final wcsFile = File(wcsPath);
      if (await wcsFile.exists()) {
        await wcsFile.delete();
      }

      final args = astapArguments(imagePath, config);

      final result = await _runSolverProcess(
        config.executablePath,
        args,
        workingDirectory: File(imagePath).parent.path,
        timeout: Duration(seconds: config.timeoutSeconds),
      );

      if (result.exitCode != 0) {
        return _failureResult(
          'ASTAP failed (exit ${result.exitCode}): ${result.stderr}',
        );
      }

      // Parse the .wcs file that ASTAP creates
      if (await wcsFile.exists()) {
        return _parseWcsFile(wcsPath);
      }

      return _failureResult(
        'ASTAP exited 0 but wrote no WCS file '
        '(no star match within search radius). stdout: '
        '${result.stdout.toString().trim()}',
      );
    } on TimeoutException {
      return _failureResult('Plate solve timed out');
    } catch (e) {
      return _failureResult('Error: $e');
    }
  }

  /// The exact ASTAP command line for [imagePath] under [config].
  ///
  /// Exposed (and tested) on its own because the hints are the difference
  /// between a solve that lands in a second and one that grinds or fails: an
  /// app that computes `1.29"/px` during onboarding, prints it on the profile
  /// card, and never passes it to the solver leaves `grep -i fov` over a whole
  /// session's log empty.
  ///
  /// **This is the FALLBACK path, not the one production runs.** Every normal
  /// solve goes through the backend to Rust and the argument vector is built by
  /// `platesolve.rs::build_astap_args`; this local spawn only happens when the
  /// backend call throws. A change to the solver's arguments therefore has to
  /// land in the Rust builder — and be pinned by its `astap_arg_tests` — before
  /// it means anything on a rig.
  @visibleForTesting
  static List<String> astapArguments(
    String imagePath,
    PlateSolverConfig config,
  ) {
    final args = <String>[
      '-f',
      imagePath,
      '-r',
      (config.searchRadius ?? 30).toString(),
    ];

    if (config.hintRa != null && config.hintDec != null) {
      args.addAll([
        // ASTAP's CLI takes -ra in hours (unlike astrometry.net and the
        // Skotiq native bridge, which take degree hints).
        '-ra', config.hintRa!.toString(),
        '-spd', (config.hintDec! + 90).toString(), // South pole distance
      ]);
    }

    // Scale hint: ASTAP's `-fov` is the field HEIGHT in degrees. `0` means
    // "work it out yourself", which is what omitting the flag already meant,
    // so only a positive, finite value is worth sending.
    final fov = config.fieldHeightDegrees;
    if (fov != null && fov.isFinite && fov > 0) {
      args.addAll(['-fov', fov.toStringAsFixed(4)]);
    }

    // Point ASTAP at the configured star catalog. ASTAP cannot solve
    // without one; when the user configured a catalog directory we must
    // pass it explicitly via `-d`.
    if (config.catalogPath != null && config.catalogPath!.isNotEmpty) {
      args.addAll(['-d', config.catalogPath!]);
    }

    // Tell ASTAP to write the `.wcs` sidecar that `_parseWcsFile` reads.
    args.add('-wcs');
    return args;
  }

  /// Solve with Astrometry.net (local)
  Future<PlateSolveResult> _solveWithAstrometryNet(
    String imagePath,
    PlateSolverConfig config,
  ) async {
    try {
      final args = <String>[imagePath, '--no-plots', '--overwrite'];

      if (config.searchRadius != null) {
        args.addAll(['--radius', config.searchRadius.toString()]);
      }

      if (config.hintRa != null && config.hintDec != null) {
        args.addAll([
          '--ra',
          (config.hintRa! * 15).toString(),
          '--dec',
          config.hintDec.toString(),
        ]);
      }

      final result = await _runSolverProcess(
        config.executablePath,
        args,
        timeout: Duration(seconds: config.timeoutSeconds),
      );

      if (result.exitCode != 0) {
        return _failureResult('Astrometry.net failed: ${result.stderr}');
      }

      // Parse the output
      final output = result.stdout.toString();
      return _parseAstrometryOutput(output);
    } on TimeoutException {
      return _failureResult('Plate solve timed out');
    } catch (e) {
      return _failureResult('Error: $e');
    }
  }

  Future<PlateSolveResult> _parseWcsFile(String wcsPath) async {
    try {
      final content = await File(wcsPath).readAsString();

      double? crval1, crval2, cdelt1, cdelt2, crota2;

      for (final line in _fitsHeaderCards(content)) {
        if (line.startsWith('CRVAL1')) {
          crval1 = _parseWcsValue(line);
        } else if (line.startsWith('CRVAL2')) {
          crval2 = _parseWcsValue(line);
        } else if (line.startsWith('CDELT1')) {
          cdelt1 = _parseWcsValue(line);
        } else if (line.startsWith('CDELT2')) {
          cdelt2 = _parseWcsValue(line);
        } else if (line.startsWith('CROTA2')) {
          crota2 = _parseWcsValue(line);
        }
      }

      if (crval1 != null && crval2 != null) {
        // RA stays in DEGREES to match `PlateSolveResult.ra` from the
        // dominant FFI/network host path (Rust `PlateSolveResult.ra` reads
        // FITS `CRVAL1` verbatim — degrees). Downstream consumers
        // (CenteringService) normalise degrees→hours themselves; emitting
        // hours here would feed them a 15x-wrong RA.
        return _successResult(
          ra: crval1,
          dec: crval2,
          rotation: crota2 ?? 0,
          pixelScale: cdelt1 != null ? cdelt1.abs() * 3600 : 0,
        );
      }

      return _failureResult('Could not parse WCS file');
    } catch (e) {
      return _failureResult('Error parsing WCS: $e');
    }
  }

  double? _parseWcsValue(String line) {
    final parts = line.split('=');
    if (parts.length >= 2) {
      final valueStr = parts[1].split('/')[0].trim();
      return double.tryParse(valueStr);
    }
    return null;
  }

  PlateSolveResult _parseAstrometryOutput(String output) {
    // Parse astrometry.net console output
    final raMatch = RegExp(r'RA,Dec = \(([^,]+),([^)]+)\)').firstMatch(output);
    if (raMatch != null) {
      final ra = double.tryParse(raMatch.group(1)!);
      final dec = double.tryParse(raMatch.group(2)!);

      if (ra != null && dec != null) {
        // astrometry.net's `RA,Dec = (...)` line is in DEGREES; keep it in
        // degrees to match the canonical `PlateSolveResult.ra` contract.
        return _successResult(ra: ra, dec: dec);
      }
    }

    return _failureResult('Could not parse solution');
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
  /// one place (`platesolve_paths.rs`).
  Future<ps_model.PlateSolverDetection> detect() async {
    final logging = _ref.read(loggingServiceProvider);
    try {
      return await _backend.detectPlateSolvers();
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
      return await _backend.verifyPlateSolver(executablePath);
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
    return _backend.getPlateSolverConfig();
  }

  /// Persist plate-solver UX configuration. Invalidates the solver-
  /// availability cache so the next `is_plate_solver_available` call
  /// re-probes the filesystem with the new paths.
  ///
  /// Routed through the backend so the phone writes config to the HOST (the
  /// machine that actually runs the solver), not to the phone.
  Future<void> setConfig(ps_model.PlateSolverPreference pref) async {
    await _backend.setPlateSolverConfig(pref);
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
    final logging = _ref.read(loggingServiceProvider);
    final detection = await detect();
    final pref = await getConfig();
    _validateSolverAvailability(detection, pref);

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

    // FFI and Network backends both execute against the host's persisted
    // solver choice. The native host performs Auto's ASTAP→astrometry fallback
    // under its process-wide gate, so issue exactly one backend solve rather
    // than accidentally running ASTAP twice when the first attempt fails.
    final activeBackend = _backend;
    if (activeBackend is FfiBackend || activeBackend is NetworkBackend) {
      final executable = switch (pref.choice) {
        ps_model.PlateSolverChoice.astrometry => detection.astrometryPath!,
        ps_model.PlateSolverChoice.astap => detection.astapPath!,
        ps_model.PlateSolverChoice.auto =>
          detection.astapReady
              ? detection.astapPath!
              : detection.astrometryPath!,
      };
      final type = pref.choice == ps_model.PlateSolverChoice.astrometry
          ? PlateSolverType.astrometryNet
          : PlateSolverType.astap;
      return _runSolve(
        imagePath,
        PlateSolverConfig(
          type: type,
          executablePath: executable,
          catalogPath: detection.catalogPath,
          timeoutSeconds: effectiveTimeout,
          searchRadius: effectiveRadius,
          hintRa: effectiveHintRa,
          hintDec: effectiveHintDec,
          fieldHeightDegrees: fieldHeightDegrees,
        ),
      );
    }

    Future<PlateSolveResult> runAstap() async {
      if (detection.astapPath == null) {
        return _failureResult('ASTAP not installed at any known location.');
      }
      if (!detection.astapReady) {
        return _failureResult('ASTAP star catalog not configured.');
      }
      final config = PlateSolverConfig(
        type: PlateSolverType.astap,
        executablePath: detection.astapPath!,
        catalogPath: detection.catalogPath,
        timeoutSeconds: effectiveTimeout,
        searchRadius: effectiveRadius,
        hintRa: effectiveHintRa,
        hintDec: effectiveHintDec,
        fieldHeightDegrees: fieldHeightDegrees,
      );
      return _runSolve(imagePath, config);
    }

    Future<PlateSolveResult> runAstrometry() async {
      if (detection.astrometryPath == null) {
        return _failureResult('Astrometry.net (solve-field) not installed.');
      }
      final config = PlateSolverConfig(
        type: PlateSolverType.astrometryNet,
        executablePath: detection.astrometryPath!,
        timeoutSeconds: effectiveTimeout,
        searchRadius: effectiveRadius,
        hintRa: effectiveHintRa,
        hintDec: effectiveHintDec,
        fieldHeightDegrees: fieldHeightDegrees,
      );
      return _runSolve(imagePath, config);
    }

    switch (pref.choice) {
      case ps_model.PlateSolverChoice.astap:
        return runAstap();
      case ps_model.PlateSolverChoice.astrometry:
        return runAstrometry();
      case ps_model.PlateSolverChoice.auto:
        if (detection.astapReady) {
          final astapResult = await runAstap();
          if (astapResult.success) return astapResult;
          if (detection.astrometryPath != null) {
            logging.warning(
              'ASTAP failed (${astapResult.error}); falling back '
              'to astrometry.net',
              source: 'PlateSolveService',
            );
            return runAstrometry();
          }
          return astapResult;
        }
        return runAstrometry();
    }
  }
}

/// Plate solve service provider
final plateSolveServiceProvider = Provider<PlateSolveService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = PlateSolveService(ref, backend: backend);
  ref.onDispose(service.retire);
  return service;
});

/// Active plate solve state
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

/// Plate solve state provider
final plateSolveStateProvider = StateProvider<PlateSolveState>((ref) {
  return const PlateSolveState();
});

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;

import '../database/daos/integrated_masters_dao.dart';
import '../database/database.dart';
import '../models/imaging/integrated_master.dart';
import '../models/imaging/integration_curve.dart';
import '../models/imaging/integration_settings.dart';
import '../models/calibration/calibration_library_models.dart';
import 'calibration_library_service.dart';
import 'darkroom_pass/pass_log.dart';
import 'darkroom_pass/pass_providers.dart' show passReporterProvider;
import 'color_calibration_service.dart';
import 'plate_solve_service.dart';
import 'post_session_seam.dart';
import 'wcs_overlay.dart';
part 'post_session_integration_service/integration_models.dart';
part 'post_session_integration_service/path_helpers.dart';
part 'post_session_integration_service/integration_stages.dart';
part 'post_session_integration_service/integration_helpers.dart';

/// Orchestrates the **batch, offline** post-session integration pipeline that
/// produces an archival-quality linear FITS master from a collection of
/// captured subs (one session, one target, possibly across nights).
///
/// This is the *finishing* path — deliberately distinct from the *live*
/// `StackAndShareService` / `LiveStacker` singleton. It is stateless per call
/// (no process-wide engine), routes through the [PostSessionSeam] (native
/// `api_integrate_session`), and is safe to run while a live session is active.
///
/// Pipeline per filter group:
///  1. **Select** accepted light subs (the caller passes pre-selected
///     [CapturedImage]s — typically from `StackLightSelector`).
///  2. **Resolve calibration** masters: dark and flat via
///     [CalibrationLibraryService.match], bias via the supplied
///     [ResolvedCalibration] override.
///  3. **Build the native args** (sub paths + calibration + settings + output
///     paths) and invoke the seam.
///  4. **Persist** an `integrated_masters` row (status `finalized`, mode
///     `batch`) plus an `integrated_master_frames` fold record per sub.
///
/// The native side writes the 16-bit/float linear FITS master and stretched
/// preview PNG directly (no lossy float→u16 round-trip through Dart).
class PostSessionIntegrationService {
  PostSessionIntegrationService({
    required IntegratedMastersDao mastersDao,
    required CalibrationLibraryService calibrationLibrary,
    required PostSessionSeam seam,
    MasterPlateSolver? plateSolver,
    MasterColorCalibrator? colorCalibrator,
    PassReporter? passReporter,
  }) : _passReporter = passReporter,
       _mastersDao = mastersDao,
       _calibrationLibrary = calibrationLibrary,
       _seam = seam,
       _plateSolver = plateSolver,
       _colorCalibrator = colorCalibrator;

  final IntegratedMastersDao _mastersDao;

  /// Where the pass this integration belongs to is reported, for the
  /// Darkroom pass view. Null reports nothing.
  final PassReporter? _passReporter;
  final PostSessionSeam _seam;

  /// The single matcher for un-pinned masters: its transparent scoring drives
  /// the auto-pick and its warnings are propagated into the outcome, so what
  /// the operator reads about a calibration decision is what actually happened.
  final CalibrationLibraryService _calibrationLibrary;

  /// Optional fail-soft plate-solver for the finished master FITS, injected at
  /// the provider boundary (where the `PlateSolveService` Riverpod `_ref`
  /// lives). When null, WCS persistence is skipped gracefully — annotation /
  /// colour calibration stay un-lit, but the master persist is unaffected.
  final MasterPlateSolver? _plateSolver;

  /// Optional fail-soft catalog colour calibrator for the finished master FITS,
  /// injected at the provider boundary (where the `ColorCalibrationService` +
  /// on-disk star catalog live). Invoked only when `settings.colorCalibrate` is
  /// set AND the master has a solved WCS (the projection it needs to place
  /// detections on the sky). When null, the colour-calibration gate is skipped
  /// gracefully — never aborting the master persist.
  final MasterColorCalibrator? _colorCalibrator;

  /// Filter-bucket name used for subs captured without a filter recorded. Kept
  /// in lock-step with `StackLightSelector.noFilterBucket`.
  static const String noFilterBucket = '(none)';

  /// Integrate the accepted light [subs], grouped by filter, into one master per
  /// filter.
  ///
  /// [subs] must be the *accepted* light frames (the caller applies the
  /// `StackLightSelector` gates). [outputPathBuilder] maps a filter bucket to
  /// the output FITS / preview / rejection-map base path: it returns the master
  /// FITS path; the preview and rejection map are derived by extension swap.
  /// [biasPath] is the optional master-bias override applied to every group.
  ///
  /// Returns one [PostSessionIntegrationOutcome] per non-empty filter group.
  /// Throws [ArgumentError] when [subs] is empty.
  Future<List<PostSessionIntegrationOutcome>> integrate({
    required List<CapturedImage> subs,
    required IntegrationSettings settings,
    required String Function(String filterBucket) outputFitsPathBuilder,
    int? targetId,
    String? targetName,
    String? biasPath,
    ResolvedCalibration? pinnedCalibration,
    bool generatePreview = true,
    double? hintRaHours,
    double? hintDecDegrees,
    String? runId,
    int? sessionId,
    int plannedDrafts = 0,
    bool closePass = true,
    String? passTitle,
  }) async {
    if (subs.isEmpty) {
      throw ArgumentError.value(subs, 'subs', 'must not be empty');
    }

    final groups = _groupByFilter(subs);
    final outcomes = <PostSessionIntegrationOutcome>[];

    // The pass view groups every report of this call under one run id, so a
    // call without one gets its own.
    final reporter = _passReporter;
    final passRunId = (runId != null && runId.isNotEmpty)
        ? runId
        : 'integrate-${DateTime.now().millisecondsSinceEpoch}';
    reporter?.report(passRunId, PassKinds.passPlanned, <String, dynamic>{
      'target': ?(targetName ?? passTitle),
      'sessionId': ?sessionId,
      'lanes': <Map<String, dynamic>>[
        for (final entry in groups.entries)
          <String, dynamic>{
            'lane': entry.key,
            'subs': entry.value.length,
            'exposure': entry.value.isEmpty
                ? null
                : entry.value.first.exposureDuration,
          },
      ],
      'finishing': true,
      'drafts': plannedDrafts,
    });
    final previewDir = reporter == null
        ? null
        : await reporter.previewDir(passRunId);

    try {
      for (final entry in groups.entries) {
        outcomes.add(
          await _integrateLane(
            entry: entry,
            settings: settings,
            outputFitsPathBuilder: outputFitsPathBuilder,
            targetId: targetId,
            targetName: targetName,
            biasPath: biasPath,
            pinnedCalibration: pinnedCalibration,
            generatePreview: generatePreview,
            hintRaHours: hintRaHours,
            hintDecDegrees: hintDecDegrees,
            passRunId: passRunId,
            previewDir: previewDir,
          ),
        );
      }
    } catch (error) {
      reporter?.report(passRunId, PassKinds.passEnded, <String, dynamic>{
        'ok': false,
        'error': '$error'.split('\n').first,
      });
      rethrow;
    }
    if (closePass) {
      reporter?.report(passRunId, PassKinds.passEnded, <String, dynamic>{
        'ok': true,
      });
    }
    return outcomes;
  }

  /// One filter group of [integrate]: integrate, persist, then the
  /// best-effort extras, reporting the lane to the pass view.
  Future<PostSessionIntegrationOutcome> _integrateLane({
    required MapEntry<String, List<CapturedImage>> entry,
    required IntegrationSettings settings,
    required String Function(String filterBucket) outputFitsPathBuilder,
    required int? targetId,
    required String? targetName,
    required String? biasPath,
    required ResolvedCalibration? pinnedCalibration,
    required bool generatePreview,
    required double? hintRaHours,
    required double? hintDecDegrees,
    required String passRunId,
    required String? previewDir,
  }) async {
    final reporter = _passReporter;
    final filterBucket = entry.key;
    final groupSubs = entry.value;
    final filterValue = filterBucket == noFilterBucket ? null : filterBucket;

    // A user-pinned calibration set bypasses auto-matching entirely (it is
    // applied verbatim to every filter group); otherwise the Calibration
    // Library / legacy DAOs pick the masters.
    final calibration =
        pinnedCalibration ??
        await _resolveCalibration(
          subs: groupSubs,
          biasPath: biasPath,
          cosmeticCorrection: settings.cosmeticCorrection,
        );

    final masterFitsPath = outputFitsPathBuilder(filterBucket);
    final previewPath = generatePreview
        ? _swapExtension(masterFitsPath, '.png')
        : null;
    final rejectionMapPath = settings.generateRejectionMap
        ? _suffixBeforeExtension(masterFitsPath, '_rejmap')
        : null;
    final rejectionMapPreviewPath = rejectionMapPath == null
        ? null
        : _swapExtension(rejectionMapPath, '.png');

    final reference = _chooseReferencePath(groupSubs);
    final exposures = groupSubs
        .map((s) => s.exposureDuration)
        .toList(growable: false);

    final args = <String, dynamic>{
      'lightPaths': groupSubs.map((s) => s.filePath).toList(),
      if (reference != null) 'reference': reference,
      'exposuresSec': exposures,
      'calibration': calibration.toBridgeJson(),
      'settings': settings.toBridgeSettings(),
      // A run started without a run id is not cancellable, and the native
      // side says so rather than pretending. With one,
      // `api_post_session_cancel` stops it at the next stage boundary and no
      // master is written. Every filter group of one call shares the id, so
      // one cancellation ends the night's integration rather than one group
      // of it.
      'runId': passRunId,
      'telemetry': {'lane': filterBucket, 'previewDir': ?previewDir},
      'output': {
        'masterFitsPath': masterFitsPath,
        if (previewPath != null) 'previewPngPath': previewPath,
        if (rejectionMapPath != null) 'rejectionMapPath': rejectionMapPath,
        if (rejectionMapPreviewPath != null)
          'rejectionMapPreviewPath': rejectionMapPreviewPath,
      },
    };

    var result = await _seam.integrateSession(args);
    reporter?.report(passRunId, PassKinds.laneFinishing, <String, dynamic>{
      'lane': filterBucket,
    });

    final masterId = await _persist(
      targetId: targetId,
      targetName: targetName,
      filter: filterValue,
      settings: settings,
      result: result,
      subs: groupSubs,
      calibrationWarnings: calibration.warnings,
    );

    // Smart Morning Report extensions: the marginal-SNR improvement curve and
    // the optional catalog/finishing passes. Both are best-effort and never
    // abort the (already-committed) master persist — a curve/finishing
    // failure leaves a perfectly good master row, just without the extras.
    await _analyzeAndStoreCurve(
      masterId: masterId,
      result: result,
      settings: settings,
    );
    // Drizzle branch: when enabled, re-deposit each accepted sub's raw pixels
    // onto a finer output grid using its source→reference registration
    // transform (surfaced per-frame above), then swap the drizzled FITS in as
    // the persisted master so everything downstream (hero, overlay, WCS solve,
    // finishing) sees the drizzled result. Fail-soft — a drizzle failure
    // leaves the already-committed standard master untouched. May rewrite
    // `result` so the WCS solve + finishing target the drizzled FITS + its
    // scaled dimensions.
    result = await _runDrizzle(
      masterId: masterId,
      result: result,
      settings: settings,
      calibration: calibration,
    );
    // Plate-solve the finished (possibly drizzled) master FITS and persist its
    // WCS. Fail-soft: a missing solver / failed solve leaves the master
    // un-annotatable (annotation + colour calibration stay skipped) but never
    // aborts the already-committed persist. Solve BEFORE the optional finishing
    // passes so the colour-calibration gate has the WCS the catalog match needs.
    final wcs = await _solveAndStoreWcs(
      masterId: masterId,
      result: result,
      hintRaHours: hintRaHours,
      hintDecDegrees: hintDecDegrees,
    );
    await _runOptionalFinishing(
      masterId: masterId,
      result: result,
      settings: settings,
      wcs: wcs,
    );

    reporter?.report(passRunId, PassKinds.laneFinished, <String, dynamic>{
      'lane': filterBucket,
      'ok': true,
    });
    return PostSessionIntegrationOutcome(
      masterId: masterId,
      filter: filterValue,
      result: result,
      calibrationWarnings: calibration.warnings,
    );
  }

  /// Run a **throwaway, non-persisting** integration of the accepted light
  /// [subs] (first filter group) with [settings], for exploratory comparison
  /// (e.g. the A/B recipe panel). Writes the master/preview to a temp directory
  /// and returns the decoded [IntegrateSessionResult] **without** inserting an
  /// `integrated_masters` row, the improvement curve, the optional finishing
  /// passes, or any fold records — so a comparison run never pollutes the master
  /// library or the durable smart-report state.
  ///
  /// Returns null when [subs] is empty.
  Future<IntegrateSessionResult?> previewIntegrate({
    required List<CapturedImage> subs,
    required IntegrationSettings settings,
    bool generatePreview = true,
  }) async {
    if (subs.isEmpty) return null;

    // Compare on the dominant filter group only — A/B is about the recipe, not
    // multi-filter fan-out; mixing filters into one throwaway master is never
    // what the comparison wants.
    final groups = _groupByFilter(subs);
    final entry = groups.entries.first;
    final groupSubs = entry.value;

    final calibration = await _resolveCalibration(
      subs: groupSubs,
      biasPath: null,
      cosmeticCorrection: settings.cosmeticCorrection,
    );

    final tempDir = await Directory.systemTemp.createTemp('sk_ab_preview');
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final masterFitsPath = '${tempDir.path}/ab_preview_$stamp.fits';
    final previewPath = generatePreview
        ? _swapExtension(masterFitsPath, '.png')
        : null;
    final rejectionMapPath = settings.generateRejectionMap
        ? _suffixBeforeExtension(masterFitsPath, '_rejmap')
        : null;
    final rejectionMapPreviewPath = rejectionMapPath == null
        ? null
        : _swapExtension(rejectionMapPath, '.png');

    final reference = _chooseReferencePath(groupSubs);
    final exposures = groupSubs
        .map((s) => s.exposureDuration)
        .toList(growable: false);

    final args = <String, dynamic>{
      'lightPaths': groupSubs.map((s) => s.filePath).toList(),
      if (reference != null) 'reference': reference,
      'exposuresSec': exposures,
      'calibration': calibration.toBridgeJson(),
      'settings': settings.toBridgeSettings(),
      'output': {
        'masterFitsPath': masterFitsPath,
        if (previewPath != null) 'previewPngPath': previewPath,
        if (rejectionMapPath != null) 'rejectionMapPath': rejectionMapPath,
        if (rejectionMapPreviewPath != null)
          'rejectionMapPreviewPath': rejectionMapPreviewPath,
      },
    };

    return _seam.integrateSession(args);
  }
}

/// Provider for the [PostSessionIntegrationService].
///
/// The [MasterPlateSolver] closure is wired here (the provider boundary, where
/// the `PlateSolveService` Riverpod handle lives): it plate-solves the finished
/// master FITS via `solveWithFallback` and converts the `PlateSolveResult` to
/// the eight CD-matrix WCS scalars using the same sign convention as the native
/// source of truth (`WcsInfo::from_plate_solve`, `imaging/src/fits.rs:1094`):
/// `cd1_1 = -scale·cosθ`, `cd1_2 = cd2_1 = scale·sinθ`, `cd2_2 = scale·cosθ`,
/// with `scale` in deg/px and `θ` the field rotation. The reference pixel is the
/// image centre. Fail-soft: a non-success solve (no solver installed, solve
/// failure) yields null, so WCS persistence is skipped without aborting the
/// master persist.
final postSessionIntegrationServiceProvider = Provider<PostSessionIntegrationService>((
  ref,
) {
  return PostSessionIntegrationService(
    passReporter: ref.watch(passReporterProvider),
    mastersDao: ref.watch(integratedMastersDaoProvider),
    seam: ref.watch(postSessionSeamProvider),
    // Calibration Library Manager: routes un-pinned master selection through
    // the transparent scored matcher so its warnings reach the outcome /
    // morning report.
    calibrationLibrary: ref.watch(calibrationLibraryServiceProvider),
    // Catalog colour calibration of the finished master, wired at the provider
    // boundary (where the `ColorCalibrationService` + its on-disk HYG catalog
    // live). The closure delegates to `ColorCalibrationService.calibrate`, which
    // detects + photometers stars, cross-matches catalogue B–V via the supplied
    // WCS, solves the per-channel white balance, and writes the rebalanced
    // master. Returns null on the fail-soft *skipped* result (too few matches /
    // no catalog) so the gate persists nothing rather than a phantom path.
    colorCalibrator:
        ({
          required String masterFits,
          required String outputFits,
          required WcsOverlay wcs,
          required int channels,
        }) async {
          final service = ref.read(colorCalibrationServiceProvider);
          final result = await service.calibrate(
            masterFits: masterFits,
            outputFits: outputFits,
            wcs: wcs,
            channels: channels,
          );
          if (ColorCalibrationService.wasSkipped(result)) return null;
          return result.outputPath;
        },
    plateSolver:
        ({
          required String imagePath,
          required int imageWidth,
          required int imageHeight,
          double? hintRaHours,
          double? hintDecDegrees,
        }) async {
          final solveService = ref.read(plateSolveServiceProvider);
          final PlateSolveResult solve;
          try {
            solve = await solveService.solveWithFallback(
              imagePath: imagePath,
              hintRaHours: hintRaHours,
              hintDecDegrees: hintDecDegrees,
            );
          } on SolverNotAvailableError {
            // No configured solver — stay un-annotated, never throw out of the
            // optional WCS step.
            return null;
          }
          if (!solve.success) return null;

          // Convert (ra°, dec°, pixelScale arcsec/px, rotation°) to the CD matrix.
          final scaleDeg = solve.pixelScale / 3600.0;
          final rotRad = solve.rotation * math.pi / 180.0;
          final cosRot = math.cos(rotRad);
          final sinRot = math.sin(rotRad);
          return MasterWcsSolution(
            crval1: solve.ra,
            crval2: solve.dec,
            crpix1: imageWidth / 2.0,
            crpix2: imageHeight / 2.0,
            cd1_1:
                -scaleDeg * cosRot, // Negative for RA increasing to the left.
            cd1_2: scaleDeg * sinRot,
            cd2_1: scaleDeg * sinRot,
            cd2_2: scaleDeg * cosRot,
          );
        },
  );
});

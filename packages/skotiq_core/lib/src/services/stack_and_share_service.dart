import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../models/calibration/dark_library_match_tolerances.dart';
import 'stacking_engine_seam.dart';
import '../models/imaging/stack_and_share_models.dart';
import '../providers/auto_stretch_provider.dart';
import '../providers/capability_provider.dart';
import '../providers/dark_library_provider.dart';
import '../database/daos/images_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/daos/stacked_results_dao.dart';
import '../providers/database_provider.dart';
import '../providers/backend_provider.dart';
import 'calibration_service.dart';
import 'dark_library_service.dart';
import 'live_stacking_service.dart';
import 'logging_service.dart';
import 'stack_light_selector.dart';
import 'stack_share_export_service.dart';
part 'stack_and_share_service/stack_results.dart';
part 'stack_and_share_service/rejection_reasons.dart';
part 'stack_and_share_service/stack_frame_io.dart';
part 'stack_and_share_service/stack_run_helpers.dart';

/// One-button orchestrator for the **Stack-and-Share Loop** (component C6).
///
/// [run] drives the whole pipeline end-to-end for a single imaging session:
///
///  1. **Guard** — refuse to run if the native stacker is already active
///     ([LiveStackBusyException]); the engine is a singleton and we must not
///     clobber a live EAA / sequencer session.
///  2. **Select** ([StackAndSharePhase.selectingLights]) — delegate to
/// [StackLightSelector] to choose the lights and the alignment
///     reference, honouring the [StackAndShareConfig] quality / accepted gates.
///  3. **Calibrate + stack** — when [StackAndShareConfig.applyCalibration] is
///     set, each light's raw u16 pixels are loaded and calibrated in memory
///     ([StackAndSharePhase.calibrating]) using a dark matched through the
///     dark library plus the configured master flat / bias, then fed to the
///     engine via `startFromData` / `addFrameFromData`
///     ([StackAndSharePhase.stacking]). When calibration is off, the engine's
///     own native file loader is used (`apiStackingStart` /
///     `apiStackingAddFrame`) so no lossy float→u16 round-trip occurs.
///  4. **Result** — `apiStackingGetResult` yields the integrated buffer, its
///     dimensions, the channel layout (`1` mono, `3` interleaved RGB16 for an
///     OSC stack the engine debayered), and the final [LiveStackingStats].
///  5. **Stretch** ([StackAndSharePhase.stretching]) — when
///     [StackAndShareConfig.autoStretch] is set, the integrated image is run
///     through the STF path with the result's channel count, so a colour stack
///     takes the per-channel (unlinked) stretch and a mono stack the grayscale
///     stretch; otherwise the raw result is kept as-is.
///  6. **Persist** — a [StackAndShareResult] is built (integration seconds from
///     the selection, alignment residual from the engine stats, colour flag +
///     channel count from the integrated result, filter `'OSC'` for a colour
///     stack / the single filter when the selection is mono) and written via
/// [StackedResultsDao.insertResult]; the returned row id is stamped
///     onto the result.
///
/// **OSC / colour resolution.** Before stacking, the run resolves the sensor
/// mode ([StackAndShareConfig.sensorMode]) into a concrete engine config: for
/// `osc`/`auto` with no explicit Bayer override it discovers the pattern from
/// the connected camera's [CameraCapabilities] (live) or the reference frame's
/// FITS `BAYERPAT` geometry (file). `osc` with no resolvable pattern is a hard
/// [StateError] — never a silent mono fallback that would scramble the mosaic.
/// The calibrated/raw CFA mono plane is fed to the engine **unchanged**; the
/// native stacker debayers post-calibration (Dart never debayers).
///  7. **Release** — `apiStackingStop` is **always** called in a `finally` so
///     the singleton is genuinely freed even if a step throws. `stop` (not
///     `reset`) is required: `reset` only clears the accumulated buffer but
///     leaves the singleton allocated, so `apiStackingIsActive` would keep
///     returning true and the entry guard (step 1) would reject every
///     subsequent run.
///
/// On any failure the run emits a final [StackAndSharePhase.error] progress
/// event and rethrows; errors are never swallowed.
///
/// The integrated raw u16 buffer and the stretched RGBA buffer from the most
/// recent successful run are retained on [lastRawResult] / [lastRgbaResult] so
/// the provider layer and the share/export step can consume them
/// without re-stacking.
class StackAndShareService {
  StackAndShareService(
    this._ref, {
    SkotiqBackend? backend,
    StackingEngineSeam engine = const BridgeStackingEngineSeam(),
    StackResultPreviewPersister? persistPreview,
  }) : _backend = backend ?? _ref.read(backendProvider),
       _backendNotifier = _ref.read(backendProvider.notifier),
       _logger = _ref.read(loggingServiceProvider),
       _engine = engine,
       _persistPreview = persistPreview;

  final Ref _ref;
  final SkotiqBackend _backend;
  final BackendNotifier _backendNotifier;
  final LoggingService _logger;
  bool _retired = false;

  // The native stacking engine is process-wide. This admission lock closes
  // the gap before the engine reports itself active (selection/calibration can
  // await for seconds), when two rapid invocations would otherwise both pass
  // isActive() and then clobber the same singleton.
  static Object? _processRunOwner;

  /// Injectable seam over the native stacker singleton + raw FITS / stretch
  /// bridge calls. Defaults to [BridgeStackingEngineSeam]; tests substitute a
  /// fake so the orchestrator body runs without the Rust dynamic library.
  final StackingEngineSeam _engine;

  /// Production persists a lossless preview for every completed result. Tests
  /// that exercise only orchestration may omit this seam; persistence-specific
  /// tests inject it explicitly.
  final StackResultPreviewPersister? _persistPreview;

  /// The integrated, calibrated u16 result of the most recent successful run,
  /// or null if no run has completed (or the last run failed). The provider
  /// layer reads this to feed the FITS save and the share-card renderer.
  StackedRawResult? get lastRawResult => _lastRawResult;
  StackedRawResult? _lastRawResult;

  /// The auto-stretched RGBA display buffer of the most recent successful run,
  /// or null when the last run did not stretch (mono) or has not completed.
  StackedRgbaResult? get lastRgbaResult => _lastRgbaResult;
  StackedRgbaResult? _lastRgbaResult;

  StackLightSelector get _selector => _ref.read(stackLightSelectorProvider);
  CalibrationService get _calibration => _ref.read(calibrationServiceProvider);
  DarkLibraryService get _darkLibrary => _ref.read(darkLibraryServiceProvider);
  ImagesDao get _imagesDao => _ref.read(imagesDaoProvider);
  SessionsDao get _sessionsDao => _ref.read(sessionsDaoProvider);
  StackedResultsDao get _resultsDao => _ref.read(stackedResultsDaoProvider);

  bool get _hasAuthority =>
      !_retired && _backendNotifier.isCurrentBackend(_backend);

  void retire() => _retired = true;

  void _ensureAuthority() {
    if (_hasAuthority) return;
    throw StateError(
      'The imaging host changed while Stack & Share was running. The outgoing '
      'run was stopped and its result was discarded; start it again on the '
      'current host.',
    );
  }

  /// Run the full Stack-and-Share pipeline for [sessionId] under [config].
  ///
  /// [onProgress] is invoked synchronously at every phase / per-frame
  /// transition so the UI can render a live progress bar. It is optional;
  /// callers that only want the final result may omit it.
  Future<StackAndShareResult> run({
    required int sessionId,
    required StackAndShareConfig config,
    void Function(StackAndShareProgress)? onProgress,
  }) async {
    _ensureAuthority();
    if (_backend is NetworkBackend) {
      throw StateError(
        'Stack & Share runs on the imaging host, not a remote controller.',
      );
    }
    if (_processRunOwner != null) {
      throw const LiveStackBusyException(
        'Another Stack-and-Share run is already preparing or stacking',
      );
    }

    // (1) Guard: never clobber an active live-stacking singleton.
    if (_engine.isActive()) {
      throw const LiveStackBusyException(
        'Stop live stacking before running Stack-and-Share',
      );
    }

    // Capture every provider value used after the first await while this
    // service's Ref is still current. Authority checks prevent later work from
    // continuing, but the cleanup path must still be able to reach the exact
    // old-host DAO and stacker after Riverpod rebuilds this provider.
    final selector = _selector;
    final sessionsDao = _sessionsDao;
    final resultsDao = _resultsDao;
    final liveStacking = _ref.read(liveStackingServiceProvider);

    final runOwner = Object();
    _processRunOwner = runOwner;

    void emit(StackAndShareProgress progress) {
      _ensureAuthority();
      onProgress?.call(progress);
    }

    var progress = const StackAndShareProgress(
      phase: StackAndSharePhase.selectingLights,
    );
    int? incompleteResultId;

    try {
      // Reset any retained buffers from a previous run; a fresh run only
      // exposes its own output, never a stale one.
      _lastRawResult = null;
      _lastRgbaResult = null;
      emit(progress);

      // (2) Selection — which lights, and which is the alignment reference.
      final selection = await selector.selectForSession(
        sessionId: sessionId,
        config: config,
      );
      _ensureAuthority();

      final referencePath = selection.referencePath;
      if (referencePath == null) {
        // The selector guarantees a non-empty selection (it throws
        // NoLightsToStackException otherwise), so a missing reference path is a
        // genuine invariant violation, not a user-facing empty stack.
        throw StateError(
          'Stack selection for session $sessionId returned no reference frame',
        );
      }

      // Order the selected frames so the alignment reference is processed
      // first; every other selected frame follows in selection order.
      final reference = selection.selected.firstWhere((f) => f.isReference);
      final followers = selection.selected
          .where((f) => f.imageId != reference.imageId)
          .toList(growable: false);

      final framesTotal = selection.selected.length;
      progress = progress.copyWith(framesTotal: framesTotal);

      // Resolve the owning session's target id for the persisted provenance
      // record (the selector already resolved the human-readable target name).
      final session = await sessionsDao.getSessionById(sessionId);
      _ensureAuthority();
      final targetId = session?.targetId;

      // Pre-resolve calibration inputs once when calibration is enabled: the
      // master flat / bias are shared across every frame, so load them a single
      // time rather than per-frame.
      _CalibrationContext? calibration;
      if (config.applyCalibration) {
        calibration = await _buildCalibrationContext();
        _ensureAuthority();
      }

      // Resolve the OSC / colour intent ONCE for the whole run, off the
      // reference frame, before any engine work. The live stacker fixes the
      // sensor mode + Bayer pattern at `start`; every follower inherits it, so
      // resolving once here keeps the whole integration on a single consistent
      // colour path (a mid-stack mode flip would mix mono and RGB buffers).
      final stackingConfig = await _resolveStackingConfig(
        config: config,
        reference: reference,
      );
      _ensureAuthority();

      // (3)+(4) Feed the reference, then every follower, into the engine.
      var framesProcessed = 0;
      var framesRejected = 0;
      // Reason → count for the frames the engine refused, so the run can name
      // the dominant cause instead of just quoting a number.
      final rejectionReasons = <String, int>{};

      // Start the stack from the reference frame.
      await _startStack(
        frame: reference,
        stackingConfig: stackingConfig,
        calibration: calibration,
        emitCalibrating: (file) {
          emit(
            progress.copyWith(
              phase: StackAndSharePhase.calibrating,
              currentFile: file,
            ),
          );
        },
      );
      _ensureAuthority();
      framesProcessed = 1; // The reference is always frame #1 in the stack.
      progress = progress.copyWith(
        phase: StackAndSharePhase.stacking,
        framesProcessed: framesProcessed,
        framesRejected: framesRejected,
        currentFile: reference.filePath,
      );
      emit(progress);

      // Track the engine's running stacked count so we can attribute each
      // follower as accepted (count advanced) or rejected (count unchanged).
      var lastStackedCount = 1;

      // Image ids the engine actually integrated. The persisted `avgHfr` is
      // averaged over exactly these — a stack's sharpness is the sharpness of
      // the subs that went INTO it, so a refused (trailed, defocused) sub must
      // not drag the number it never contributed to.
      final integratedImageIds = <int>{reference.imageId};

      for (final frame in followers) {
        if (calibration != null) {
          emit(
            progress.copyWith(
              phase: StackAndSharePhase.calibrating,
              currentFile: frame.filePath,
            ),
          );
        }

        final LiveStackingResult result;
        try {
          result = await _addStackFrame(frame: frame, calibration: calibration);
        } catch (e) {
          // Losing an entire night's stack to one satellite-trailed or
          // wind-shaken sub is the most expensive failure this feature has, and
          // an unguarded await is how it happens: every native rejection path
          // (too few stars, too few matches, residual over the ceiling) returns
          // Err, so one refused follower would reach the run-level catch, which
          // deletes the partial `stacked_results` row and abandons the
          // remaining subs.
          //
          // A refused frame is a PER-FRAME outcome: count it, remember why, and
          // keep stacking. Authority loss is the one genuine run-level abort
          // that can surface from in here, so it still propagates.
          if (!_hasAuthority) rethrow;
          framesProcessed++;
          framesRejected++;
          final reason = _rejectionReason(e);
          rejectionReasons[reason] = (rejectionReasons[reason] ?? 0) + 1;
          _logger.warning(
            'Frame rejected from the stack (${frame.filePath}): $reason',
            source: 'StackAndShareService',
          );
          progress = progress.copyWith(
            phase: StackAndSharePhase.stacking,
            framesProcessed: framesProcessed,
            framesRejected: framesRejected,
            currentFile: frame.filePath,
          );
          emit(progress);
          continue;
        }
        _ensureAuthority();

        framesProcessed++;
        final stackedCount = result.stats.stackedFrameCount;
        if (stackedCount <= lastStackedCount) {
          // Belt and braces: an engine build that reports a refusal as an Ok
          // with an unadvanced count is still a rejection.
          framesRejected++;
          rejectionReasons['not accepted by the stacker'] =
              (rejectionReasons['not accepted by the stacker'] ?? 0) + 1;
        } else {
          integratedImageIds.add(frame.imageId);
        }
        lastStackedCount = stackedCount;

        progress = progress.copyWith(
          phase: StackAndSharePhase.stacking,
          framesProcessed: framesProcessed,
          framesRejected: framesRejected,
          currentFile: frame.filePath,
        );
        emit(progress);
      }

      // A "stack" the engine only ever accepted the reference into is not a
      // stack; persisting it would report a master built from one sub. Fail
      // loudly, naming the dominant reason, rather than shipping that.
      if (followers.isNotEmpty && lastStackedCount <= 1) {
        throw StackAndShareAllFramesRejectedException(
          framesRejected: framesRejected,
          framesTotal: framesTotal,
          dominantReason: _dominantReason(rejectionReasons),
        );
      }

      // (5) Final integrated result + statistics.
      final stacked = await liveStacking.getCurrentResult();
      _ensureAuthority();
      final stats = stacked.stats;
      final rawU16 = Uint16List.fromList(stacked.data);

      // The engine reports the integrated channel layout directly: `1` for a
      // mono integration, `3` for an OSC integration it debayered to
      // interleaved RGB16. Anything else has no display/persist layout and is a
      // genuine engine-contract violation rather than something to paper over.
      final channels = stacked.channels;
      if (channels != 1 && channels != 3) {
        throw StateError(
          'Stacking engine returned an integrated result with $channels '
          'channels; only 1 (mono) or 3 (interleaved RGB16) are supported.',
        );
      }
      final isColor = channels == 3;

      // Guard the buffer length against the reported layout so a mismatch
      // surfaces here instead of corrupting the stretch / persisted record.
      final expectedSamples = stacked.width * stacked.height * channels;
      if (rawU16.length != expectedSamples) {
        throw StateError(
          'Stacking engine returned ${rawU16.length} samples for a '
          '${stacked.width}x${stacked.height} $channels-channel result '
          '(expected $expectedSamples).',
        );
      }

      _lastRawResult = StackedRawResult(
        width: stacked.width,
        height: stacked.height,
        channels: channels,
        data: rawU16,
      );

      // (6) Optional auto-stretch to an RGBA display buffer. The channel count
      // is forwarded so a colour stack takes the per-channel (unlinked) STF
      // route rather than being treated as a single luminance plane.
      if (config.autoStretch) {
        progress = progress
            .copyWith(phase: StackAndSharePhase.stretching)
            .clearCurrentFile();
        emit(progress);

        final rgba = _engine.autoStretch(
          width: stacked.width,
          height: stacked.height,
          data: stacked.data,
          channels: channels,
        );
        _lastRgbaResult = StackedRgbaResult(
          width: stacked.width,
          height: stacked.height,
          rgba: rgba,
        );
      }

      // (7) Build + persist the provenance record.
      final avgHfr = await _averageIntegratedHfr(
        sessionId: sessionId,
        imageIds: integratedImageIds,
      );
      _ensureAuthority();
      final result = StackAndShareResult(
        sessionId: sessionId,
        targetId: targetId,
        targetName: selection.targetName,
        width: stacked.width,
        height: stacked.height,
        framesStacked: stats.stackedFrameCount,
        framesAttempted: framesTotal,
        integrationSecs: _integratedIntegrationSecs(
          selection,
          integratedImageIds,
        ),
        avgAlignmentResidual: stats.avgAlignmentResidual,
        avgHfr: avgHfr,
        filter: _singleFilter(selection, isColor: isColor),
        isColor: isColor,
        channels: channels,
        createdAt: DateTime.now(),
        stats: stats,
      );

      final id = await resultsDao.insertResult(result);
      incompleteResultId = id;
      _ensureAuthority();
      var persisted = result.copyWith(id: id);

      // Metadata alone is not a saved result: the raw integration is released
      // when the auto-disposed provider goes away. Persist a lossless display
      // preview before declaring the run complete so history survives app
      // navigation and process restarts. When auto-stretch was disabled for the
      // run, render an STF only for this viewer preview; the retained raw buffer
      // and run configuration remain unchanged.
      final persistPreview = _persistPreview;
      if (persistPreview != null) {
        progress = progress
            .copyWith(phase: StackAndSharePhase.exporting)
            .clearCurrentFile();
        emit(progress);

        final previewRgba =
            _lastRgbaResult?.rgba ??
            _engine.autoStretch(
              width: stacked.width,
              height: stacked.height,
              data: rawU16,
              channels: channels,
            );
        final previewPath = await persistPreview(
          result: persisted,
          rgba: previewRgba,
        );
        _ensureAuthority();
        persisted = persisted.copyWith(exportedImagePath: previewPath);
      }

      emit(
        progress
            .copyWith(
              phase: StackAndSharePhase.complete,
              framesProcessed: framesTotal,
            )
            .clearCurrentFile(),
      );
      incompleteResultId = null;

      _logger.info(
        'Stack-and-Share complete for session $sessionId: '
        '${stats.stackedFrameCount}/$framesTotal frames stacked, '
        '$framesRejected rejected'
        '${framesRejected > 0 ? ' (${_dominantReason(rejectionReasons)})' : ''}'
        ', ${persisted.integrationSecs.toStringAsFixed(0)}s integration '
        '(result id $id)',
        source: 'StackAndShareService',
      );

      return persisted;
    } catch (e, st) {
      // (9) Surface the failure: emit a terminal error phase, log, and rethrow.
      _lastRawResult = null;
      _lastRgbaResult = null;
      final resultId = incompleteResultId;
      if (resultId != null) {
        try {
          await resultsDao.deleteResult(resultId);
          incompleteResultId = null;
        } catch (cleanupError, cleanupStack) {
          _logger.error(
            'Failed to remove incomplete stacked result $resultId: '
            '$cleanupError',
            source: 'StackAndShareService',
            fields: {'stackTrace': cleanupStack.toString()},
          );
        }
      }
      if (_hasAuthority) {
        emit(
          progress.copyWith(phase: StackAndSharePhase.error).clearCurrentFile(),
        );
      }
      _logger.error(
        'Stack-and-Share failed for session $sessionId: $e',
        source: 'StackAndShareService',
        fields: {'stackTrace': st.toString()},
      );
      rethrow;
    } finally {
      // (8) Always release the engine singleton, even on failure, so a later
      // live-stacking session is not blocked by leftover stacker state.
      //
      // `stop` — not `reset` — is required here: `reset` clears the accumulated
      // buffer but leaves the singleton allocated, so `isActive()` would keep
      // returning true and the entry guard (step 1) would refuse every later
      // run, making the feature single-shot per app launch. `stop` frees the
      // guard so `isActive()` returns false again.
      //
      // Guard the stop in its own try/catch: when the pipeline itself threw, the
      // `catch` above is already rethrowing the real cause — a release failure
      // must not mask it. Log it instead, so the leaked singleton is still
      // visible to operators.
      try {
        await _engine.stop();
      } catch (stopError, stopStack) {
        _logger.error(
          'Stack-and-Share failed to release the stacking engine for session '
          '$sessionId: $stopError',
          source: 'StackAndShareService',
          fields: {'stackTrace': stopStack.toString()},
        );
      }
      if (identical(_processRunOwner, runOwner)) {
        _processRunOwner = null;
      }
    }
  }
}

/// Provider for the [StackAndShareService].
///
/// Reads the selector, calibration, dark-library, DAO, and live-stacking
/// providers lazily inside the service so it follows the same Drift instance
/// and backend as the rest of the app, and so test overrides flow through.
final stackAndShareServiceProvider = Provider<StackAndShareService>((ref) {
  final backend = ref.watch(backendProvider);
  final exportService = ref.watch(stackShareExportServiceProvider);
  final service = StackAndShareService(
    ref,
    backend: backend,
    persistPreview: ({required result, required rgba}) {
      return exportService.persistViewerPreview(result: result, rgba: rgba);
    },
  );
  ref.onDispose(service.retire);
  return service;
});

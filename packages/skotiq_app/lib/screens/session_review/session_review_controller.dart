import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide BestNight;
// The controller exposes its own UI-facing [BestNight] (hours-based) to the
// panels; reach the core service type — also named `BestNight` — under a prefix
// so the two never collide.
import 'package:skotiq_core/skotiq_core.dart' as core show BestNight;
import 'package:path/path.dart' as p;

part 'session_review_controller_parts/_models.dart';
part 'session_review_controller_parts/_state.dart';
part 'session_review_controller_parts/_helpers.dart';

/// Drives the Session Review / Morning Report screen.
///
/// Owns sub loading + culling (delegating accept/reject to [ImagesDao]), the
/// editable [IntegrationSettings], the integration / re-integrate runs (through
/// [PostSessionIntegrationService]) and multi-night accumulation (through
/// [MasterAccumulationService]), and the persisted [IntegratedMaster] list.
class SessionReviewController extends StateNotifier<SessionReviewState> {
  SessionReviewController(this._ref, this._scope)
      : super(const SessionReviewState()) {
    _bindProgress();
    _load();
  }

  final Ref _ref;
  final SessionReviewScope _scope;

  /// Whether this screen has already replaced a stale Night Doctor verdict.
  ///
  /// The staleness test in `_loadNightReport` would otherwise fire on every
  /// smart-data load for the same night — each one computing AND persisting a
  /// report — because the freshly written report is still older than nothing
  /// it can change. One automatic recompute per visit is enough to correct the
  /// record; the operator's Refresh can always force another.
  bool _nightReportRecomputed = false;

  /// Live integration-progress subscription bound from the post-session seam's
  /// `IntegrationProgress` event stream; cancelled in [dispose].
  StreamSubscription<({String phase, double fraction})>? _progressSub;

  /// App-settings key for the default integration settings used by the panel
  /// and the auto-process hook.
  static const String kDefaultSettingsKey = 'post_session.default_settings';

  /// What an integration run actually did, when it did not do what was asked.
  ///
  /// Returns null when every sub made it into the master; otherwise a single
  /// sentence naming the counts and the dominant reason, e.g.
  /// `Integrated 1 of 9 subs — 8 were dropped: registration failed: too few
  /// stars to register: reference=0, frame=4, need >= 3`.
  ///
  /// A run that silently keeps 1 of 9 subs and presents the result as a
  /// finished master loses a night's data with no signal anywhere in the UI:
  /// the master card shows only the frame count it *did* integrate, and the
  /// outcome's `framesRejected` has no other rendering on the manual path. Both
  /// the toast and the persistent workbench banner read this.
  ///
  /// Pure so the sentence can be asserted without a running integration.
  static String? integrationShortfall(PostSessionIntegrationOutcome? outcome) {
    if (outcome == null) return null;
    final result = outcome.result;
    final rejected = result.framesRejected;
    if (rejected <= 0) return null;
    final total = result.framesIntegrated + rejected;

    // The dominant reason, not the first: a run usually fails the same way for
    // every sub, and naming the common cause is what makes the message
    // actionable.
    final tally = <String, int>{};
    for (final frame in result.perFrameStats) {
      if (frame.accepted) continue;
      final reason = (frame.reason ?? '').trim();
      if (reason.isEmpty) continue;
      tally[reason] = (tally[reason] ?? 0) + 1;
    }
    String? dominant;
    var dominantCount = 0;
    tally.forEach((reason, count) {
      if (count > dominantCount) {
        dominant = reason;
        dominantCount = count;
      }
    });

    final headline = 'Integrated ${result.framesIntegrated} of $total subs — '
        '$rejected ${rejected == 1 ? 'was' : 'were'} dropped';
    return dominant == null ? '$headline.' : '$headline: $dominant';
  }

  ImagesDao get _images => _ref.read(imagesDaoProvider);
  IntegratedMastersDao get _mastersDao =>
      _ref.read(integratedMastersDaoProvider);
  NarrowbandCompositesDao get _compositesDao =>
      _ref.read(narrowbandCompositesDaoProvider);

  /// Run [body] as a live-progress-reporting action: whatever the native side
  /// pushes onto the shared progress stream while it runs belongs to *this*
  /// action, so the strip is torn down when it returns — on success, on failure
  /// and on every early-out.
  ///
  /// This exists because the strip's lifetime cannot be left to each action's
  /// own completion handler. The stream's terminal event is a full 1.0 fraction
  /// that [_bindProgress] deliberately leaves on screen (so the bar lands full
  /// rather than vanishing mid-way); an action that returns without clearing it
  /// therefore pins a "Preview… 100%" strip under the header forever, claiming
  /// a job is still running. Every seam-driven action routes through here so
  /// the clear cannot be forgotten by the next one added.
  Future<T> _withLiveProgress<T>(Future<T> Function() body) async {
    try {
      return await body();
    } finally {
      if (mounted) state = state.copyWith(clearLiveProgress: true);
    }
  }

  /// Bind [SessionReviewState.progress] to the seam's live integration-progress
  /// stream. Each native `IntegrationProgress` event maps straight to the
  /// `(phase, fraction)` record the `SkotiqProgressBar` renders. The stream
  /// is long-lived (broadcast off the backend event channel) and only carries
  /// data while a run is in flight; [_withLiveProgress] clears the field when
  /// the action that raised it returns. Bound once for the controller's
  /// lifetime.
  void _bindProgress() {
    final seam = _ref.read(postSessionSeamProvider);
    _progressSub = seam.integrationProgress().listen(
      (event) {
        if (!mounted) return;
        // A terminal 1.0 fraction is left on screen until the action's own
        // completion handler clears it (so the bar lands full, not mid-way).
        state = state.copyWith(progress: event);
      },
      onError: (_) {
        // A progress-stream error must never sink the screen; just stop
        // reporting live progress.
        if (mounted) state = state.copyWith(clearLiveProgress: true);
      },
    );
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<IntegrationSettings> _loadDefaultSettings() async {
    final raw =
        await _ref.read(settingsDaoProvider).getSetting(kDefaultSettingsKey);
    return IntegrationSettings.fromJsonStringOrDefault(raw);
  }

  /// Refresh the sub list + master list from the database (after an external
  /// change, e.g. another screen rejected a frame).
  ///
  /// Also RE-COMPUTES the Night Doctor verdict rather than re-reading the
  /// persisted one: the operator pressing Refresh on a screen showing a
  /// verdict they disagree with is the one moment where "use the cached
  /// answer" is certainly wrong.
  Future<void> refresh() => _load(recomputeNightReport: true);

  /// Replace the working integration settings (panel edits). Not persisted as
  /// the default unless [persistAsDefault] is set.
  Future<void> updateSettings(
    IntegrationSettings settings, {
    bool persistAsDefault = false,
  }) async {
    state = state.copyWith(settings: settings);
    if (persistAsDefault) {
      await _ref
          .read(settingsDaoProvider)
          .setSetting(kDefaultSettingsKey, settings.toJsonString());
    }
  }

  /// Flip the accept/reject flag for a single sub and refresh the list.
  Future<void> setAccepted(int imageId, bool accepted) async {
    if (accepted) {
      await _images.acceptImage(imageId);
    } else {
      await _images.rejectImage(imageId, 'Manual quality flag');
    }
    await _reloadSubs();
  }

  /// Reject every accepted light sub whose HFR exceeds [hfrThreshold] (when
  /// non-null) OR whose quality score is below [qualityThreshold] (when
  /// non-null). Returns the number of subs newly rejected.
  Future<int> bulkReject({
    double? hfrThreshold,
    double? qualityThreshold,
  }) async {
    var rejected = 0;
    for (final sub in state.acceptedLights) {
      final failHfr =
          hfrThreshold != null && sub.hfr != null && sub.hfr! > hfrThreshold;
      final failQuality = qualityThreshold != null &&
          sub.qualityScore != null &&
          sub.qualityScore! < qualityThreshold;
      if (failHfr || failQuality) {
        await _images.rejectImage(
          sub.id,
          failHfr
              ? 'Bulk cull: HFR ${sub.hfr!.toStringAsFixed(2)} > '
                  '${hfrThreshold.toStringAsFixed(2)}'
              : 'Bulk cull: quality ${sub.qualityScore!.toStringAsFixed(0)} < '
                  '${qualityThreshold!.toStringAsFixed(0)}',
        );
        rejected++;
      }
    }
    if (rejected > 0) await _reloadSubs();
    return rejected;
  }

  /// Run a one-shot batch integration of the current accepted subs with the
  /// current settings, producing a fresh master. Returns the outcome, or null
  /// on failure (with [SessionReviewState.error] set).
  Future<PostSessionIntegrationOutcome?> integrate() async {
    final accepted = state.acceptedLights;
    if (accepted.isEmpty) {
      state = state.copyWith(error: 'No accepted subs to integrate.');
      return null;
    }
    state = state.copyWith(
      integrating: true,
      integrationProgress: 0,
      clearError: true,
    );
    return _withLiveProgress(_integrate);
  }

  Future<PostSessionIntegrationOutcome?> _integrate() async {
    final accepted = state.acceptedLights;
    try {
      final service = _ref.read(postSessionIntegrationServiceProvider);
      final outDir = await _outputDir();
      // Catalog coordinates (RA hours / Dec degrees) hint the master plate-solve
      // so the WCS persist is fast/robust; null falls back to a blind solve.
      final (hintRaHours, hintDecDegrees) = await _resolveTargetHint();
      final outcomes = await service.integrate(
        subs: accepted,
        settings: state.settings,
        targetId: state.targetId,
        targetName: state.targetName,
        hintRaHours: hintRaHours,
        hintDecDegrees: hintDecDegrees,
        sessionId: _scope.sessionId,
        outputFitsPathBuilder: (filterBucket) {
          final stamp = DateTime.now().millisecondsSinceEpoch;
          final base = _safeName(state.title);
          final filterTag =
              filterBucket == PostSessionIntegrationService.noFilterBucket
                  ? ''
                  : '_${_safeName(filterBucket)}';
          return p.join(outDir, '$base${filterTag}_master_$stamp.fits');
        },
      );
      final first = outcomes.isNotEmpty ? outcomes.first : null;
      if (!mounted) return first;
      await _publishMasters(
        pinMasterId: first?.masterId,
        extra: (s) => s.copyWith(
          integrating: false,
          clearProgress: true,
          clearLiveProgress: true,
          lastOutcome: first,
        ),
      );
      // A fresh master invalidates the smart backbone — re-derive it.
      unawaited(loadSmartData());
      return first;
    } catch (e) {
      if (!mounted) return null;
      state = state.copyWith(
        integrating: false,
        clearProgress: true,
        clearLiveProgress: true,
        error: 'Integration failed: $e',
      );
      return null;
    }
  }

  // Smart morning report (Pillar 5) — data backbone + finishing actions

  /// Load (or refresh) the smart-report backbone the narrative + workbench
  /// panels read: the Night Doctor [NightReport], the reviewed master's
  /// marginal-SNR [IntegrationCurve], its multi-night [GrowthPoint] growth
  /// series + [BestNight], and the catalog [AnnotationLayer].
  ///
  /// Every source is loaded fail-soft and independently: a failure in any one
  /// leaves that field null/empty rather than sinking the whole load, so a
  /// single-night session (no master, no growth) still gets its night report,
  /// and a master with no persisted curve still gets growth + annotations.
  Future<void> loadSmartData({bool recomputeNightReport = false}) async {
    if (!mounted) return;
    state = state.copyWith(loadingSmartData: true);

    final report = await _loadNightReport(forceRecompute: recomputeNightReport);
    // The load runs unawaited after an integration, so the review may have
    // closed while the report was read.
    if (!mounted) return;
    final master = state.reviewedMaster;
    final (curve, population) = master != null
        ? await _loadImprovementCurve(master.id)
        : (null, const <String>[]);
    final (growth, best) = master != null
        ? await _loadGrowthAndBestNight(master.id)
        : (const <GrowthPoint>[], null);
    final annotations =
        master != null ? await _loadAnnotationLayer(master) : null;

    if (!mounted) return;
    state = state.copyWith(
      loadingSmartData: false,
      nightReport: report,
      clearNightReport: report == null,
      improvementCurve: curve,
      clearImprovementCurve: curve == null,
      improvementCurvePopulation: population,
      growthPoints: growth,
      bestNight: best,
      clearBestNight: best == null,
      annotationLayer: annotations,
      clearAnnotationLayer: annotations == null,
    );
  }

  /// Re-run the integration of the current accepted subs with [settings],
  /// producing a fresh master. The narrative/workbench finishing actions
  /// (`runColorCalibration`, `runBackgroundExtraction`, `runNarrowband`) and the
  /// integration-settings A/B panel all funnel through this so they share the
  /// one progress binding + smart-data refresh. [settings] also becomes the
  /// working settings. Returns the first outcome, or null on failure.
  Future<PostSessionIntegrationOutcome?> reIntegrate(
    IntegrationSettings settings,
  ) async {
    state = state.copyWith(settings: settings);
    return integrate();
  }

  /// Run a **throwaway, non-persisting** integration of the current accepted
  /// subs with [settings] and return the outcome, for exploratory comparison
  /// (the A/B recipe panel). Unlike [reIntegrate] this does **not** mutate the
  /// working `state.settings`, does not persist an `integrated_masters` row,
  /// does not refresh the master list / `lastOutcome`, and does not re-derive
  /// the smart backbone — so an A/B comparison never changes what "Re-integrate"
  /// or the narrative finishing actions use, and never pollutes the master
  /// library or the hero/growth/annotation state. Returns null on failure (with
  /// no error surfaced on state, since this is a side panel's concern).
  ///
  /// The returned outcome carries a sentinel `masterId` of `-1` — it is a
  /// preview, not a persisted master.
  Future<PostSessionIntegrationOutcome?> reIntegratePreview(
    IntegrationSettings settings,
  ) async {
    final accepted = state.acceptedLights;
    if (accepted.isEmpty) return null;
    return _withLiveProgress(() async {
      try {
        final service = _ref.read(postSessionIntegrationServiceProvider);
        final result = await service.previewIntegrate(
          subs: accepted,
          settings: settings,
        );
        if (result == null) return null;
        return PostSessionIntegrationOutcome(
          masterId: -1,
          filter: accepted.first.filter,
          result: result,
        );
      } catch (_) {
        return null;
      }
    });
  }

  /// Catalog colour-calibrate the **current reviewed master** as a
  /// non-destructive post-step on its finished FITS — the narrative / workbench
  /// "Calibrate color" action. Unlike a re-integration this never re-runs the
  /// stack: it detects + photometers stars on the master, cross-matches them to
  /// the catalog using the master's persisted WCS, solves the per-channel white
  /// balance via [ColorCalibrationService], writes `<master>_color.fits`, renders
  /// a sibling preview PNG, persists the path via the v42 `color_calibrated_path`
  /// column, and refreshes the master list so the result survives reload.
  ///
  /// Needs a master with a solved WCS: without one the cross-match cannot place
  /// detections on the sky, so the action surfaces an error rather than silently
  /// producing an unchanged master. A solved-but-sparse field (too few catalog
  /// cross-matches) also surfaces a "could not calibrate" message. Returns the
  /// written calibrated FITS path, or null when there is no master / no WCS / the
  /// pass skipped or failed.
  Future<String?> runColorCalibration() async {
    final master = state.reviewedMaster;
    final inputFits = master?.masterFitsPath;
    if (master == null || inputFits == null || inputFits.trim().isEmpty) {
      state = state.copyWith(
        error: 'Color calibration needs a finished master FITS — integrate '
            'first.',
      );
      return null;
    }
    final wcs = _resolveMasterWcs(master);
    if (wcs == null) {
      state = state.copyWith(
        error: 'Color calibration needs a plate-solved master (WCS) to match '
            'catalog stars — none is available for this master.',
      );
      return null;
    }
    state = state.copyWith(calibrating: true, clearError: true);
    return _withLiveProgress(
        () => _runColorCalibration(master, inputFits, wcs));
  }

  /// Background-extract (gradient-flatten) the **current reviewed master** as a
  /// non-destructive post-step on its finished FITS — the workbench "Background
  /// extract" action. Unlike a re-integration this never re-runs the stack: it
  /// flattens the existing master FITS via the post-session seam
  /// (`extractBackground`), writes `<master>_bgx.fits`, renders a sibling preview
  /// PNG, persists the path via [IntegratedMastersDao.updateFinishingPaths] (the
  /// v44 `background_extracted_path` column), and refreshes the master list so
  /// the result round-trips on reload. Returns the written FITS path, or null
  /// when there is no master / the pass fails.
  Future<String?> runBackgroundExtraction() async {
    return _runFinishingStep(
      busy: (v) => state.copyWith(extractingBackground: v),
      suffix: '_bgx',
      label: 'Background extraction',
      invoke: (seam, master, output) =>
          seam.extractBackground(<String, dynamic>{
        'inputFits': master.masterFitsPath,
        'outputFits': output,
        'config': <String, dynamic>{
          'polyDegree': state.settings.backgroundPolyDegree,
          'preserveMean': state.settings.backgroundPreserveMean,
        },
      }),
      persist: (id, path) => _mastersDao.updateFinishingPaths(
        id,
        backgroundExtractedPath: path,
      ),
      alsoMark: (id) =>
          _mastersDao.updateSmartFields(id, backgroundExtracted: true),
    );
  }

  /// Deconvolve (Richardson–Lucy preview) the **current reviewed master** as a
  /// non-destructive post-step on its finished FITS — the workbench "Deconvolve"
  /// action. Writes `<master>_decon.fits`, renders a sibling preview PNG,
  /// persists the path via the v44 `deconvolved_path` column, and refreshes so
  /// the result survives reload. Returns the written FITS path, or null when
  /// there is no master / the pass fails.
  Future<String?> runDeconvolve() async {
    return _runFinishingStep(
      busy: (v) => state.copyWith(deconvolving: v),
      suffix: '_decon',
      label: 'Deconvolution',
      invoke: (seam, master, output) =>
          seam.deconvolvePreview(<String, dynamic>{
        'inputFits': master.masterFitsPath,
        'outputFits': output,
        'config': <String, dynamic>{
          'iterations': state.settings.deconIterations,
          'regularization': state.settings.deconRegularization,
        },
      }),
      persist: (id, path) =>
          _mastersDao.updateFinishingPaths(id, deconvolvedPath: path),
    );
  }

  /// Reduce stars (mask-confined preview) on the **current reviewed master** as
  /// a non-destructive post-step on its finished FITS — the workbench "Reduce
  /// stars" action. Writes `<master>_starred.fits`, renders a sibling preview
  /// PNG, persists the path via the v44 `star_reduced_path` column, and
  /// refreshes so the result survives reload. Returns the written FITS path, or
  /// null when there is no master / the pass fails.
  Future<String?> runStarReduction() async {
    return _runFinishingStep(
      busy: (v) => state.copyWith(reducingStars: v),
      suffix: '_starred',
      label: 'Star reduction',
      invoke: (seam, master, output) =>
          seam.reduceStarsPreview(<String, dynamic>{
        'inputFits': master.masterFitsPath,
        'outputFits': output,
        'config': <String, dynamic>{
          'strength': state.settings.starReductionStrength,
          'method': state.settings.starReduceMethod.wire,
        },
      }),
      persist: (id, path) =>
          _mastersDao.updateFinishingPaths(id, starReducedPath: path),
    );
  }

  /// Combine the supplied single-channel narrowband [channels] into an RGB
  /// composite under [palette] (`'sho'` / `'hoo'` / `'custom'`) with the given
  /// per-input `[r,g,b]` [weights], writing the composite FITS. Routes through
  /// the post-session seam's `combineChannels`. Returns the written composite
  /// path, or null when the inputs are insufficient / the combine fails.
  ///
  /// [palette] mirrors the `NarrowbandMixerPanel`'s preset-or-custom token; when
  /// it is `'custom'` the explicit [weights] matrix is sent, otherwise the
  /// native canonical palette table is used.
  Future<String?> runNarrowband(
    String palette,
    List<List<double>> weights, {
    List<NarrowbandChannelRef>? channels,
  }) async {
    // Apply is the mixer's ONLY action, and a combine can take tens of seconds.
    // Without this guard a second press re-enters and starts a concurrent
    // native combine writing to a different stamped path, so two runs race to
    // set `narrowbandComposite` and the user gets orphaned FITS for the presses
    // that lost. The button also renders its busy state now, so a rejected
    // press is visible rather than looking like a dead control.
    if (state.combiningNarrowband) return null;

    // Cleared BEFORE the guard below, not inside the try: the screen toasts a
    // given error string once and remembers it, so re-raising the SAME message
    // without a null in between is silent. Pressing Apply five times against an
    // unchanged precondition has to say something five times.
    state = state.copyWith(clearError: true);

    final refs = channels ?? state.narrowbandChannels;
    // Only the channels that resolve to an on-disk master FITS feed the combine;
    // keep their master ids in lock-step so the persisted row records exactly the
    // component masters the composite was built from, in channel order.
    final fed = [
      for (final c in refs)
        if (c.fitsPath != null) c,
    ];
    final inputs = [for (final c in fed) c.fitsPath!];
    if (inputs.length < 2) {
      final withPath = refs.where((c) => c.fitsPath != null).length;
      state = state.copyWith(
        error: 'Need at least two finalized narrowband masters to combine — '
            '${refs.length} channel${refs.length == 1 ? '' : 's'} in scope, '
            '$withPath with a finished FITS on disk.',
      );
      return null;
    }
    state = state.copyWith(combiningNarrowband: true, clearError: true);
    return _withLiveProgress(() async {
      try {
        final seam = _ref.read(postSessionSeamProvider);
        final outDir = await _outputDir();
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final output = p.join(outDir,
            '${_safeName(state.title)}_${_safeName(palette)}_$stamp.fits');
        final isCustom = palette.toLowerCase() == 'custom';
        final outputPath = await seam.combineChannels(<String, dynamic>{
          'inputs': inputs,
          'palette': palette,
          if (isCustom) 'weights': weights,
          'output': output,
        });

        // Persist the composite as a `narrowband_composites` row so the SHO/HOO
        // output survives the session and can be surfaced rather than orphaned
        // on disk. Composite dimensions track the component masters (the
        // combine is a per-pixel mix of identically-sized channels), so read
        // them off the first fed master when available.
        final firstMaster = _masterById(fed.first.masterId);
        final id = await _compositesDao.insertComposite(
          targetId: state.targetId,
          palette: palette,
          componentMasterIds: [for (final c in fed) c.masterId],
          outputPath: outputPath,
          width: firstMaster?.width ?? 0,
          height: firstMaster?.height ?? 0,
        );
        final composite = NarrowbandComposite(
          id: id,
          targetId: state.targetId,
          palette: palette,
          componentMasterIds: [for (final c in fed) c.masterId],
          outputPath: outputPath,
          width: firstMaster?.width ?? 0,
          height: firstMaster?.height ?? 0,
          createdAt: DateTime.now().toUtc(),
        );
        if (mounted) {
          state = state.copyWith(
            narrowbandComposite: composite,
            narrowbandComposites: [composite, ...state.narrowbandComposites],
          );
        }
        return outputPath;
      } catch (e) {
        if (mounted) {
          state = state.copyWith(error: 'Narrowband combine failed: $e');
        }
        return null;
      } finally {
        if (mounted) state = state.copyWith(combiningNarrowband: false);
      }
    });
  }

  /// Load the persisted narrowband composites in scope (target-scoped when a
  /// target is resolved, otherwise all), newest first, onto
  /// [SessionReviewState.narrowbandComposites] — the workbench "composites" list.
  Future<void> loadComposites() async {
    final tid = state.targetId;
    final composites = tid != null
        ? await _compositesDao.getForTarget(tid)
        : await _compositesDao.getAll();
    if (!mounted) return;
    state = state.copyWith(
      narrowbandComposites: composites,
      narrowbandComposite: state.narrowbandComposite ??
          (composites.isNotEmpty ? composites.first : null),
    );
  }

  /// The single-channel narrowband masters available to the mixer — a
  /// controller-method alias of [SessionReviewState.narrowbandChannels] so a
  /// view holding only the controller (not the state snapshot) can list them.
  List<NarrowbandChannelRef> narrowbandChannels() => state.narrowbandChannels;

  /// Flip the active rendering between the narrative and the workbench. With no
  /// argument it toggles; pass [mode] to set it directly.
  void setViewMode([SessionReviewViewMode? mode]) {
    final next = mode ??
        (state.viewMode == SessionReviewViewMode.narrative
            ? SessionReviewViewMode.workbench
            : SessionReviewViewMode.narrative);
    if (next == state.viewMode) return;
    state = state.copyWith(viewMode: next);
  }

  /// Whether the "keep best N" cull is offerable against the *current* state,
  /// and the numbers a label may quote. [cullToRecommended] runs off this same
  /// evaluation, so what the rail renders and what the press handler does can
  /// never diverge — the rail must not advertise a cull this refuses.
  ///
  /// The optimizer's `keptIndices` are positions into the *population the curve
  /// was computed over* — `improvementCurvePopulation`, the ordered sub paths
  /// recorded when the master was built. They are NOT raw positions into the
  /// live `acceptedLights`, which may have changed (subs accepted/rejected
  /// since, or a different ordering) and whose `SubsetRecommendation` documents
  /// the indices as weight-ranked, not capture-ranked. So the offer is only
  /// `offerable` while the population still matches the live accepted set
  /// exactly; a stale/mismatched curve must never reject arbitrary subs.
  CullRecommendationOffer get cullRecommendationOffer {
    final curve = state.improvementCurve;
    if (curve == null) return CullRecommendationOffer.none;
    final rec = curve.recommendation;
    if (rec.keepN <= 0) return CullRecommendationOffer.none;

    final population = state.improvementCurvePopulation;
    final accepted = state.acceptedLights;
    final stale = CullRecommendationOffer(
      status: CullOfferStatus.stale,
      keepN: rec.keepN,
      gainPct: rec.predictedSnrGainPct,
      populationSize: population.length,
    );
    if (accepted.isEmpty) return stale;

    // The curve must carry a population, and that population must be the same
    // set of subs (by path) that is currently accepted — otherwise the index
    // space no longer maps to these subs.
    if (population.length != accepted.length) return stale;
    final acceptedPaths = <String>{for (final s in accepted) s.filePath};
    // Duplicate paths: the path→sub mapping is ambiguous, so the keep-set
    // cannot be resolved safely.
    if (acceptedPaths.length != accepted.length) return stale;
    for (final path in population) {
      if (!acceptedPaths.contains(path)) return stale; // population diverged
    }

    // keepN covering the whole population rejects nothing; a non-positive
    // predicted gain means the keep-set is not worth the subs it would throw
    // away, so neither may be dressed up as a "+X% SNR" action.
    if (rec.keepN >= population.length || rec.predictedSnrGainPct <= 0) {
      return CullRecommendationOffer(
        status: CullOfferStatus.alreadyOptimal,
        keepN: rec.keepN,
        gainPct: rec.predictedSnrGainPct,
        populationSize: population.length,
      );
    }
    return CullRecommendationOffer(
      status: CullOfferStatus.offerable,
      keepN: rec.keepN,
      gainPct: rec.predictedSnrGainPct,
      populationSize: population.length,
    );
  }

  /// Cull the accepted light subs down to the improvement curve's recommended
  /// keep-set: reject every accepted sub *not* in the optimizer's kept indices,
  /// leaving exactly `keepN` accepted. The "drop to recommended {keepN}" action
  /// the `SubCullRail` wires to the curve. No-op (returns 0) unless
  /// [cullRecommendationOffer] is offerable. Returns the number of subs newly
  /// rejected.
  Future<CullToRecommendedResult> cullToRecommended() async {
    final offer = cullRecommendationOffer;
    switch (offer.status) {
      case CullOfferStatus.none:
      case CullOfferStatus.stale:
        return CullToRecommendedResult.staleCurve;
      case CullOfferStatus.alreadyOptimal:
        return CullToRecommendedResult.alreadyOptimal;
      case CullOfferStatus.offerable:
        break;
    }

    final rec = state.improvementCurve!.recommendation;
    final population = state.improvementCurvePopulation;
    final accepted = state.acceptedLights;

    // Map the kept indices through the population's paths to the live subs to
    // keep; everything accepted but not in that keep-set is culled.
    final keepPaths = <String>{
      for (final idx in rec.keptIndices)
        if (idx >= 0 && idx < population.length) population[idx],
    };
    var rejected = 0;
    for (final sub in accepted) {
      if (keepPaths.contains(sub.filePath)) continue;
      await _images.rejectImage(
        sub.id,
        'Curve cull: outside recommended best ${rec.keepN} of ${population.length}',
      );
      rejected++;
    }
    if (rejected > 0) {
      await _reloadSubs();
      // The kept population changed; the curve recommendation no longer maps to
      // the same indices, so re-derive the backbone.
      unawaited(loadSmartData());
    }
    return CullToRecommendedResult(CullOutcome.culled, rejected);
  }

  /// Fold the current accepted subs into an accumulating master for this
  /// target+filter, creating one on first use. Used by the multi-night
  /// "add tonight's data" action.
  Future<MasterAccumulateResult?> addToAccumulatingMaster({
    required IntegratedMaster master,
  }) async {
    final accepted = state.acceptedLights
        .where((s) => _filterMatches(s.filter, master.filter))
        .toList();
    if (accepted.isEmpty) {
      state = state.copyWith(error: 'No accepted subs match this master.');
      return null;
    }
    state = state.copyWith(integrating: true, clearError: true);
    try {
      final service = _ref.read(masterAccumulationServiceProvider);
      final label = DateTime.now().toIso8601String().split('T').first;
      final result = await service.addNight(
        masterId: master.id,
        subs: accepted,
        label: label,
        settings: state.settings,
      );
      // The night was folded INTO this master, so it is now the master under
      // review for this scope.
      await _publishMasters(
        pinMasterId: master.id,
        extra: (s) => s.copyWith(integrating: false),
      );
      return result;
    } catch (e) {
      if (!mounted) return null;
      state = state.copyWith(
        integrating: false,
        error: 'Add to master failed: $e',
      );
      return null;
    }
  }

  /// Create a brand-new accumulating master for this target+filter from the
  /// best accepted sub as the reference.
  Future<int?> createAccumulatingMaster({String? filter}) async {
    final accepted = state.acceptedLights
        .where((s) => filter == null || _filterMatches(s.filter, filter))
        .toList();
    if (accepted.isEmpty) {
      state = state.copyWith(error: 'No accepted subs to seed a master.');
      return null;
    }
    state = state.copyWith(integrating: true, clearError: true);
    try {
      final service = _ref.read(masterAccumulationServiceProvider);
      final outDir = await _outputDir();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final sidecar = p.join(
        outDir,
        '${_safeName(state.title)}_${_safeName(filter ?? 'master')}_$stamp.skmaster',
      );
      final reference = _bestReference(accepted);
      final masterId = await service.createMaster(
        referenceSub: reference,
        sidecarPath: sidecar,
        settings: state.settings,
        targetId: state.targetId,
        targetName: state.targetName,
        filter: filter,
      );
      // Immediately fold the night's subs in.
      final master = await _mastersDao.getById(masterId);
      if (master != null) {
        await service.addNight(
          masterId: masterId,
          subs: accepted,
          label: DateTime.now().toIso8601String().split('T').first,
          settings: state.settings,
        );
      }
      await _publishMasters(
        pinMasterId: masterId,
        extra: (s) => s.copyWith(integrating: false),
      );
      return masterId;
    } catch (e) {
      if (!mounted) return null;
      state = state.copyWith(
        integrating: false,
        error: 'Create master failed: $e',
      );
      return null;
    }
  }

  /// Finalize an accumulating master to a shareable FITS + preview.
  Future<void> finalizeMaster(IntegratedMaster master) async {
    state = state.copyWith(integrating: true, clearError: true);
    try {
      final service = _ref.read(masterAccumulationServiceProvider);
      final outDir = await _outputDir();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final fits =
          p.join(outDir, '${_safeName(master.name)}_final_$stamp.fits');
      final preview =
          p.join(outDir, '${_safeName(master.name)}_final_$stamp.png');
      await service.finalizeMaster(
        masterId: master.id,
        masterFitsPath: fits,
        previewPngPath: preview,
      );
      await _publishMasters(
        pinMasterId: master.id,
        extra: (s) => s.copyWith(integrating: false),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        integrating: false,
        error: 'Finalize failed: $e',
      );
    }
  }

  /// Delete a master row (its fold records cascade in the DB).
  Future<void> deleteMaster(IntegratedMaster master) async {
    await _mastersDao.deleteMaster(master.id);
    // The reviewed master may be the row just deleted; _publishMasters
    // re-resolves the scope when the pinned id no longer exists.
    await _publishMasters();
  }

  static bool _filterMatches(String? subFilter, String? masterFilter) {
    final s = (subFilter ?? '').trim();
    final m = (masterFilter ?? '').trim();
    return s == m;
  }

  static String _safeName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'session' : cleaned;
  }

  /// Insert [suffix] before the extension (`master.fits` →
  /// `master_bgx.fits`). Mirrors the post-session service's path discipline so
  /// the finishing artifacts land beside the master FITS with the same
  /// `_bgx`/`_decon`/`_starred` tags the gated integration passes use.
  static String _suffixBeforeExtension(String path, String suffix) {
    final slash = path.lastIndexOf(RegExp(r'[\\/]'));
    final dot = path.lastIndexOf('.');
    if (dot <= slash) return '$path$suffix';
    return '${path.substring(0, dot)}$suffix${path.substring(dot)}';
  }

  /// Replace the path's extension (`master_bgx.fits` → `master_bgx.png`). If the
  /// file segment carries no `.`, the new extension is appended. Used to derive
  /// the sibling preview PNG a finishing artifact renders into.
  static String _swapExtension(String path, String newExt) {
    final slash = path.lastIndexOf(RegExp(r'[\\/]'));
    final dot = path.lastIndexOf('.');
    if (dot <= slash) return '$path$newExt';
    return '${path.substring(0, dot)}$newExt';
  }
}

/// Renders a finishing-artifact FITS at [inputFits] into a viewable PNG at
/// [outputPng] so the workbench can show a before/after of the
/// background-extraction / deconvolution / star-reduction passes (those native
/// passes write a linear FITS only — no preview). Injected via
/// [finishingPreviewRendererProvider] so the controller stays testable without
/// the native bridge: the production renderer auto-stretches the FITS exactly
/// like every other on-disk master preview, while tests substitute a fake.
typedef FinishingPreviewRenderer = Future<void> Function(
  String inputFits,
  String outputPng,
);

/// Production [FinishingPreviewRenderer] — delegates to
/// [ImagingBackend.renderFinishingPreview], which reads the finishing FITS,
/// computes its auto-stretch (the same MAD/STF stretch the integration preview
/// uses), applies it to an 8-bit RGBA display buffer, and writes the sibling
/// PNG. The controller's finishing actions wrap this in a fail-soft `try` so a
/// render failure never drops the (already written + persisted) finishing FITS.
final finishingPreviewRendererProvider =
    Provider<FinishingPreviewRenderer>((ref) {
  final imaging = ref.watch(imagingBackendProvider);
  return (String inputFits, String outputPng) {
    return imaging.renderFinishingPreview(
      inputFits: inputFits,
      outputPng: outputPng,
    );
  };
});

/// Family provider keyed by the review scope so a session view and a target
/// view are independent controllers.
final sessionReviewControllerProvider = StateNotifierProvider.family<
    SessionReviewController, SessionReviewState, SessionReviewScope>(
  (ref, scope) => SessionReviewController(ref, scope),
);

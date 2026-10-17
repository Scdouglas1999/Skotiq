// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Private load, finishing and accumulating-master helpers of SessionReviewController.
part of '../session_review_controller.dart';

extension _SessionReviewControllerHelpers on SessionReviewController {
  Future<void> _load({bool recomputeNightReport = false}) async {
    try {
      final settings = await _loadDefaultSettings();
      final subs = await _loadSubs();
      final (targetId, targetName) = await _resolveTarget(subs);
      final title = await _resolveTitle(targetName);
      final masters = targetId != null
          ? await _mastersDao.getForTarget(targetId)
          : await _mastersDao.getAll();
      // Scope the reviewed master to THIS review's subs (see
      // [SessionReviewState.reviewedMaster]); `masters` stays the library list.
      final reviewed = await _resolveReviewedMaster(masters, subs);
      final darkroomJob = await _loadDarkroomJob();
      final interruptedPass = await _loadInterruptedPassNotice();

      if (!mounted) return;
      state = state.copyWith(
        subs: subs,
        title: title,
        targetId: targetId,
        targetName: targetName,
        settings: settings,
        masters: masters,
        reviewedMaster: reviewed,
        clearReviewedMaster: reviewed == null,
        darkroomJob: darkroomJob,
        clearDarkroomJob: darkroomJob == null,
        interruptedPassNotice: interruptedPass,
        clearInterruptedPassNotice: interruptedPass == null,
        loading: false,
        clearError: true,
      );
      // The base list is on screen; populate the smart backbone in the
      // background so the panels fill in without blocking the first paint.
      // An operator-driven Refresh AWAITS the recompute: the caller asked for
      // a new verdict, so `refresh()` must not complete while one is still
      // being computed and written. The first load stays unawaited so the sub
      // list paints without waiting for the analysis.
      if (recomputeNightReport) {
        await loadSmartData(recomputeNightReport: true);
      } else {
        unawaited(loadSmartData());
      }
      unawaited(loadComposites());
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(loading: false, error: 'Failed to load: $e');
    }
  }

  /// The newest Darkroom pass queued for this session, or null.
  ///
  /// Session scope only: a target review spans nights that were each processed
  /// by their own job, so there is no one pass to report. The newest row wins
  /// because a re-run is the operator's answer to the run before it, and the
  /// answer is the state that stands — `listForSession` already orders newest
  /// first, so that is its first row.
  ///
  /// Its own failure is caught: this row is a report, and a database that
  /// cannot answer for it must not take the sub list, the masters and the
  /// verdict down with it. The screen then simply has no pass to state, which
  /// is what it had before this read existed.
  Future<DarkroomJob?> _loadDarkroomJob() async {
    final sessionId = _scope.sessionId;
    if (sessionId == null) return null;
    try {
      final jobs = await _ref.read(darkroomJobsDaoProvider).listForSession(
            sessionId,
          );
      return jobs.isEmpty ? null : jobs.first;
    } catch (e) {
      _ref.read(loggingServiceProvider).warning(
        'The Darkroom pass for this session could not be read, so Session '
        'Review cannot state how it ended',
        source: 'SessionReviewController',
        fields: {'sessionId': sessionId, 'error': '$e'},
      );
      return null;
    }
  }

  /// What the open-time recovery said about a post-session pass a process exit
  /// cut off on this session, or null when it said nothing.
  ///
  /// Same shape and the same reasons as [_loadDarkroomJob], for the ending that
  /// leaves no terminal row: a pass the machine died inside is discovered in
  /// `beforeOpen` and written to a `warning` Night Narrator event, which is the
  /// only typed, session-scoped record of it. Session scope only — an
  /// interruption belongs to the one night it cut short.
  ///
  /// Its own failure is caught: this is a report, and a database that cannot
  /// answer for it must not take the sub list, the masters and the verdict down
  /// with it.
  Future<String?> _loadInterruptedPassNotice() async {
    final sessionId = _scope.sessionId;
    if (sessionId == null) return null;
    try {
      final events = await _ref
          .read(narratorEventsDaoProvider)
          .getFeedForSession(sessionId);
      NarratorEventRow? newest;
      for (final event in events) {
        if (event.eventType != kInterruptedPassEventType) continue;
        // Chosen by timestamp, not by position: the feed is pinned-first, so a
        // pinned discovery reorders it. A night interrupted twice states the
        // interruption that stands.
        //
        // Row id breaks a tie, because these timestamps are stored to the
        // second and two records of one night CAN land inside one — the
        // open-time recovery writes the interruption and, when the retry cap
        // ends the same job, the correction that revokes it. The row written
        // later is the record that stands, and its id is the only thing that
        // says which one that was.
        if (newest == null ||
            event.timestamp.isAfter(newest.timestamp) ||
            (event.timestamp.isAtSameMomentAs(newest.timestamp) &&
                event.id > newest.id)) {
          newest = event;
        }
      }
      if (newest == null) return null;
      // The detector's own two sentences — which stage was cut off, how far it
      // got, and what is still owed. Nothing is re-worded here: a screen that
      // paraphrased them could only disagree with the morning feed about one
      // night.
      final body = newest.body?.trim();
      return body == null || body.isEmpty
          ? newest.headline
          : '${newest.headline} $body';
    } catch (e) {
      _ref.read(loggingServiceProvider).warning(
        'The interruption record for this session could not be read, so '
        'Session Review cannot state a pass a process exit cut off',
        source: 'SessionReviewController',
        fields: {'sessionId': sessionId, 'error': '$e'},
      );
      return null;
    }
  }

  Future<List<DbCapturedImage>> _loadSubs() async {
    if (_scope.isSession) {
      return _images.getImagesForSession(_scope.sessionId!);
    }
    return _images.getImagesForTarget(_scope.targetId!);
  }

  Future<(int?, String?)> _resolveTarget(List<DbCapturedImage> subs) async {
    if (_scope.targetId != null) {
      final t =
          await _ref.read(targetsDaoProvider).getTargetById(_scope.targetId!);
      return (_scope.targetId, t?.name);
    }
    // Session scope: derive the dominant target from the subs.
    final targetId = subs
        .map((s) => s.targetId)
        .firstWhere((id) => id != null, orElse: () => null);
    if (targetId == null) return (null, null);
    final t = await _ref.read(targetsDaoProvider).getTargetById(targetId);
    return (targetId, t?.name);
  }

  /// The reviewed target's catalog coordinates (RA in decimal hours, Dec in
  /// decimal degrees) for hinting the master plate-solve, or `(null, null)` when
  /// no target / coordinates are known (the solve then runs blind).
  Future<(double?, double?)> _resolveTargetHint() async {
    final id = state.targetId;
    if (id == null) return (null, null);
    final t = await _ref.read(targetsDaoProvider).getTargetById(id);
    if (t == null) return (null, null);
    return (t.ra, t.dec);
  }

  /// The header title for this review.
  ///
  /// A session scope is titled with the SESSION (its name plus start date/time),
  /// never `Night of <date>`: two sequences run twenty minutes apart are two
  /// separate reviews with disjoint sub sets, and titling both "Night of
  /// 2026-07-25" claimed the screen aggregated the night when it does not — and
  /// gave the user no way to tell the two apart. A target scope keeps the target
  /// name, which is accurate (it really does span every night of that target).
  Future<String> _resolveTitle(String? targetName) async {
    final target = targetName?.trim();
    if (!_scope.isSession) {
      return (target != null && target.isNotEmpty) ? target : 'Target Review';
    }
    final session =
        await _ref.read(sessionsDaoProvider).getSessionById(_scope.sessionId!);
    if (session == null) {
      return (target != null && target.isNotEmpty) ? target : 'Session Review';
    }
    final sessionName = session.name?.trim();
    final label = (sessionName != null && sessionName.isNotEmpty)
        ? sessionName
        : (target != null && target.isNotEmpty ? target : 'Session');
    final d = session.startTime.toLocal();
    final stamp = '${d.year}-${_two(d.month)}-${_two(d.day)} '
        '${_two(d.hour)}:${_two(d.minute)}';
    return '$label · $stamp';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  Future<void> _reloadSubs() async {
    final subs = await _loadSubs();
    if (!mounted) return;
    state = state.copyWith(subs: subs);
  }

  /// The Night Doctor verdict for this scope. Reuses the most-recent persisted
  /// report when it still describes this night; otherwise computes (and
  /// persists) a fresh one.
  ///
  /// A failure returns null so the rest of the smart backbone still loads, but
  /// it is NOT silent: the null case renders `NightReportPanel`'s "Analysis
  /// pending — the Night Doctor is still reviewing this session ... once
  /// analysis completes" card, which is a false statement once the analysis has
  /// thrown and nothing is left running. So the failure is logged and raised on
  /// [SessionReviewState.error], which `SessionReviewScreen` shows as a toast.
  ///
  /// Preferring the stored report unconditionally computes the verdict once per
  /// session and never again, so a night analysed before a detector fix — or
  /// while its frames were still being graded — keeps the old answer forever.
  ///
  /// Two ways out, both needed: [forceRecompute] for the operator's own
  /// Refresh, and a staleness test for the case nobody thinks to refresh — a
  /// report cannot describe frames that were captured after it was written.
  Future<NightReport?> _loadNightReport({bool forceRecompute = false}) async {
    try {
      final reports = _ref.read(nightReportsDaoProvider);
      if (!forceRecompute) {
        NightReport? stored;
        if (_scope.isSession) {
          stored = await reports.latestForSession(_scope.sessionId!);
        } else if (_scope.targetId != null) {
          final rows = await reports.getForTarget(_scope.targetId!);
          stored = rows.isEmpty ? null : rows.first;
        }
        if (stored != null &&
            (_nightReportRecomputed || !_nightReportIsStale(stored))) {
          return stored;
        }
      }
      _nightReportRecomputed = true;
      // No usable stored report — compute (and persist) one. AWAITED inside the
      // try on purpose: `return <future>` completes this function's future from
      // outside the try, so a detector that throws escaped this catch entirely,
      // left `loadingSmartData` stuck true (the tail of `loadSmartData` never
      // ran) and surfaced as an unhandled async error.
      return await _ref.read(nightAnalysisServiceProvider).computeReport(
            sessionId: _scope.sessionId,
            targetId: _scope.targetId ?? state.targetId,
          );
    } catch (e) {
      _ref.read(loggingServiceProvider).error(
        'Night Doctor analysis failed',
        source: 'SessionReviewController',
        fields: {
          'sessionId': _scope.sessionId,
          'targetId': _scope.targetId ?? state.targetId,
          'error': '$e',
        },
      );
      if (mounted) {
        state = state.copyWith(
          error: 'Night analysis failed: $e',
        );
      }
      return null;
    }
  }

  /// True when [report] cannot possibly describe the frames now in scope.
  ///
  /// The evidence a report is a verdict ON is the sub list; a sub captured at
  /// or after the report was written was not part of it. Compared against the
  /// subs already loaded into state, so this costs no query.
  bool _nightReportIsStale(NightReport report) {
    final written = report.createdAt.toUtc();
    for (final sub in state.subs) {
      if (!sub.capturedAt.toUtc().isBefore(written)) return true;
    }
    return false;
  }

  /// Decode the reviewed master's persisted marginal-SNR curve from its
  /// `improvement_curve_json` column (not surfaced on the typed model, so read
  /// directly), together with the ordered sub-path population the curve was
  /// computed over (stored as a sibling `population` key). Returns
  /// `(null, [])` when absent / corrupt — the panel placeholders.
  Future<(IntegrationCurve?, List<String>)> _loadImprovementCurve(
    int masterId,
  ) async {
    try {
      final rows = await _ref.read(databaseProvider).customSelect(
        'SELECT improvement_curve_json FROM integrated_masters '
        'WHERE id = ? LIMIT 1',
        variables: [Variable<int>(masterId)],
      ).get();
      if (rows.isEmpty) return (null, const <String>[]);
      final json = rows.first.readNullable<String>('improvement_curve_json');
      if (json == null || json.trim().isEmpty) return (null, const <String>[]);
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        final rawPopulation = decoded['population'];
        final population = <String>[
          if (rawPopulation is List)
            for (final e in rawPopulation)
              if (e is String) e,
        ];
        return (IntegrationCurve.fromJson(decoded), population);
      }
      return (null, const <String>[]);
    } catch (_) {
      return (null, const <String>[]);
    }
  }

  /// The reviewed master's multi-night growth series + best night, projected
  /// from the core [SmartProjectService] into the UI hour-based types. Both fail
  /// soft (empty / null) so a single-night master simply has no growth panel.
  Future<(List<GrowthPoint>, BestNight?)> _loadGrowthAndBestNight(
    int masterId,
  ) async {
    try {
      final smart = _ref.read(smartProjectServiceProvider);
      final corePoints = await smart.growthCurve(masterId);
      final coreBest = await smart.bestNight(masterId);
      return (
        corePoints.map(GrowthPoint.fromCore).toList(growable: false),
        coreBest != null ? BestNight.fromCore(coreBest) : null,
      );
    } catch (_) {
      return (const <GrowthPoint>[], null);
    }
  }

  /// The catalog-powered annotation layer over the finished master.
  ///
  /// Building it needs the master's solved WCS (RA/Dec reference + pixel scale),
  /// which is not plumbed onto the [IntegratedMaster] row at this layer yet —
  /// so without a WCS source this fail-softs to null and the overlay simply
  /// shows no annotation toggle. The [MasterAnnotationService] seam is wired
  /// here so the layer fills in automatically once a master WCS is surfaced.
  Future<AnnotationLayer?> _loadAnnotationLayer(IntegratedMaster master) async {
    final wcs = _resolveMasterWcs(master);
    if (wcs == null) return null;
    try {
      final service = _ref.read(masterAnnotationServiceProvider);
      final (fovW, fovH) = wcs.fieldOfView(master.width, master.height);
      final layer = await service.annotate(
        wcs: wcs,
        width: master.width,
        height: master.height,
        fovDeg: fovW > fovH ? fovW : fovH,
      );
      return layer.items.isEmpty ? null : layer;
    } catch (_) {
      return null;
    }
  }

  /// Resolve the reviewed master's solved WCS, or null when none is persisted.
  ///
  /// The master row now carries its plate-solved WCS as the eight CD-matrix
  /// scalars (v44), written by the post-session integration's fail-soft
  /// plate-solve step. `WcsOverlay` consumes the cdelt/crota form, so this
  /// derives them from the CD matrix using the inverse of the native sign
  /// convention (`WcsInfo::from_plate_solve`, `imaging/src/fits.rs`):
  /// `cd1_1 = -scale·cosθ`, `cd2_1 = scale·sinθ`, `cd2_2 = scale·cosθ`, hence
  /// `cdelt1 = -‖(cd1_1, cd2_1)‖` (RA negative), `cdelt2 = ‖(cd1_2, cd2_2)‖`,
  /// and `crota2 = atan2(cd2_1, cd2_2)`. Returns null (the honest fail-soft)
  /// until a WCS is persisted, which keeps the annotation overlay + colour
  /// calibration cleanly un-lit.
  WcsOverlay? _resolveMasterWcs(IntegratedMaster master) {
    if (!master.hasWcs) return null;
    final cd11 = master.wcsCd1_1;
    final cd12 = master.wcsCd1_2;
    final cd21 = master.wcsCd2_1;
    final cd22 = master.wcsCd2_2;
    if (cd11 == null || cd12 == null || cd21 == null || cd22 == null) {
      return null;
    }

    final cdelt1 = -math.sqrt(cd11 * cd11 + cd21 * cd21); // RA: negative.
    final cdelt2 = math.sqrt(cd12 * cd12 + cd22 * cd22);
    final crota2 = math.atan2(cd21, cd22) * 180.0 / math.pi;

    return WcsOverlay(
      crpix1: master.wcsCrpix1 ?? master.width / 2,
      crpix2: master.wcsCrpix2 ?? master.height / 2,
      crval1: master.wcsCrval1!,
      crval2: master.wcsCrval2!,
      cdelt1: cdelt1,
      cdelt2: cdelt2,
      crota2: crota2,
    );
  }

  Future<String?> _runColorCalibration(
    IntegratedMaster master,
    String inputFits,
    WcsOverlay wcs,
  ) async {
    try {
      final service = _ref.read(colorCalibrationServiceProvider);
      final output =
          SessionReviewController._suffixBeforeExtension(inputFits, '_color');
      final result = await service.calibrate(
        masterFits: inputFits,
        outputFits: output,
        wcs: wcs,
        channels: master.channels,
        whiteRefBv: state.settings.whiteRefBv,
      );
      if (ColorCalibrationService.wasSkipped(result)) {
        if (mounted) {
          state = state.copyWith(
            error: 'Color calibration found too few catalog cross-matches in '
                'this field to solve a white balance.',
          );
        }
        return null;
      }
      // Render a sibling preview PNG so the calibrated result is viewable;
      // fail-soft so a render failure never sinks the written FITS or its path.
      final previewPng =
          SessionReviewController._swapExtension(result.outputPath, '.png');
      try {
        await _ref.read(finishingPreviewRendererProvider)(
            result.outputPath, previewPng);
      } catch (_) {
        // Leave the FITS path persisted; the overlay simply shows no preview.
      }
      await _mastersDao.updateSmartFields(
        master.id,
        colorCalibratedPath: result.outputPath,
      );
      await _publishMasters();
      return result.outputPath;
    } catch (e) {
      if (mounted) {
        state = state.copyWith(error: 'Color calibration failed: $e');
      }
      return null;
    } finally {
      if (mounted) state = state.copyWith(calibrating: false);
    }
  }

  /// Shared engine for the three workbench finishing actions (background
  /// extraction / deconvolution / star reduction). Each operates on the current
  /// reviewed master's finished FITS, never re-running the stack:
  ///
  ///  1. Guard a reviewed master that carries a `masterFitsPath` on disk.
  ///  2. Flip the action's [busy] flag (via [SessionReviewController.state]).
  ///  3. [invoke] the post-session seam, writing `<master><suffix>.fits`.
  ///  4. Render a sibling preview PNG (`<master><suffix>.png`) via the injected
  ///     [finishingPreviewRendererProvider] so `MasterOverlayView` can show the
  ///     before/after — fail-soft: a render failure still keeps the FITS path.
  ///  5. [persist] the written FITS path onto the row (and [alsoMark] any extra
  ///     bookkeeping column, e.g. `background_extracted`).
  ///  6. Refresh the master list so the new artifact path round-trips on reload.
  ///
  /// Returns the written FITS path, or null when no master is in scope or the
  /// pass throws (the error surfaces on [SessionReviewState.error]).
  Future<String?> _runFinishingStep({
    required SessionReviewState Function(bool busy) busy,
    required String suffix,
    required String label,
    required Future<String> Function(
      PostSessionSeam seam,
      IntegratedMaster master,
      String output,
    ) invoke,
    required Future<void> Function(int masterId, String path) persist,
    Future<void> Function(int masterId)? alsoMark,
  }) async {
    final master = state.reviewedMaster;
    final inputFits = master?.masterFitsPath;
    if (master == null || inputFits == null || inputFits.trim().isEmpty) {
      state = state.copyWith(
        error: '$label needs a finished master FITS — integrate first.',
      );
      return null;
    }
    state = busy(true).copyWith(clearError: true);
    return _withLiveProgress(() async {
      try {
        final seam = _ref.read(postSessionSeamProvider);
        final output =
            SessionReviewController._suffixBeforeExtension(inputFits, suffix);
        final written = await invoke(seam, master, output);
        // Render a sibling preview PNG so the result is viewable; fail-soft so
        // a render failure (no native lib in a test, missing FITS) never sinks
        // the already-written finishing FITS or its persisted path.
        final previewPng =
            SessionReviewController._swapExtension(written, '.png');
        try {
          await _ref.read(finishingPreviewRendererProvider)(
              written, previewPng);
        } catch (_) {
          // Leave the FITS path persisted; the overlay shows no preview.
        }
        await persist(master.id, written);
        if (alsoMark != null) await alsoMark(master.id);
        await _publishMasters();
        return written;
      } catch (e) {
        if (mounted) state = state.copyWith(error: '$label failed: $e');
        return null;
      } finally {
        if (mounted) state = busy(false);
      }
    });
  }

  /// The in-scope master with [id], or null when not loaded.
  IntegratedMaster? _masterById(int id) {
    for (final m in state.masters) {
      if (m.id == id) return m;
    }
    return null;
  }

  DbCapturedImage _bestReference(List<DbCapturedImage> subs) {
    DbCapturedImage best = subs.first;
    for (final s in subs.skip(1)) {
      final bq = best.qualityScore, sq = s.qualityScore;
      if (sq != null && (bq == null || sq > bq)) {
        best = s;
      } else if (sq != null && bq != null && sq == bq) {
        if ((s.hfr ?? double.infinity) < (best.hfr ?? double.infinity)) {
          best = s;
        }
      }
    }
    return best;
  }

  Future<List<IntegratedMaster>> _refreshMasters() {
    final tid = state.targetId;
    return tid != null ? _mastersDao.getForTarget(tid) : _mastersDao.getAll();
  }

  /// Refresh the master library AND re-resolve [SessionReviewState.reviewedMaster],
  /// then publish both plus any [extra] state produced by the caller's action.
  ///
  /// [pinMasterId] pins the reviewed master to a specific row — the id an
  /// integration run just produced — so the screen shows the master the user
  /// just made even before its fold records are queried back. Without a pin the
  /// currently-reviewed master is kept when it still exists, else the scope is
  /// re-resolved from the fold records.
  Future<void> _publishMasters({
    int? pinMasterId,
    SessionReviewState Function(SessionReviewState)? extra,
  }) async {
    final library = await _refreshMasters();
    final wanted = pinMasterId ?? state.reviewedMaster?.id;
    IntegratedMaster? reviewed;
    if (wanted != null) {
      reviewed = _masterInListById(library, wanted) ??
          await _mastersDao.getById(wanted);
    }
    reviewed ??= await _resolveReviewedMaster(library, state.subs);
    if (!mounted) return;
    final next = state.copyWith(
      masters: library,
      reviewedMaster: reviewed,
      clearReviewedMaster: reviewed == null,
    );
    state = extra == null ? next : extra(next);
  }

  /// The persisted master that belongs to this review, or null when the
  /// session/target has produced none.
  ///
  /// Resolution is by fold record (`integrated_master_frames`): a master is in
  /// scope when it folded at least one of the subs on screen. A target-wide
  /// review additionally accepts the newest master for that target, because
  /// every master for the target is in scope by definition (and legacy rows may
  /// pre-date fold recording). A session review does NOT fall back — an honest
  /// "no finished master yet" beats another night's stack presented as this
  /// night's result.
  Future<IntegratedMaster?> _resolveReviewedMaster(
    List<IntegratedMaster> library,
    List<DbCapturedImage> subs,
  ) async {
    if (subs.isNotEmpty) {
      try {
        final scoped = await _mastersDao.masterIdsForImages(
          subs.map((s) => s.id),
        );
        if (scoped.isNotEmpty) {
          final scopedSet = scoped.toSet();
          // `library` is newest-first, so the first hit is the newest in-scope
          // master the library slice knows about.
          for (final m in library) {
            if (scopedSet.contains(m.id)) return m;
          }
          // In scope but outside the library slice (e.g. a master row with a
          // NULL target_id while this review resolved a target) — read it.
          final direct = await _mastersDao.getById(scoped.first);
          if (direct != null) return direct;
        }
      } catch (_) {
        // Fail soft: a scoping-query failure must not sink the screen. Fall
        // through to the target-scope rule below.
      }
    }
    if (!_scope.isSession && _scope.targetId != null) {
      return library.isNotEmpty ? library.first : null;
    }
    return null;
  }

  static IntegratedMaster? _masterInListById(
    List<IntegratedMaster> masters,
    int id,
  ) {
    for (final m in masters) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<String> _outputDir() async {
    final configured =
        await _ref.read(settingsDaoProvider).getImageOutputDirectory();
    if (configured.trim().isNotEmpty) {
      return p.join(configured.trim(), 'masters');
    }
    // Fall back to the documents dir under a masters subfolder.
    return p.join('.', 'masters');
  }
}

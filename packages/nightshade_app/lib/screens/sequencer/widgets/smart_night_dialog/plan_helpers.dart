// ignore_for_file: invalid_use_of_protected_member
// Strategy persistence, validation, filter-count adjustment and plan start/save helpers.
part of '../smart_night_dialog.dart';

extension _SmartNightPlanHelpers on _SmartNightDialogState {
  /// Translate the snake_case strategy id stored in app_settings back
  /// into a [SmartNightStrategy] enum value. Unknown strings fall back
  /// to [SmartNightStrategy.autoLrgb] (the constructor default).
  SmartNightStrategy _strategyFromPersistedName(String name) {
    switch (name) {
      case 'mono_lrgb':
        return SmartNightStrategy.monoLrgb;
      case 'narrowband_hoo':
        return SmartNightStrategy.narrowbandHoo;
      case 'narrowband_sho':
        return SmartNightStrategy.narrowbandSho;
      case 'osc_one_shot':
        return SmartNightStrategy.oscOneShot;
      case 'auto_lrgb':
      default:
        return SmartNightStrategy.autoLrgb;
    }
  }

  String _persistedNameForStrategy(SmartNightStrategy s) {
    switch (s) {
      case SmartNightStrategy.autoLrgb:
        return 'auto_lrgb';
      case SmartNightStrategy.monoLrgb:
        return 'mono_lrgb';
      case SmartNightStrategy.narrowbandHoo:
        return 'narrowband_hoo';
      case SmartNightStrategy.narrowbandSho:
        return 'narrowband_sho';
      case SmartNightStrategy.oscOneShot:
        return 'osc_one_shot';
    }
  }

  /// Best-effort writeback of the wizard's working [_settings] +
  /// [_strategy] into [AppSettingsState]. Called whenever the user
  /// changes a knob on steps 1/2/4 so the next launch pre-fills.
  ///
  /// Errors are swallowed (logged-only) because failing to persist a
  /// preference is a UX-degradation not a sequence-correctness issue:
  /// the user can still load the plan they've built; the next session
  /// just won't pre-fill with the same values. We surface no snackbar
  /// to avoid noise during normal usage.
  void _persistSettings() {
    if (!_settingsSeededFromAppSettings) return;
    final notifier = ref.read(appSettingsProvider.notifier);
    // Fire-and-forget — each setter writes through the DAO independently.
    // We don't await because the dialog's onChanged callbacks are sync.
    () async {
      try {
        await notifier.updateSmartNightWizardDefaults(
          maxSessionHours: _settings.maxSessionHours,
          afCadenceFrames: _settings.afEveryFrames,
          integrationBudgetMinsPerTarget:
              (_settings.defaultIntegrationBudgetHours * 60).round(),
          includeFlatsAtEnd: _settings.includeFlatsAtEnd,
          useSchedulerForMultiTarget: _settings.useSchedulerForMultiTarget,
          schedulerTargetThreshold: _settings.schedulerTargetThreshold,
          polarAlignmentStaleAfterDays: _settings.polarAlignmentStaleAfterDays,
          subExposureFloorSecs: _settings.subExposureFloorSecs,
          subExposureCeilingSecs: _settings.subExposureCeilingSecs,
          targetSnr: _settings.targetSnr,
          strategy: _persistedNameForStrategy(_strategy),
          autoSelect: _autoSelect,
          autoSelectCount: _autoSelectCount,
        );
      } catch (error, stack) {
        ref.read(loggingServiceProvider).warning(
              'Could not persist Smart Night wizard defaults: $error\n$stack',
              source: 'SmartNightDialog',
            );
      }
    }();
  }

  SmartNightService _buildService() {
    return SmartNightService(
      suggestionService: ref.read(targetSuggestionServiceProvider),
      logging: ref.read(loggingServiceProvider),
      cameraLibrary: ref.read(hardwarePresetsServiceProvider),
    );
  }

  void _onPrimaryPressed() async {
    // Guard re-entry: the strategy step kicks off the heavy builder and
    // disables the primary button, but a double-tap could still slip through
    // before the rebuild lands.
    if (_isBuildingPreview || _isStarting) return;
    switch (_step) {
      case 0:
        if (!_validateWindow()) return;
        setState(() => _step = 1);
        break;
      case 1:
        if (!_validateEquipment()) return;
        setState(() => _step = 2);
        break;
      case 2:
        if (!_validateTargets()) return;
        setState(() => _step = 3);
        break;
      case 3:
        if (!_validateStrategy()) return;
        setState(() => _isBuildingPreview = true);
        try {
          final completed = await _buildPreview();
          if (mounted && completed) setState(() => _step = 4);
        } finally {
          if (mounted) setState(() => _isBuildingPreview = false);
        }
        break;
      case 4:
        if (_preview == null) return;
        setState(() => _step = 5);
        break;
      case 5:
        await _startPlan();
        break;
    }
  }

  bool _validateWindow() {
    final start = _windowStart;
    final end = _windowEnd;
    if (start == null || end == null) {
      context.showErrorSnackBar(
        _windowError ??
            'Cannot determine tonight\'s window — set your latitude / '
                'longitude in Settings first.',
      );
      return false;
    }
    if (!end.isAfter(start)) {
      context.showErrorSnackBar(
        'Window end must be after window start.',
      );
      return false;
    }
    // Non-blocking twilight sanity check: if the user has narrowed the window
    // so it no longer overlaps tonight's astronomical-dark window at all, the
    // plan will be all-daylight/twilight. Warn up front rather than letting
    // the preview silently produce an unusable plan. We still let them
    // proceed — civil-twilight wide-field / solar-system work is legitimate.
    final twiStart = _twilightStart;
    final twiEnd = _twilightEnd;
    if (twiStart != null && twiEnd != null) {
      final overlaps = start.isBefore(twiEnd) && end.isAfter(twiStart);
      if (!overlaps) {
        context.showWarningSnackBar(
          'Your chosen window falls outside tonight\'s dark window '
          '(${_formatDateTime(twiStart)} – ${_formatDateTime(twiEnd)}). '
          'Exposures will be in twilight or daylight.',
        );
      }
    }
    return true;
  }

  bool _validateEquipment() {
    final profile = ref.read(activeEquipmentProfileProvider);
    if (profile == null) {
      context.showErrorSnackBar(
        'No active equipment profile — select one on the Equipment '
        'screen first.',
      );
      return false;
    }
    if (profile.focalLength <= 0 && profile.telescopeFocalLength == null) {
      context.showErrorSnackBar(
        'Equipment profile is missing focal length — exposure '
        'recommendations need it.',
      );
      return false;
    }
    if (profile.aperture <= 0 && profile.telescopeAperture == null) {
      context.showErrorSnackBar(
        'Equipment profile is missing aperture — exposure '
        'recommendations need it.',
      );
      return false;
    }
    return true;
  }

  bool _validateTargets() {
    final suggestionsAsync = ref.read(tonightSuggestionsProvider);
    if (suggestionsAsync.hasError) {
      context.showErrorSnackBar(
        'Could not load target suggestions: ${suggestionsAsync.error}',
      );
      return false;
    }
    final suggestions = suggestionsAsync.valueOrNull;
    if (suggestions == null) {
      context.showInfoSnackBar('Target suggestions are still loading.');
      return false;
    }
    if (suggestions.isEmpty) {
      context.showWarningSnackBar(
        'No targets meet tonight\'s altitude and score cut-offs.',
      );
      return false;
    }
    if (!_autoSelect && _selectedTargetIds.isEmpty) {
      context.showWarningSnackBar(
        'Pick at least one target, or switch to Auto-pick mode.',
      );
      return false;
    }
    return true;
  }

  bool _validateStrategy() {
    final profile = ref.read(activeEquipmentProfileProvider);
    final fits = _strategyFitsProfile(_strategy, profile);
    if (!fits) {
      context.showWarningSnackBar(
        'The selected strategy needs filters this profile doesn\'t '
        'have. Pick a different strategy or add filters to the profile.',
      );
      return false;
    }
    return true;
  }

  /// True if the selected strategy can find at least one usable filter
  /// in the active profile. We do a simple set intersection rather than
  /// reusing the service's internal helper because we want a synchronous
  /// validation before kicking the builder.
  bool _strategyFitsProfile(
    SmartNightStrategy strategy,
    EquipmentProfileModel? profile,
  ) {
    if (profile == null) return false;
    final names = profile.filterNames.map((n) => n.toLowerCase()).toSet();
    bool any(Iterable<String> wanted) => wanted.any(names.contains);
    switch (strategy) {
      case SmartNightStrategy.autoLrgb:
      case SmartNightStrategy.monoLrgb:
        return any({'l', 'lum', 'luminance', 'r', 'g', 'b'});
      case SmartNightStrategy.narrowbandHoo:
        return any({'ha', 'h-alpha', 'halpha'}) && any({'oiii', 'o3'});
      case SmartNightStrategy.narrowbandSho:
        return any({'ha', 'h-alpha', 'halpha'}) &&
            any({'oiii', 'o3'}) &&
            any({'sii', 's2'});
      case SmartNightStrategy.oscOneShot:
        // OSC works without a wheel — the service plans a single unfiltered
        // row and emits an ExposureNode with no filter selection.
        return true;
    }
  }

  /// Whether a sensor value Smart Night's exposure model needs is missing.
  ///
  /// Asked of the resolved specs rather than of the caveat text: a reworded
  /// caveat used to stop this prompt firing silently, and the exposure model
  /// then planned the night on a stand-in figure without anyone being asked.
  /// Sensor dimensions are not on the list — they set the field of view, not
  /// the exposure.
  bool _shouldPromptForCameraSpecs(ResolvedCameraSensorSpecs specs) {
    const needed = {
      SensorSpecField.pixelSize,
      SensorSpecField.readNoise,
      SensorSpecField.fullWell,
      SensorSpecField.qePeak,
    };
    return specs.unresolvedFields.any(needed.contains);
  }

  void _adjustFilterCount(
    SmartNightPlannedTarget target,
    int filterIndex,
    int delta,
  ) {
    final plan = _preview;
    if (plan == null) return;

    // Capture-time delta in seconds for this single edit. Wall-clock is
    // capture time plus a fixed per-target/per-filter overhead model the
    // builder applies; that overhead does not change when only a frame count
    // changes, so we can adjust wall-clock by the same capture delta rather
    // than re-running the (heavy) builder for every tap.
    var wallClockDeltaSecs = 0.0;

    final newPlannedTargets = <SmartNightPlannedTarget>[];
    for (final p in plan.plannedTargets) {
      if (p == target) {
        final updatedFilters = <SmartNightFilterPlan>[];
        for (var i = 0; i < p.filterPlans.length; i++) {
          if (i == filterIndex) {
            final fp = p.filterPlans[i];
            final newCount = (fp.count + delta).clamp(1, 999).toInt();
            wallClockDeltaSecs += (newCount - fp.count) * fp.durationSecs;
            updatedFilters.add(SmartNightFilterPlan(
              filterName: fp.filterName,
              count: newCount,
              durationSecs: fp.durationSecs,
              recommendation: fp.recommendation,
            ));
          } else {
            updatedFilters.add(p.filterPlans[i]);
          }
        }
        final newIntegration = updatedFilters.fold<double>(
          0,
          (s, fp) => s + fp.integrationSecs,
        );
        newPlannedTargets.add(SmartNightPlannedTarget(
          suggestion: p.suggestion,
          windowStart: p.windowStart,
          windowEnd: p.windowEnd,
          filterPlans: updatedFilters,
          integrationSecs: newIntegration,
          rationale: p.rationale,
        ));
      } else {
        newPlannedTargets.add(p);
      }
    }

    // Patch the existing plan's sequence in place — no full rebuild. The
    // SmartExposureNode counts/integration are overwritten directly, and we
    // recompute totals + wall-clock locally so the preview is internally
    // consistent (no longer borrowing wall-clock from a rebuild that used the
    // un-tweaked counts).
    final patched = SmartNightPlan(
      sequence: _patchSequenceCounts(plan.sequence, newPlannedTargets),
      plannedTargets: newPlannedTargets,
      totalIntegrationSecs: newPlannedTargets.fold<double>(
        0,
        (s, p) => s + p.integrationSecs,
      ),
      estimatedWallClockSecs: (plan.estimatedWallClockSecs + wallClockDeltaSecs)
          .clamp(0, double.infinity),
      warnings: plan.warnings,
      strategy: plan.strategy,
      settings: plan.settings,
      context: plan.context,
    );

    setState(() => _preview = patched);

    // Debounce the durable draft write so a burst of +/- taps only persists
    // the final count, not one row per tap.
    final profile = ref.read(activeEquipmentProfileProvider);
    if (profile == null) return;
    _countDraftDebounce?.cancel();
    _countDraftDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final draft = await SmartNightDraftService(
          settingsDao: ref.read(settingsDaoProvider),
        ).savePending(
          profileId: profile.id.toString(),
          astronomicalDay: patched.context.windowStart,
          plan: patched,
        );
        if (!mounted) return;
        setState(() => _previewDraftId = draft.id);
      } catch (e) {
        if (mounted) {
          context.showWarningSnackBar('Could not save adjusted counts: $e');
        }
      }
    });
  }

  /// Walk every capture node in `seq` and overwrite its per-filter counts
  /// with the user-tweaked values. We match by filter name within the same
  /// TargetHeader. A wheel-less target emits a single unfiltered
  /// [ExposureNode] instead of a [SmartExposureNode]; its count is patched
  /// from the target's one filter plan.
  Sequence _patchSequenceCounts(
    Sequence seq,
    List<SmartNightPlannedTarget> targets,
  ) {
    final byTargetName = <String, SmartNightPlannedTarget>{
      for (final t in targets) t.suggestion.targetName: t,
    };
    final newNodes = <String, SequenceNode>{...seq.nodes};

    String? targetNameFor(SequenceNode node) {
      String? parentId = node.parentId;
      while (parentId != null) {
        final parent = seq.nodes[parentId];
        if (parent is TargetHeaderNode) return parent.targetName;
        parentId = parent?.parentId;
      }
      return null;
    }

    for (final entry in seq.nodes.entries) {
      final node = entry.value;
      if (node is ExposureNode && node.frameType == FrameType.light) {
        final targetName = targetNameFor(node);
        if (targetName == null) continue;
        final tweaked = byTargetName[targetName];
        if (tweaked == null || !tweaked.isUnfiltered) continue;
        final plan = tweaked.filterPlans.single;
        newNodes[node.id] = node.copyWith(
          count: plan.count,
          durationSecs: plan.durationSecs,
        );
        continue;
      }
      if (node is! SmartExposureNode) continue;
      // Walk up to find the parent TargetHeader to identify which
      // planned target this SmartExposure belongs to.
      final targetName = targetNameFor(node);
      if (targetName == null) continue;
      final tweaked = byTargetName[targetName];
      if (tweaked == null) continue;
      final newPlans = <FilterPlan>[];
      for (final plan in node.plans) {
        final matchingTweak = tweaked.filterPlans.firstWhere(
          (fp) => fp.filterName == plan.filterName,
          orElse: () => SmartNightFilterPlan(
            filterName: plan.filterName,
            count: plan.count,
            durationSecs: plan.durationSecs,
          ),
        );
        newPlans.add(plan.copyWith(
          count: matchingTweak.count,
          durationSecs: matchingTweak.durationSecs,
        ));
      }
      newNodes[node.id] = node.copyWith(
        plans: newPlans,
        integrationBudgetSecs: tweaked.integrationSecs,
      );
    }
    return seq.copyWith(nodes: newNodes);
  }

  Future<void> _startPlan() async {
    if (_isStarting) return;
    final plan = _preview;
    if (plan == null) return;
    setState(() => _isStarting = true);
    try {
      await const SmartNightPlanLauncher().launch(
        read: ref.read,
        plan: plan,
        draftId: _previewDraftId,
      );
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Could not start Smart Night sequence: $e');
      }
      return;
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    GoRouter.maybeOf(context)?.go('/imaging');
    context.showSuccessSnackBar(
      'Smart Night plan loaded — '
      '${plan.plannedTargets.length} '
      'target${plan.plannedTargets.length == 1 ? '' : 's'}, '
      '${(plan.totalIntegrationSecs / 3600).toStringAsFixed(1)}h integration.',
    );
  }

  /// Persist the built plan's sequence as a reusable template via the
  /// sequence repository, instead of starting it. The Sequence is already
  /// assembled in [plan]; we just flag it as a template and save.
  Future<void> _savePlanAsTemplate(SmartNightPlan plan) async {
    if (_isStarting) return;
    setState(() => _isStarting = true);
    try {
      await ref
          .read(sequenceRepositoryProvider)
          .saveSequence(plan.sequence, isTemplate: true);
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Could not save template: $e');
      }
      return;
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    context.showSuccessSnackBar(
      'Saved "${plan.sequence.name}" as a template.',
    );
  }

  Future<void> _pickDateTime({
    required DateTime initial,
    required void Function(DateTime) onPicked,
  }) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.subtract(const Duration(days: 1)),
      lastDate: initial.add(const Duration(days: 7)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    onPicked(DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    ));
  }

  String _formatDuration(Duration d) =>
      DurationFormat.of(d, style: DurationStyle.compact);

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

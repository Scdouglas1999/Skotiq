part of '../smart_night_dialog.dart';

extension _SmartNightDialogStepViews on _SmartNightDialogState {
  Widget _buildHeader(SkotiqColors colors) {
    return Row(
      children: [
        Icon(LucideIcons.sparkles, size: 22, color: colors.primary),
        const SizedBox(width: 10),
        Text(
          'Smart Night — Plan Tonight',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize18,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(LucideIcons.x, size: 18),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _buildStepIndicator(SkotiqColors colors) {
    const titles = [
      'Window',
      'Equipment',
      'Targets',
      'Strategy',
      'Preview',
      'Accept',
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < titles.length; i++) ...[
            _StepChip(
              label: '${i + 1}. ${titles[i]}',
              colors: colors,
              isActive: i == _step,
              isComplete: i < _step,
            ),
            if (i < titles.length - 1)
              Container(
                width: 12,
                height: 1,
                color: colors.border,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildFooter(SkotiqColors colors) {
    final isLast = _step == 5;
    // On the Preview step the primary advances to Accept only once a plan
    // exists. When the build failed (`_previewError != null`, `_preview ==
    // null`) `_onPrimaryPressed` would silently no-op, leaving an enabled-
    // looking button that does nothing — the only real exit is the body's
    // "Back to strategy". Disable Next here so the affordance matches reality.
    final primaryDisabled =
        _isBuildingPreview || _isStarting || (_step == 4 && _preview == null);
    return Row(
      children: [
        if (_step > 0)
          TextButton.icon(
            icon: const Icon(LucideIcons.chevronLeft, size: 16),
            label: const Text('Back'),
            onPressed: () => _update(() => _step--),
          ),
        const Spacer(),
        // No footer "Cancel" — the header ✕ is the single dismissal affordance
        // (matches the AlertDialog/full-screen-wizard convention). A duplicate
        // Cancel here just competed with it for the same action.
        FilledButton.icon(
          icon: _isBuildingPreview
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  isLast ? LucideIcons.play : LucideIcons.chevronRight,
                  size: 16,
                ),
          label: Text(_isBuildingPreview
              ? 'Building…'
              : (isLast ? 'Start Sequence' : 'Next')),
          onPressed: primaryDisabled ? null : _onPrimaryPressed,
        ),
      ],
    );
  }

  // Step body

  Widget _buildStepBody(SkotiqColors colors) {
    switch (_step) {
      case 0:
        return _buildWindowStep(colors);
      case 1:
        return _buildEquipmentStep(colors);
      case 2:
        return _buildTargetsStep(colors);
      case 3:
        return _buildStrategyStep(colors);
      case 4:
        return _buildPreviewStep(colors);
      case 5:
        return _buildAcceptStep(colors);
      default:
        return const SizedBox.shrink();
    }
  }

  // Step 1: window

  Widget _buildWindowStep(SkotiqColors colors) {
    _ensureWindowInitialised();
    final start = _windowStart;
    final end = _windowEnd;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tonight\'s dark window',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize15,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Computed from your location\'s astronomical twilight. '
            'You can narrow it if you don\'t want to image the full night.',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          if (start == null || end == null)
            _windowError == null
                ? _MissingLocationCard(colors: colors)
                : _WindowUnavailableCard(
                    colors: colors,
                    message: _windowError!,
                  )
          else
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
                border: Border.all(color: colors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.sunset, size: 16, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Start: ${_formatDateTime(start)}',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: SkotiqTypography.fontSize13,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => _pickDateTime(
                          initial: start,
                          onPicked: (dt) => _update(() => _windowStart = dt),
                        ),
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Icon(LucideIcons.sunrise,
                          size: 16, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'End: ${_formatDateTime(end)}',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: SkotiqTypography.fontSize13,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => _pickDateTime(
                          initial: end,
                          onPicked: (dt) => _update(() => _windowEnd = dt),
                        ),
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Total: ${_formatDuration(end.difference(start))}',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: SkotiqTypography.fontSize12,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 18),
          _SettingsRow(
            label: 'Max session length',
            colors: colors,
            child: _CompactNumberField(
              initial: _settings.maxSessionHours,
              suffix: 'h',
              onChanged: (v) {
                _update(() => _settings =
                    _settings.copyWith(maxSessionHours: v.clamp(1.0, 14.0)));
                _persistSettings();
              },
            ),
          ),
          _SettingsRow(
            label: 'Min altitude',
            colors: colors,
            child: _CompactNumberField(
              initial: _settings.minAltitudeDeg,
              suffix: '°',
              onChanged: (v) => _update(() => _settings =
                  _settings.copyWith(minAltitudeDeg: v.clamp(10.0, 80.0))),
            ),
          ),
        ],
      ),
    );
  }

  // Step 2: equipment

  Widget _buildEquipmentStep(SkotiqColors colors) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    if (profile == null) {
      return _MissingProfileCard(colors: colors);
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Active equipment profile',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize15,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ProfileRow(
                  icon: LucideIcons.tag,
                  label: 'Name',
                  value: profile.name,
                  colors: colors,
                ),
                _ProfileRow(
                  icon: LucideIcons.camera,
                  label: 'Camera',
                  value: profile.cameraName ?? '<no camera>',
                  colors: colors,
                ),
                _ProfileRow(
                  icon: LucideIcons.target,
                  label: 'OTA',
                  value: '${profile.telescopeName ?? "<no telescope>"} '
                      '(${profile.focalLength.toStringAsFixed(0)}mm @ '
                      'f/${(profile.calculatedFocalRatio ?? 0).toStringAsFixed(1)})',
                  colors: colors,
                ),
                _ProfileRow(
                  icon: LucideIcons.compass,
                  label: 'Mount',
                  value: profile.mountName ?? '<no mount>',
                  colors: colors,
                ),
                _ProfileRow(
                  icon: LucideIcons.layers,
                  label: 'Filters',
                  value: profile.filterNames.isEmpty
                      ? '<no filter wheel>'
                      : profile.filterNames.join(', '),
                  colors: colors,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Inline fix path: edit the active profile without leaving the
          // wizard. The step ref.watch(activeEquipmentProfileProvider), so it
          // auto-refreshes once the editor closes.
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              onPressed: () => ProfileEditorDialog.show(context),
              icon: LucideIcons.settings2,
              label: 'Edit profile',
              variant: ButtonVariant.outline,
              size: ButtonSize.small,
            ),
          ),
          const SizedBox(height: 16),
          _SettingsRow(
            label: 'Cool to',
            colors: colors,
            child: _CompactNumberField(
              initial: _settings.coolDownTargetC,
              suffix: '°C',
              onChanged: (v) => _update(
                  () => _settings = _settings.copyWith(coolDownTargetC: v)),
            ),
          ),
          _SettingsRow(
            label: 'Has flat panel',
            colors: colors,
            child: SkotiqSwitch(
              value: _settings.hasCoverCalibrator,
              onChanged: (v) => _update(
                  () => _settings = _settings.copyWith(hasCoverCalibrator: v)),
            ),
          ),
          if (profile.coverCalibratorId != null &&
              !_settings.hasCoverCalibrator)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 6),
              child: Text(
                'A cover calibrator is bound to this profile — toggle '
                'this on to schedule auto-flats at session end.',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: SkotiqTypography.fontSize11,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Step 3: targets

  Widget _buildTargetsStep(SkotiqColors colors) {
    final suggestionsAsync = ref.watch(tonightSuggestionsProvider);
    final plannedCount = _plannedTargetCount(suggestionsAsync.valueOrNull);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Pick tonight\'s targets',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize15,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (plannedCount != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: SkotiqDecorations.statusChip(
                  plannedCount == 0 ? colors.warning : colors.primary,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
                child: Text(
                  plannedCount == 0
                      ? 'None will be planned'
                      : '$plannedCount will be planned',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    fontWeight: FontWeight.w600,
                    color: plannedCount == 0 ? colors.warning : colors.primary,
                  ),
                ),
              ),
          ],
        ),
        if (widget.seedSourceLabel != null) ...[
          const SizedBox(height: 8),
          _SeedSourceBanner(
            label: widget.seedSourceLabel!,
            missingNames: _seededTargetsNotUpTonight(
              suggestionsAsync.valueOrNull,
            ),
            colors: colors,
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              _autoSelect
                  ? 'Auto-pick the top'
                  : 'Hand-pick from suggestions below',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize12,
              ),
            ),
            if (_autoSelect) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: _CompactNumberField(
                  initial: _autoSelectCount.toDouble(),
                  suffix: '',
                  onChanged: (v) {
                    _update(
                      () => _autoSelectCount = v.round().clamp(1, 10),
                    );
                    _persistSettings();
                  },
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'by score',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: SkotiqTypography.fontSize12,
                ),
              ),
            ],
            const Spacer(),
            FilterChip(
              label: const Text('Auto-pick'),
              selected: _autoSelect,
              onSelected: (v) {
                _update(() {
                  _autoSelect = v;
                  if (v) _selectedTargetIds.clear();
                });
                _persistSettings();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: suggestionsAsync.when(
            data: (suggestions) {
              if (suggestions.isEmpty) {
                return _EmptyTargetsCard(colors: colors);
              }
              return ListView.builder(
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final s = suggestions[index];
                  return _TargetTile(
                    suggestion: s,
                    isSelected:
                        _autoSelect || _selectedTargetIds.contains(s.targetId),
                    isAutoMode: _autoSelect,
                    rank: index + 1,
                    autoPickedTop: _autoSelect && index < _autoSelectCount,
                    onToggle: () {
                      if (_autoSelect) return;
                      _update(() {
                        if (_selectedTargetIds.contains(s.targetId)) {
                          _selectedTargetIds.remove(s.targetId);
                        } else {
                          _selectedTargetIds.add(s.targetId);
                        }
                      });
                    },
                    colors: colors,
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Failed to load suggestions: $e',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.error),
                  ),
                  const SizedBox(height: 10),
                  SkotiqButton(
                    label: 'Retry',
                    icon: LucideIcons.refreshCw,
                    variant: ButtonVariant.outline,
                    size: ButtonSize.small,
                    onPressed: () => ref.invalidate(tonightSuggestionsProvider),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Names of seeded (project) targets that are NOT in tonight's ranked
  /// suggestions — i.e. they fall below the altitude/score cut-offs tonight and
  /// will not be planned. Returned for honest disclosure in the seed banner
  /// rather than silently dropping them. Empty when every seeded target is up,
  /// or when suggestions haven't loaded yet (`null` in) — we only warn about a
  /// confirmed absence.
  List<String> _seededTargetsNotUpTonight(List<TargetSuggestion>? suggestions) {
    final seed = widget.seedTargetIds;
    if (seed == null || seed.isEmpty || suggestions == null) {
      return const [];
    }
    final upIds = suggestions.map((s) => s.targetId).toSet();
    final missing = <String>[];
    for (final id in seed) {
      if (upIds.contains(id)) continue;
      // The name isn't in tonight's ranking, so we can't read it from a
      // suggestion. Surface the id so the operator can still identify it; the
      // banner copy frames these as "below tonight's cut-offs".
      missing.add('#$id');
    }
    return missing;
  }

  /// How many targets will actually be planned given the current selection
  /// mode and tonight's ranking. In auto mode that's min(count, available);
  /// in hand-pick mode it's the number of selected ids that appear in the
  /// ranking (the ranking is the source of truth for imageable-tonight).
  /// Returns null until suggestions have loaded.
  int? _plannedTargetCount(List<TargetSuggestion>? suggestions) {
    if (suggestions == null) return null;
    if (_autoSelect) {
      return _autoSelectCount < suggestions.length
          ? _autoSelectCount
          : suggestions.length;
    }
    final upIds = suggestions.map((s) => s.targetId).toSet();
    return _selectedTargetIds.where(upIds.contains).length;
  }

  // Step 4: strategy

  Widget _buildStrategyStep(SkotiqColors colors) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choose imaging strategy',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize15,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          for (final s in SmartNightStrategy.values)
            _StrategyTile(
              strategy: s,
              isSelected: _strategy == s,
              filtersAvailable: _strategyFitsProfile(s, profile),
              onSelected: () {
                _update(() => _strategy = s);
                _persistSettings();
              },
              colors: colors,
            ),
          const SizedBox(height: 18),
          Text(
            'Autofocus cadence',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 8),
          _AfCadenceSelector(
            value: _settings,
            onChanged: (v) {
              _update(() => _settings = v);
              _persistSettings();
            },
            colors: colors,
          ),
          const SizedBox(height: 18),
          _SettingsRow(
            label: 'Integration budget per target',
            colors: colors,
            child: _CompactNumberField(
              initial: _settings.defaultIntegrationBudgetHours,
              suffix: 'h',
              onChanged: (v) {
                _update(() => _settings =
                    _settings.copyWith(defaultIntegrationBudgetHours: v));
                _persistSettings();
              },
            ),
          ),
          _SettingsRow(
            label: 'Sub-exposure floor',
            colors: colors,
            child: _CompactNumberField(
              initial: _settings.subExposureFloorSecs,
              suffix: 's',
              onChanged: (v) {
                _update(() =>
                    _settings = _settings.copyWith(subExposureFloorSecs: v));
                _persistSettings();
              },
            ),
          ),
          _SettingsRow(
            label: 'Sub-exposure ceiling',
            colors: colors,
            child: _CompactNumberField(
              initial: _settings.subExposureCeilingSecs,
              suffix: 's',
              onChanged: (v) {
                _update(() =>
                    _settings = _settings.copyWith(subExposureCeilingSecs: v));
                _persistSettings();
              },
            ),
          ),
          _SettingsRow(
            label: 'Target SNR',
            colors: colors,
            child: _CompactNumberField(
              initial: _settings.targetSnr,
              suffix: '',
              onChanged: (v) {
                _update(() => _settings = _settings.copyWith(targetSnr: v));
                _persistSettings();
              },
            ),
          ),
          _SettingsRow(
            label: 'Auto flats at end',
            colors: colors,
            child: SkotiqSwitch(
              value: _settings.includeFlatsAtEnd,
              onChanged: (v) {
                _update(
                    () => _settings = _settings.copyWith(includeFlatsAtEnd: v));
                _persistSettings();
              },
            ),
          ),
          _SettingsRow(
            label: 'Auto-schedule missing darks',
            colors: colors,
            child: SkotiqSwitch(
              value: _settings.autoScheduleMissingDarks,
              onChanged: (v) {
                _update(() => _settings =
                    _settings.copyWith(autoScheduleMissingDarks: v));
              },
            ),
          ),
        ],
      ),
    );
  }

  // Step 5: preview

  Widget _buildPreviewStep(SkotiqColors colors) {
    if (_preview == null && _previewError == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_previewError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.alertCircle, size: 32, color: colors.error),
            const SizedBox(height: 8),
            Text(
              'Cannot build plan',
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _previewError!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: SkotiqTypography.fontSize12),
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(LucideIcons.chevronLeft, size: 14),
              label: const Text('Back to strategy'),
              onPressed: () => _update(() => _step = 3),
            ),
          ],
        ),
      );
    }
    final plan = _preview!;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlanSummary(plan: plan),
          const SizedBox(height: 12),
          for (final p in plan.plannedTargets)
            _PlannedTargetCard(
              planned: p,
              colors: colors,
              onCountChanged: (filterIndex, delta) {
                _adjustFilterCount(p, filterIndex, delta);
              },
            ),
          SmartNightSafetyWatchdogsSection(plan: plan, colors: colors),
          if (plan.warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Warnings',
              style: SkotiqTypography.labelStrong
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 6),
            for (final w in plan.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      LucideIcons.alertTriangle,
                      size: 14,
                      color: colors.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        w,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  // Step 6: accept

  Widget _buildAcceptStep(SkotiqColors colors) {
    final plan = _preview;
    if (plan == null) {
      return Center(
        child: Text(
          'No plan to load — please re-run preview.',
          style: TextStyle(color: colors.textSecondary),
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.checkCircle,
                        size: 20, color: colors.success),
                    const SizedBox(width: 10),
                    Text(
                      'Plan ready',
                      style: SkotiqTypography.h4
                          .copyWith(color: colors.textPrimary),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  plan.sequence.name,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: SkotiqTypography.fontSize14,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  plan.sequence.description,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: SkotiqTypography.fontSize12,
                  ),
                ),
                const SizedBox(height: 14),
                _SummaryRow(
                  icon: LucideIcons.target,
                  label: 'Targets',
                  value: '${plan.plannedTargets.length}',
                  colors: colors,
                ),
                _SummaryRow(
                  icon: LucideIcons.camera,
                  label: 'Total integration',
                  value: _formatDuration(
                    Duration(seconds: plan.totalIntegrationSecs.round()),
                  ),
                  colors: colors,
                ),
                _SummaryRow(
                  icon: LucideIcons.clock,
                  label: 'Estimated wall-clock',
                  value: _formatDuration(
                    Duration(seconds: plan.estimatedWallClockSecs.round()),
                  ),
                  colors: colors,
                ),
                _SummaryRow(
                  icon: LucideIcons.list,
                  label: 'Sequence nodes',
                  value: '${plan.sequence.nodes.length}',
                  colors: colors,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Tapping "Start Sequence" replaces the current sequence with '
            'this plan, starts the executor, and opens the Imaging screen '
            'so you can monitor the run immediately.',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: SkotiqTypography.fontSize12,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              onPressed: () => unawaited(_savePlanAsTemplate(plan)),
              icon: LucideIcons.save,
              label: 'Save as template instead',
              variant: ButtonVariant.outline,
              size: ButtonSize.small,
            ),
          ),
        ],
      ),
    );
  }

  // Wiring + helpers
}

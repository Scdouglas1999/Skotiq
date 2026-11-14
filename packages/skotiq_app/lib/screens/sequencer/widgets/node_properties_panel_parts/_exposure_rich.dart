part of '../node_properties_panel.dart';

/// Marker index for the synthetic "stored filter not available" dropdown
/// row. It is display-only — selecting it never rewrites the node.
const int _kMissingFilterSentinel = -999;

/// Soft thresholds above which the editor surfaces a non-blocking "this is
/// unusually long" warning under a duration/delay field. The values are still
/// accepted; the note just nudges the user to confirm it was intentional.
const double _kLongExposureWarnSecs = 1200;
const double _kLongDelayWarnSecs = 1800;

class _ExposureProperties extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final ExposureNode node;

  const _ExposureProperties({required this.colors, required this.node});

  @override
  ConsumerState<_ExposureProperties> createState() => _ExposureRichState();
}

class _ExposureRichState extends ConsumerState<_ExposureProperties> {
  // Track whether values have been explicitly overridden by the user in this
  // editing session. When false, the displayed value is the profile default.
  // We use a Set of property names to track which properties the user has
  // explicitly touched during this session.
  final Set<String> _userOverrides = {};
  bool _isRunningTestExposure = false;

  @override
  void initState() {
    super.initState();
    _detectInitialOverrides();
  }

  @override
  void didUpdateWidget(_ExposureProperties oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.id != widget.node.id) {
      _userOverrides.clear();
      _detectInitialOverrides();
    }
  }

  /// Determine which properties were explicitly set on the node (non-null
  /// values that differ from profile defaults). Properties that are null
  /// or match the profile default are treated as "using profile default".
  void _detectInitialOverrides() {
    final profile = ref.read(activeEquipmentProfileProvider);
    final node = widget.node;

    // Gain/offset use null == "inherit profile default". Any *non-null* stored
    // value is, by definition, an explicit override — even when it happens to
    // equal the current profile default or zero. Treating gain==0 or
    // gain==profileDefault as inherited demotes a real override on reopen, so a
    // deliberate gain of 0 would drift when the profile changed.
    if (node.gain != null) {
      _userOverrides.add('gain');
    }
    if (node.offset != null) {
      _userOverrides.add('offset');
    }

    // Binning is a non-nullable BinningMode and so can't express "inherit" at
    // the model level (see modelChangeRequests). Until a nullable
    // binningOverride lands we keep the value-compare heuristic: a node whose
    // binning differs from the profile default is treated as an override.
    final profileBinning = profile?.defaultBinX ?? 1;
    final nodeBinning = _binningModeToInt(node.binning);
    if (nodeBinning != profileBinning) {
      _userOverrides.add('binning');
    }
  }

  bool _isGainProfileDefault() => !_userOverrides.contains('gain');
  bool _isOffsetProfileDefault() => !_userOverrides.contains('offset');
  bool _isBinningProfileDefault() => !_userOverrides.contains('binning');

  int _binningModeToInt(BinningMode mode) {
    switch (mode) {
      case BinningMode.one:
        return 1;
      case BinningMode.two:
        return 2;
      case BinningMode.three:
        return 3;
      case BinningMode.four:
        return 4;
    }
  }

  int _effectiveGain(EquipmentProfileModel? profile) {
    if (_userOverrides.contains('gain') && widget.node.gain != null) {
      return widget.node.gain!;
    }
    return profile?.defaultGain ?? widget.node.gain ?? 0;
  }

  int _effectiveOffset(EquipmentProfileModel? profile) {
    if (_userOverrides.contains('offset') && widget.node.offset != null) {
      return widget.node.offset!;
    }
    return profile?.defaultOffset ?? widget.node.offset ?? 0;
  }

  int _effectiveBinningX(EquipmentProfileModel? profile) {
    if (_isBinningProfileDefault()) {
      return profile?.defaultBinX ?? _binningModeToInt(widget.node.binning);
    }
    return _binningModeToInt(widget.node.binning);
  }

  int _effectiveBinningY(EquipmentProfileModel? profile) {
    if (_isBinningProfileDefault()) {
      return profile?.defaultBinY ?? _binningModeToInt(widget.node.binning);
    }
    return _binningModeToInt(widget.node.binning);
  }

  Future<void> _runTestExposure(EquipmentProfileModel? profile) async {
    if (_isRunningTestExposure) return;

    setState(() => _isRunningTestExposure = true);

    final node = widget.node;
    final settings = ExposureSettings(
      exposureTime: node.durationSecs,
      gain: _effectiveGain(profile),
      offset: _effectiveOffset(profile),
      binningX: _effectiveBinningX(profile),
      binningY: _effectiveBinningY(profile),
      filter: node.filter,
      // A test exposure is an out-of-sequence preview, so it captures as a
      // SNAPSHOT (not written into the sequence's frame set).
      // exposure_properties_recommendation_test.dart pins that.
      frameType: FrameType.snapshot,
      fastReadout: false,
    );

    try {
      final image = await ref.read(imagingServiceProvider).captureImage(
            settings: settings,
            targetName: '${node.name} test',
          );

      if (image != null) {
        ref.read(currentImageProvider.notifier).state = image;
        ref.read(lastImageStatsProvider.notifier).state = image.stats;
      }

      if (!mounted) return;
      context.showInfoSnackBar(
        image == null ? 'Test exposure completed' : 'Test exposure saved',
        duration: const Duration(seconds: 2),
      );
    } catch (error) {
      if (!mounted) return;
      context.showErrorSnackBar(
        'Test exposure failed: ${userFacingError(error)}',
      );
    } finally {
      if (mounted) {
        setState(() => _isRunningTestExposure = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final node = widget.node;
    final profile = ref.watch(activeEquipmentProfileProvider);
    final sensitivity = ref.watch(cameraSensitivityProvider);
    void setGain(int gain) {
      setState(() => _userOverrides.add('gain'));
      ref.read(currentSequenceProvider.notifier).updateNode(
            node.copyWith(gain: gain),
          );
      ref
          .read(sequencerDefaultsProvider.notifier)
          .updateExposureDefaults(gain: gain);
    }

    final exposureContext =
        ref.watch(smartNightExposureContextProvider).valueOrNull;
    final exposureRecommendation =
        exposureContext?.recommendForFilter(node.filter);
    // Belt-and-suspenders gate. The parent _NodeEditor
    // already wraps the editor body in IgnorePointer when running; wrap the
    // largest properties form in IgnorePointer too so an extraction refactor
    // can't un-gate the dozens of inputs below.
    final canEdit = ref.watch(canEditSequenceProvider);

    return IgnorePointer(
      ignoring: !canEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NodeSectionHeader(colors: colors, label: 'Exposure settings'),
          const SizedBox(height: 12),

          NodePropertyField(
            colors: colors,
            label: 'Duration',
            child: NodeNumberInput(
              colors: colors,
              value: node.durationSecs,
              suffix: 's',
              min: ExposureFieldLimits.durationSecs.min,
              max: ExposureFieldLimits.durationSecs.max,
              // 3 decimals to match the inline editor; sub-second exposures
              // matter for lucky imaging / fast photometry.
              decimals: 3,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(durationSecs: value),
                    );
                ref
                    .read(sequencerDefaultsProvider.notifier)
                    .updateExposureDefaults(
                      duration: value,
                    );
              },
            ),
          ),

          if (node.durationSecs > _kLongExposureWarnSecs)
            _LongValueWarning(
              colors: colors,
              message:
                  'This is an unusually long sub-exposure — confirm this is '
                  'intentional.',
            ),

          if (exposureRecommendation != null) ...[
            const SizedBox(height: 8),
            _ExposureRecommendationCard(
              colors: colors,
              recommendation: exposureRecommendation,
              currentDurationSecs: node.durationSecs,
              onApply: () {
                final seconds = exposureRecommendation.seconds;
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(durationSecs: seconds),
                    );
                ref
                    .read(sequencerDefaultsProvider.notifier)
                    .updateExposureDefaults(
                      duration: seconds,
                    );
              },
            ),
          ],

          NodePropertyField(
            colors: colors,
            label: 'Count',
            child: NodeNumberInput(
              colors: colors,
              value: node.count.toDouble(),
              min: ExposureFieldLimits.frameCount.min.toDouble(),
              max: ExposureFieldLimits.frameCount.max.toDouble(),
              onChanged: (value) {
                final count = value.toInt();
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(count: count),
                    );
                ref
                    .read(sequencerDefaultsProvider.notifier)
                    .updateExposureDefaults(
                      count: count,
                    );
              },
            ),
          ),

          NodePropertyField(
            colors: colors,
            label: 'Frame type',
            child: NodeDropdown<FrameType>(
              colors: colors,
              value: node.frameType,
              items: FrameType.values,
              // Sentence case, like every other label on the screen: a
              // dropdown value is a word, not a shout.
              labelBuilder: (t) =>
                  t.name[0].toUpperCase() + t.name.substring(1),
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(frameType: value),
                    );
              },
            ),
          ),

          _buildFilterDropdown(context),

          NodePropertyField(
            colors: colors,
            label: _isBinningProfileDefault()
                ? 'Binning (profile default)'
                : 'Binning',
            child: NodeDropdown<BinningMode>(
              colors: colors,
              value: node.binning,
              items: BinningMode.values,
              labelBuilder: (b) => b.label,
              onChanged: (value) {
                setState(() => _userOverrides.add('binning'));
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(binning: value),
                    );
                ref
                    .read(sequencerDefaultsProvider.notifier)
                    .updateExposureDefaults(
                      binning: value,
                    );
              },
            ),
          ),

          Row(
            children: [
              if (sensitivity.hasGain)
                Expanded(
                  child: NodePropertyField(
                    colors: colors,
                    label: _isGainProfileDefault()
                        ? '${sensitivity.label} (profile)'
                        : sensitivity.label,
                    child: SensitivityField(
                      value: _effectiveGain(profile),
                      sensitivity: sensitivity,
                      onChanged: setGain,
                      gainField: (_) => NodeNumberInput(
                        colors: colors,
                        value: _effectiveGain(profile).toDouble(),
                        min: ExposureFieldLimits.gain.min.toDouble(),
                        max: ExposureFieldLimits.gain.max.toDouble(),
                        isProfileDefault: _isGainProfileDefault(),
                        hintText: _isGainProfileDefault() &&
                                profile?.defaultGain != null
                            ? 'Profile: ${profile!.defaultGain}'
                            : null,
                        onChanged: (value) => setGain(value.toInt()),
                      ),
                    ),
                  ),
                ),
              if (sensitivity.hasOffset) ...[
                if (sensitivity.hasGain) const SizedBox(width: 12),
                Expanded(
                  child: NodePropertyField(
                    colors: colors,
                    label: _isOffsetProfileDefault()
                        ? 'Offset (profile)'
                        : 'Offset',
                    child: NodeNumberInput(
                      colors: colors,
                      value: _effectiveOffset(profile).toDouble(),
                      min: ExposureFieldLimits.offset.min.toDouble(),
                      max: ExposureFieldLimits.offset.max.toDouble(),
                      isProfileDefault: _isOffsetProfileDefault(),
                      hintText: _isOffsetProfileDefault() &&
                              profile?.defaultOffset != null
                          ? 'Profile: ${profile!.defaultOffset}'
                          : null,
                      onChanged: (value) {
                        final offset = value.toInt();
                        setState(() => _userOverrides.add('offset'));
                        ref.read(currentSequenceProvider.notifier).updateNode(
                              node.copyWith(offset: offset),
                            );
                        ref
                            .read(sequencerDefaultsProvider.notifier)
                            .updateExposureDefaults(
                              offset: offset,
                            );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),

          NodePropertyField(
            colors: colors,
            label: 'Dither every',
            child: NodeNumberInput(
              colors: colors,
              value: (node.ditherEvery ?? 0).toDouble(),
              suffix: ' frames',
              min: ExposureFieldLimits.ditherEvery.min.toDouble(),
              max: ExposureFieldLimits.ditherEvery.max.toDouble(),
              onChanged: (value) {
                final ditherEvery = value.toInt();
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(ditherEvery: ditherEvery),
                    );
                ref
                    .read(sequencerDefaultsProvider.notifier)
                    .updateExposureDefaults(
                      ditherEvery: ditherEvery,
                    );
              },
            ),
          ),

          // Sky-brightness adaptive exposure block.
          // Off by default; expanding shows the SNR / reference / min /
          // max controls + per-filter overrides.
          const SizedBox(height: 12),
          _AdaptiveExposureSection(
            colors: colors,
            node: node,
          ),

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isRunningTestExposure
                  ? null
                  : () => _runTestExposure(profile),
              icon: Icon(
                _isRunningTestExposure
                    ? LucideIcons.loader2
                    : LucideIcons.camera,
                size: 15,
              ),
              label: Text(
                _isRunningTestExposure
                    ? 'Running Test Exposure'
                    : 'Run test exposure',
              ),
            ),
          ),

          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: SkotiqDecorations.tintedBadge(
              colors.primary,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.clock, size: 14, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  'Total: ${DurationFormat.seconds(node.totalDurationSecs, style: DurationStyle.short)}',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 13),
                    fontWeight: FontWeight.w500,
                    color: colors.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterDropdown(BuildContext context) {
    final colors = widget.colors;
    final node = widget.node;

    final filterNames = ref.watch(effectiveFiltersProvider);

    final filterOptions = <({int index, String name})>[
      (index: -1, name: ''), // No filter option
      for (int i = 0; i < filterNames.length; i++)
        (index: i, name: filterNames[i]),
    ];

    if (kDebugMode) {
      Log.debug(
        '_buildFilterDropdown: node.filter="${node.filter}" node.filterIndex=${node.filterIndex} filterNames=$filterNames',
        source: 'InstructionNodeProperties',
      );
    }
    final matched = filterOptions.firstWhereOrNull(
      (f) =>
          (node.filterIndex != null && f.index == node.filterIndex) ||
          (node.filterIndex == null && f.name == (node.filter ?? '')),
    );

    // If the stored filter is no longer available, surface it as an
    // explicit "(not available)" option and select it, rather than silently
    // snapping to the first filter (which would quietly rewrite the node).
    // `_kMissingFilterSentinel` marks that synthetic row so the renderer and
    // onChanged handler can treat it specially.
    final storedFilterName = node.filter ?? '';
    final bool missingFromList = matched == null &&
        (node.filterIndex != null || storedFilterName.isNotEmpty);
    if (missingFromList) {
      final label = storedFilterName.isNotEmpty
          ? '$storedFilterName (not available)'
          : 'Filter #${node.filterIndex} (not available)';
      filterOptions.add((index: _kMissingFilterSentinel, name: label));
    }
    final currentFilter =
        matched ?? (missingFromList ? filterOptions.last : filterOptions.first);
    if (kDebugMode) {
      Log.debug(
        '_buildFilterDropdown: currentFilter=(index:${currentFilter.index}, name:"${currentFilter.name}")',
        source: 'InstructionNodeProperties',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodePropertyField(
          colors: colors,
          label: 'Filter',
          child: filterNames.isEmpty
              ? NodeTextInput(
                  colors: colors,
                  value: node.filter ?? '',
                  hint: noFiltersToPickHint,
                  onChanged: (value) {
                    final filter = value.isEmpty ? null : value;
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(
                              filter: filter, clearFilter: filter == null),
                        );
                    ref
                        .read(sequencerDefaultsProvider.notifier)
                        .updateExposureDefaults(
                          filter: filter,
                        );
                  },
                )
              : Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: colors.surfaceAlt,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(color: colors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: AccessibleDropdown<({int index, String name})>(
                      value: currentFilter,
                      isExpanded: true,
                      icon: Icon(
                        LucideIcons.chevronDown,
                        size: 16,
                        color: colors.textMuted,
                      ),
                      dropdownColor: colors.surface,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        color: colors.textPrimary,
                      ),
                      items: filterOptions.map((filter) {
                        final String label;
                        if (filter.index == _kMissingFilterSentinel) {
                          label = filter.name;
                        } else if (filter.index < 0) {
                          label = '(None)';
                        } else {
                          label = filter.name;
                        }
                        return DropdownMenuItem(
                          value: filter,
                          child: Text(label),
                        );
                      }).toList(),
                      onChanged: (newValue) {
                        if (newValue != null) {
                          // The synthetic "not available" row is display-only;
                          // re-selecting it must not rewrite the node.
                          if (newValue.index == _kMissingFilterSentinel) return;
                          final isNone = newValue.index < 0;
                          final filter = isNone ? null : newValue.name;
                          final filterIndex = isNone ? null : newValue.index;
                          ref.read(currentSequenceProvider.notifier).updateNode(
                                node.copyWith(
                                  filter: filter,
                                  filterIndex: filterIndex,
                                  clearFilter: isNone,
                                ),
                              );
                          ref
                              .read(sequencerDefaultsProvider.notifier)
                              .updateExposureDefaults(
                                filter: filter,
                              );
                        }
                      },
                    ),
                  ),
                ),
        ),
        if (missingFromList) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          // ONE inline line, not a paragraph: it says what is wrong and what
          // to do, and the button beside it is the doing.
          Row(
            children: [
              Icon(LucideIcons.alertTriangle, size: 12, color: colors.warning),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Expanded(
                child: Text(
                  'Filter is not on the wheel or in the profile.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.warning,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceSm),
        // A real button, not a link dressed as a row of muted text. Disabled
        // when there is no profile to edit, with the reason on the control
        // rather than in a sentence beside it.
        Align(
          alignment: Alignment.centerLeft,
          child: Builder(
            builder: (context) {
              final profile = ref.watch(activeEquipmentProfileProvider);
              return SkotiqButton(
                label: 'Edit filters',
                icon: LucideIcons.settings,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                semanticsHint: profile == null
                    ? 'No equipment profile is active, so there are no '
                        'filters to edit.'
                    : null,
                onPressed: profile == null
                    ? null
                    : () => ProfileEditorDialog.show(context, profile: profile),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ExposureRecommendationCard extends StatelessWidget {
  final SkotiqColors colors;
  final ExposureRecommendation recommendation;
  final double currentDurationSecs;
  final VoidCallback onApply;

  const _ExposureRecommendationCard({
    required this.colors,
    required this.recommendation,
    required this.currentDurationSecs,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final recommended = recommendation.seconds;
    final differs = (recommended - currentDurationSecs).abs() > 0.5;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: SkotiqDecorations.iconChip(
        colors.primary,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        borderAlpha: 0.28,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.sparkles, size: 14, color: colors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Recommended exposure',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: differs ? onApply : null,
                icon: Icon(
                  LucideIcons.check,
                  size: 13,
                  color: differs ? colors.primary : colors.textMuted,
                ),
                label: Text(
                  'Apply ${'${QuantityFormat.trimmed(recommended)}s'}',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
                    color: differs ? colors.primary : colors.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${'${QuantityFormat.trimmed(recommended)}s'} · ${recommendation.limitingFactor.label}',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 12),
              color: colors.textSecondary,
            ),
          ),
          // Whole sentences: the inspector scrolls, and the reason is the
          // point of the card ("The sky alone wo…" said nothing).
          if (recommendation.rationale.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              recommendation.rationale,
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.textMuted,
              ),
            ),
          ],
          if (recommendation.caveats.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              recommendation.caveats.first,
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.warning,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Non-blocking amber notice shown under a duration/delay field whose value is
/// unusually large. The value is still accepted — this just asks the user to
/// confirm intent.
class _LongValueWarning extends StatelessWidget {
  final SkotiqColors colors;
  final String message;

  const _LongValueWarning({required this.colors, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(color: colors.warning.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.alertTriangle, size: 14, color: colors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: Responsive.fontSize(context, 11),
                  color: colors.warning,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

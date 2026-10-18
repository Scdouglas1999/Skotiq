// ignore_for_file: unused_element

part of '../polar_alignment_screen.dart';

extension _ConfigurationPanel on _PolarAlignmentScreenState {
  Widget _buildLeftPanel(
    SkotiqColors colors,
    PolarAlignmentState state,
    PolarAlignmentConfig config,
    bool isRunning,
  ) {
    final ui = ref.watch(polarAlignmentUiStateProvider);

    // The settings column is a side panel (05 §15): 'surface' toned, 16px
    // padding, sections separated by 16 and each opened by a SectionTitle.
    return Container(
      color: colors.surface,
      child: Column(
        children: [
          // Configuration section
          Expanded(
            child: SingleChildScrollView(
              controller: _configScrollController,
              padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Every setting below is refused while a run is in flight
                  // (each control passes a null callback), but nothing said so:
                  // the column kept its full contrast, so clicking "South" or
                  // "4x4" mid-run just appeared to do nothing.
                  if (isRunning) ...[
                    _buildSettingsLockedNote(colors),
                    const SizedBox(height: 12),
                  ],
                  if (state.phase == PolarAlignPhase.idle) ...[
                    _buildIdleGuide(colors),
                    const SizedBox(height: SkotiqTokens.spaceLg),
                  ],
                  // Essential settings - always visible
                  _buildSectionHeader(
                      colors, 'Essential', SkotiqIcons.settings),
                  const SizedBox(height: 12),
                  _dimWhileRunning(
                    isRunning,
                    _buildEssentialSettings(colors, config, isRunning),
                  ),

                  const SizedBox(height: 16),

                  // Common settings - collapsible
                  _dimWhileRunning(
                    isRunning,
                    _buildCommonSettings(colors, config, isRunning),
                  ),

                  const SizedBox(height: 8),

                  // Advanced settings - collapsible
                  _dimWhileRunning(
                    isRunning,
                    _buildAdvancedSettings(colors, config, isRunning),
                  ),

                  if (state.phase == PolarAlignPhase.adjusting) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(
                        colors, 'Adjustment tips', SkotiqIcons.idea),
                    const SizedBox(height: 12),
                    _buildAdjustmentTips(colors),
                  ],

                  // History panel (shown when toggled)
                  if (ui.showHistoryPanel) ...[
                    const SizedBox(height: 24),
                    KeyedSubtree(
                      key: _historyPanelKey,
                      child: _buildHistoryPanel(colors),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Dim the settings groups while a run holds them. The controls are already
  /// disabled; this is what makes that legible at a glance instead of only on
  /// the click that gets refused. Kept above the disabled threshold so the
  /// operator can still READ the hemisphere/binning the run is using.
  Widget _dimWhileRunning(bool isRunning, Widget child) {
    if (!isRunning) return child;
    return Opacity(opacity: SkotiqTokens.opacityMuted, child: child);
  }

  /// Why the settings below cannot be changed right now, and what to do about
  /// it. Carries the same lock semantics the mode selector and Back button in
  /// the header already have during a run.
  Widget _buildSettingsLockedNote(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: SkotiqDecorations.tintedBadge(
        colors.info,
        borderRadius: SkotiqTokens.borderRadiusInline8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(SkotiqIcons.lock, size: 14, color: colors.info),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Settings are locked while aligning — press Stop to change them.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.info,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The kit's section title (05 §15), not a hand-built icon + h6 row.
  Widget _buildSectionHeader(SkotiqColors colors, String title, IconData icon) {
    return SectionTitle(icon: icon, title: title);
  }

  Widget _buildEssentialSettings(
    SkotiqColors colors,
    PolarAlignmentConfig config,
    bool isRunning,
  ) {
    final configNotifier = ref.read(polarAlignmentConfigProvider.notifier);

    return Column(
      children: [
        // Hemisphere
        _SettingRow(
          label: 'Hemisphere',
          tooltip:
              'Northern or Southern hemisphere determines celestial pole position',
          colors: colors,
          child: PolarAlignmentSegmentedButton<bool>(
            buttonKey: PolarAlignmentTutorialKeys.hemisphere,
            segments: const [
              ButtonSegment(value: true, label: Text('North')),
              ButtonSegment(value: false, label: Text('South')),
            ],
            selected: {config.isNorth},
            onSelectionChanged:
                isRunning ? null : (v) => configNotifier.setIsNorth(v.first),
          ),
        ),
        const SizedBox(height: 12),

        // Exposure time
        _SettingRow(
          label: 'Exposure',
          tooltip:
              'Longer exposures capture more stars but slow down iterations',
          colors: colors,
          child: Row(
            key: PolarAlignmentTutorialKeys.exposure,
            children: [
              Expanded(
                child: Slider(
                  value: config.exposureTime,
                  min: 1,
                  max: 30,
                  divisions: 29,
                  onChanged: isRunning
                      ? null
                      : (v) => configNotifier.setExposureTime(v),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${config.exposureTime.toInt()}s',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCommonSettings(
    SkotiqColors colors,
    PolarAlignmentConfig config,
    bool isRunning,
  ) {
    final configNotifier = ref.read(polarAlignmentConfigProvider.notifier);
    final ui = ref.watch(polarAlignmentUiStateProvider);
    final uiNotifier = ref.read(polarAlignmentUiStateProvider.notifier);

    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          initiallyExpanded: ui.showCommonSettings,
          onExpansionChanged: uiNotifier.setShowCommonSettings,
          title: Row(
            children: [
              Icon(SkotiqIcons.sliders, size: 14, color: colors.textMuted),
              const SizedBox(width: 8),
              Text(
                'Common',
                style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          children: [
            // Binning
            _SettingRow(
              label: 'Binning',
              tooltip: 'Binning 2 solves in a quarter of the time; alignment '
                  'accuracy is unaffected.',
              colors: colors,
              child: PolarAlignmentSegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1x1')),
                  ButtonSegment(value: 2, label: Text('2x2')),
                  ButtonSegment(value: 4, label: Text('4x4')),
                ],
                selected: {config.binning},
                onSelectionChanged: isRunning
                    ? null
                    : (v) => configNotifier.setBinning(v.first),
              ),
            ),
            const SizedBox(height: 12),

            // Step size
            _SettingRow(
              label: 'Step size',
              tooltip:
                  'Distance between measurement points. Larger = more accurate but may hit mount limits',
              colors: colors,
              child: Row(
                key: PolarAlignmentTutorialKeys.stepSize,
                children: [
                  Expanded(
                    child: Slider(
                      value: config.stepSize,
                      min: 10,
                      max: 45,
                      divisions: 7,
                      onChanged: isRunning
                          ? null
                          : (v) => configNotifier.setStepSize(v),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${config.stepSize.toInt()}°',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Direction
            _SettingRow(
              label: 'Direction',
              tooltip:
                  'Which way to rotate for measurements. Use West if near Eastern meridian limit',
              colors: colors,
              child: PolarAlignmentSegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('East')),
                  ButtonSegment(value: false, label: Text('West')),
                ],
                selected: {config.rotateEast},
                onSelectionChanged: isRunning
                    ? null
                    : (v) => configNotifier.setRotateEast(v.first),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdvancedSettings(
    SkotiqColors colors,
    PolarAlignmentConfig config,
    bool isRunning,
  ) {
    final configNotifier = ref.read(polarAlignmentConfigProvider.notifier);
    final ui = ref.watch(polarAlignmentUiStateProvider);
    final uiNotifier = ref.read(polarAlignmentUiStateProvider.notifier);

    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          initiallyExpanded: ui.showAdvancedSettings,
          onExpansionChanged: uiNotifier.setShowAdvancedSettings,
          title: Row(
            children: [
              Icon(SkotiqIcons.settings2, size: 14, color: colors.textMuted),
              const SizedBox(width: 8),
              Text(
                'Advanced',
                style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          children: [
            // Manual rotation toggle
            _SettingRow(
              label: 'Manual rotation',
              tooltip: 'Enable for star trackers without GoTo capability',
              colors: colors,
              child: SkotiqSwitch(
                value: config.manualRotation,
                onChanged: isRunning
                    ? null
                    : (v) => configNotifier.setManualRotation(v),
              ),
            ),
            const SizedBox(height: 12),

            // Solve timeout
            _SettingRow(
              label: 'Solve timeout',
              tooltip: 'Budget for one frame: a solve hinted from the mount '
                  'position first, then a blind solve with whatever is left.',
              colors: colors,
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: config.solveTimeout,
                      min: 10,
                      max: 120,
                      divisions: 11,
                      onChanged: isRunning
                          ? null
                          : (v) => configNotifier.setSolveTimeout(v),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${config.solveTimeout.toInt()}s',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Start position
            _SettingRow(
              label: 'Start from',
              tooltip: 'Current: measure from where the scope points now. '
                  'Pole: slew to the pole region first (requires your site '
                  'location to be set).',
              colors: colors,
              child: PolarAlignmentSegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Current')),
                  ButtonSegment(value: false, label: Text('Pole')),
                ],
                selected: {config.startFromCurrent},
                onSelectionChanged: isRunning
                    ? null
                    : (v) => configNotifier.setStartFromCurrent(v.first),
              ),
            ),
            const SizedBox(height: 12),

            // Auto-complete threshold
            _SettingRow(
              label: 'Auto-Complete',
              tooltip:
                  'Automatically finish when error stays below this value for 3 seconds',
              colors: colors,
              child: Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: config.autoCompleteThreshold,
                      min: 10,
                      max: 120,
                      divisions: 11,
                      onChanged: isRunning
                          ? null
                          : (v) => configNotifier.setAutoCompleteThreshold(v),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${config.autoCompleteThreshold.toInt()}"',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

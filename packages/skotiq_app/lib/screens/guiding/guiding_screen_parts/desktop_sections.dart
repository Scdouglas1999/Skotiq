// Wide layout, shared panels and the guiding side panel.
part of '../guiding_screen.dart';

mixin _GuidingDesktopSections
    on ConsumerState<GuidingScreen>, _GuidingStateFields, _GuidingActions {
  /// Left column width (06 §Guiding: three columns 224 / 1fr / 300).
  static const double _leftColumnWidth = 224;

  /// Right side-panel width (06 §Guiding; 05 §15 side panel without a strip).
  static const double _sidePanelWidth = 300;

  /// Below this the three columns cannot each hold their content, so the
  /// screen reflows to the stacked tab layout rather than shrinking the graph
  /// to a sliver. It is the shell's own layout breakpoint so the page agrees
  /// with the chrome around it.
  static const double _threeColumnMinWidth =
      ShellChromeMetrics.shellLayoutBreakpoint;

  Widget _buildDesktopLayout(
    SkotiqColors colors,
    bool isConnected,
    Phd2State phd2State,
    Phd2GuideStats guideStats,
  ) {
    return Row(
      // The columns start at the same y: a Row centres its children by
      // default, which left the shorter left column floating 34 px below the
      // graph panel's top edge.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.space2xl,
            SkotiqTokens.spaceXl,
            0,
            SkotiqTokens.space2xl,
          ),
          child: SizedBox(
            width: _leftColumnWidth,
            child: _buildLeftColumn(colors, isConnected, guideStats),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.spaceLg,
              SkotiqTokens.spaceXl,
              SkotiqTokens.spaceLg,
              SkotiqTokens.space2xl,
            ),
            child: _buildGraphPanel(colors, guideStats),
          ),
        ),
        SidePanel(
          width: _sidePanelWidth,
          child: _buildSidePanelContent(colors, isConnected, phd2State),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- left ---

  Widget _buildLeftColumn(
    SkotiqColors colors,
    bool isConnected,
    Phd2GuideStats stats,
  ) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildGuideStarPanel(colors, isConnected, stats),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _buildTargetDisplayPanel(colors, stats),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _buildStarStatisticsPanel(colors, stats),
        ],
      ),
    );
  }

  /// The guide-star preview: a square [well] inside a panel (06 §Guiding).
  Widget _buildGuideStarPanel(
    SkotiqColors colors,
    bool isConnected,
    Phd2GuideStats stats,
  ) {
    final starImage = ref.watch(starImageProvider);

    return SkotiqPanel(
      head: PanelHead(
        label: 'Guide star',
        icon: SkotiqIcons.star,
        trailing: [
          if (isConnected)
            SkotiqIconButton(
              icon: SkotiqIcons.refresh,
              tooltip: 'Refresh the guide star image',
              size: IconButtonSize.sm,
              onPressed: () => ref.read(starImageProvider.notifier).refresh(),
            ),
        ],
      ),
      child: _well(
        colors,
        child: AspectRatio(
          aspectRatio: 1,
          child: starImage.when(
            data: (image) => GuideStarView(
              key: GuidingTutorialKeys.starView,
              pixels: image.pixels,
              width: image.width,
              height: image.height,
              starX: image.starX,
              starY: image.starY,
              snr: stats.snr,
              showCrosshairs: true,
              onStarSelected: isConnected ? _selectStar : null,
              statusMessage: 'No star selected',
            ),
            loading: () => GuideStarView(
              key: GuidingTutorialKeys.starView,
              statusMessage: _starViewIdleMessage(),
            ),
            error: (_, __) => GuideStarView(
              key: GuidingTutorialKeys.starView,
              statusMessage: 'Guide star image unavailable',
            ),
          ),
        ),
      ),
    );
  }

  /// The bullseye error history: a square [well] inside a panel.
  Widget _buildTargetDisplayPanel(
    SkotiqColors colors,
    Phd2GuideStats stats,
  ) {
    final errorHistory = ref.watch(targetDisplayHistoryProvider);
    final currentError = errorHistory.isNotEmpty ? errorHistory.last : null;

    return SkotiqPanel(
      head: const PanelHead(
        label: 'Target display',
        icon: SkotiqIcons.target,
      ),
      child: _well(
        colors,
        child: AspectRatio(
          aspectRatio: 1,
          child: GuideTargetDisplay(
            key: GuidingTutorialKeys.targetDisplay,
            errorHistory: errorHistory
                .map(
                  (e) => GuideErrorPoint(
                    raError: _errorForDisplay(e.raError, stats.pixelScale),
                    decError: _errorForDisplay(e.decError, stats.pixelScale),
                    timestamp: e.timestamp,
                  ),
                )
                .toList(),
            // Absent error coalesced to 0 put the marker exactly on the
            // bullseye while the guider was stopped with nothing measured,
            // which reads as perfect guiding rather than as no reading.
            showCurrentError: currentError != null,
            currentRaError:
                _errorForDisplay(currentError?.raError ?? 0, stats.pixelScale),
            currentDecError:
                _errorForDisplay(currentError?.decError ?? 0, stats.pixelScale),
            scaleArcsec: _yScale.arcsec / 2,
            unitSuffix: _errorUnit(stats.pixelScale),
            numRings: 3,
          ),
        ),
      ),
    );
  }

  /// Star statistics as a [ReadoutRow] (06 §Guiding). An unmeasured value is a
  /// null readout, which renders the em dash — never a fabricated 0.0.
  Widget _buildStarStatisticsPanel(
    SkotiqColors colors,
    Phd2GuideStats stats,
  ) {
    return SkotiqPanel(
      head: const PanelHead(
        label: 'Star statistics',
        icon: SkotiqIcons.activity,
      ),
      child: ReadoutRow(
        // 28 is the default gap for a full-width row; this column is 224 wide,
        // so the three readouts share the panel's own rhythm instead.
        gap: SkotiqTokens.spaceMd,
        children: [
          Readout(
            value: _starMetricValue(stats.snr),
            label: 'SNR',
            size: ReadoutSize.sm,
            valueColor: _getSnrColor(stats.snr, colors),
          ),
          Readout(
            value: _starMetricValue(stats.starMass, decimals: 0),
            label: 'Mass',
            size: ReadoutSize.sm,
          ),
          Readout(
            value: _frameCountText(stats, ref.watch(phd2StateProvider)),
            label: 'Frames',
            size: ReadoutSize.sm,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- centre ---

  /// The guide graph panel. [GuideGraphAdvanced] carries the options row
  /// (RA / Dec / Tot and the Time and Scale selectors) and its own inset plot
  /// surface, so the panel adds the label and the frame and nothing else — a
  /// second RMS row here would print the same three numbers twice.
  Widget _buildGraphPanel(SkotiqColors colors, Phd2GuideStats stats) {
    return LayoutBuilder(
      builder: (context, constraints) => _buildGraphPanelBody(
        colors,
        stats,
        // The head costs 32 dp of a pane a short viewport can cut to ~110, and
        // it is the least load-bearing thing here: the page is already titled
        // Guiding, the scale selectors stay, and the plot is what was come for.
        showHead: constraints.maxHeight >= _graphHeadMinPaneHeight,
        // Below this the graph's own options row plus the panel's inset no
        // longer both fit, and padding is what gives way, not the plot.
        compact: constraints.maxHeight < _graphCompactPaneHeight,
      ),
    );
  }

  /// Pane height below which the graph panel drops its own head.
  static const double _graphHeadMinPaneHeight = 220.0;

  /// Pane height below which the graph panel spends the least padding it can.
  static const double _graphCompactPaneHeight = 140.0;

  Widget _buildGraphPanelBody(
    SkotiqColors colors,
    Phd2GuideStats stats, {
    required bool showHead,
    required bool compact,
  }) {
    final graphData = ref.watch(guideGraphProvider);
    final hasRmsSamples = stats.frameCount > 0;

    final Widget graph = GuideGraphAdvanced(
      key: GuidingTutorialKeys.graph,
      data: graphData
          .map(
            (p) => GuideDataPoint(
              timestamp: p.time,
              raError: _errorForDisplay(p.ra, stats.pixelScale),
              decError: _errorForDisplay(p.dec, stats.pixelScale),
            ),
          )
          .toList(),
      valueUnit: _errorUnit(stats.pixelScale),
      timeScale: _timeScale,
      yScale: _yScale,
      // Values are converted here (and nulled out when nothing has been
      // measured) so the graph's own stats row cannot label raw pixels as
      // arcseconds or print a fabricated 0.00.
      rmsRa: hasRmsSamples
          ? _rmsReadout(stats.rmsRa, stats.pixelScale).value
          : null,
      rmsDec: hasRmsSamples
          ? _rmsReadout(stats.rmsDec, stats.pixelScale).value
          : null,
      rmsTotal: hasRmsSamples
          ? _rmsReadout(stats.rmsTotal, stats.pixelScale).value
          : null,
      rmsUnit: _rmsReadout(0, stats.pixelScale).unit,
      onTimeScaleChanged: (scale) => setState(() => _timeScale = scale),
      onYScaleChanged: (scale) => setState(() => _yScale = scale),
    );

    return SkotiqPanel(
      key: GuidingTutorialKeys.rmsDisplay,
      padding: showHead
          ? SkotiqTokens.paddingLg
          : (compact ? SkotiqTokens.paddingXs : SkotiqTokens.paddingMd),
      head: showHead
          ? const PanelHead(label: 'Guide graph', icon: SkotiqIcons.chart)
          : null,
      // With a head the panel body is a Column, so the graph claims the
      // remaining height as its flex child. Without one the panel IS the
      // graph's box and an Expanded would have no Flex to attach to.
      child: showHead ? Expanded(child: graph) : graph,
    );
  }

  // --------------------------------------------------------- side panel ---

  Widget _buildSidePanelContent(
    SkotiqColors colors,
    bool isConnected,
    Phd2State phd2State,
  ) {
    final guiderId = ref.watch(guiderStateProvider).deviceId;
    final isPhd2Guider = guiderId == null || isPhd2DeviceId(guiderId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 3, child: _buildControls(isConnected, phd2State)),
        const SizedBox(height: SidePanel.sectionGap),
        Expanded(
          flex: 2,
          child: isPhd2Guider
              ? _buildCalibrationSection(colors, isConnected, phd2State)
              : _buildNonPhd2GuiderInfo(colors),
        ),
        const SizedBox(height: SidePanel.sectionGap),
        SkotiqButton(
          key: GuidingTutorialKeys.brainBtn,
          label: isPhd2Guider
              ? (_showBrainPanel ? 'Hide brain settings' : 'Brain settings')
              : 'Guider settings',
          icon: isPhd2Guider ? SkotiqIcons.brain : SkotiqIcons.settings,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: isPhd2Guider
              ? () => setState(() => _showBrainPanel = !_showBrainPanel)
              : () => context.go('/equipment'),
        ),
        if (isPhd2Guider && _showBrainPanel) ...[
          const SizedBox(height: SidePanel.sectionGap),
          Expanded(flex: 3, child: _buildBrainPanel(colors)),
        ],
      ],
    );
  }

  Widget _buildControls(bool isConnected, Phd2State phd2State) {
    final guiderId = ref.watch(guiderStateProvider).deviceId;
    final isPhd2Guider = guiderId == null || isPhd2DeviceId(guiderId);
    final settingsAsync = ref.watch(appSettingsProvider);
    final canPersistGuidingSettings = settingsAsync.hasValue &&
        !settingsAsync.isLoading &&
        !settingsAsync.hasError;
    final controller = ref.read(phd2ControllerProvider);

    return GuideControlsPanel(
      key: GuidingTutorialKeys.controls,
      state: _mapPhd2State(phd2State),
      isConnected: isConnected,
      onStartGuiding: () => controller.startGuiding(
        settlePixels: _settlePixels,
        settleTime: _settleTime,
        settleTimeout: _settleTimeout,
      ),
      onStopGuiding: () => ref.read(phd2ControllerProvider).stopGuiding(),
      onPauseGuiding: isPhd2Guider
          ? () => ref.read(phd2ControllerProvider).pauseGuiding()
          : null,
      onResumeGuiding: isPhd2Guider
          ? () => ref.read(phd2ControllerProvider).resumeGuiding()
          : null,
      pauseUnavailableReason: isPhd2Guider ? null : kBuiltinGuiderNoPauseReason,
      onLoop: () => ref.read(phd2ControllerProvider).loop(),
      onFindStar: _autoSelectStar,
      onDeselectStar: _deselectStar,
      ditherAmount: _ditherAmount,
      ditherRaOnly: _ditherRaOnly,
      onDitherAmountChanged:
          canPersistGuidingSettings ? _setDitherAmount : null,
      onDitherRaOnlyChanged:
          canPersistGuidingSettings ? _setDitherRaOnly : null,
      onDither: () => ref.read(phd2ControllerProvider).dither(
            amount: _ditherAmount,
            raOnly: _ditherRaOnly,
            settlePixels: _settlePixels,
            settleTime: _settleTime,
            settleTimeout: _settleTimeout,
          ),
      settlePixels: _settlePixels,
      settleTime: _settleTime,
      settleTimeout: _settleTimeout,
      onSettlePixelsChanged:
          canPersistGuidingSettings ? _setSettlePixels : null,
      onSettleTimeChanged: canPersistGuidingSettings ? _setSettleTime : null,
      onSettleTimeoutChanged:
          canPersistGuidingSettings ? _setSettleTimeout : null,
    );
  }

  /// Calibration as a side-panel section (06 §Guiding). The uncalibrated state
  /// is ONE [SkotiqBanner], not a bordered hero with its own icon disc.
  Widget _buildCalibrationSection(
    SkotiqColors colors,
    bool isConnected,
    Phd2State phd2State,
  ) {
    final calibration = ref.watch(calibrationStateProvider);
    final isCalibrating = phd2State == Phd2State.calibrating;
    final isCalibrated = calibration.isCalibrated;

    // The whole section scrolls, title included: on a short phone this slot
    // can be squeezed below the height of its own title, and a pinned title
    // over an Expanded body overflows there.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionTitle(
            icon: SkotiqIcons.compass,
            title: 'Calibration',
            trailing: SkotiqChip(
              label: isCalibrating
                  ? 'Calibrating'
                  : (isCalibrated ? 'Calibrated' : 'Not calibrated'),
              tone: isCalibrating
                  ? ChipTone.primary
                  : (isCalibrated ? ChipTone.success : ChipTone.warning),
              dot: true,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCalibrating)
                const SkotiqBanner(
                  title: 'Calibrating the mount.',
                  message: 'PHD2 is measuring the guide rates.',
                  tone: BannerTone.info,
                )
              else if (!isCalibrated)
                const SkotiqBanner(
                  title: 'Mount not calibrated.',
                  message: 'PHD2 calibrates the mount the first time you '
                      'start guiding.',
                  tone: BannerTone.warning,
                )
              else ...[
                ReadoutRow(
                  gap: SkotiqTokens.spaceLg,
                  children: [
                    Readout(
                      value: _angleValue(calibration.rotationAngle),
                      unit: '°',
                      label: 'RA angle',
                      size: ReadoutSize.sm,
                    ),
                    Readout(
                      value: _rateValue(calibration.raRate),
                      unit: 'px/s',
                      label: 'RA rate',
                      size: ReadoutSize.sm,
                    ),
                    Readout(
                      value: _rateValue(calibration.decRate),
                      unit: 'px/s',
                      label: 'Dec rate',
                      size: ReadoutSize.sm,
                    ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                Row(
                  children: [
                    Expanded(
                      child: SkotiqButton(
                        label: 'Clear',
                        icon: SkotiqIcons.delete,
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        onPressed: isConnected ? _clearCalibration : null,
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Expanded(
                      child: SkotiqButton(
                        label: 'Flip',
                        icon: LucideIcons.flipHorizontal,
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        onPressed: isConnected ? _flipCalibration : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'Flip the calibration after a meridian flip.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// The guider in use is not PHD2, so PHD2's calibration and Brain controls do
  /// not exist for it. One empty state, one button (05 §12).
  Widget _buildNonPhd2GuiderInfo(SkotiqColors colors) {
    final isBuiltin = ref.watch(isBuiltinGuiderProvider);
    return SingleChildScrollView(
      child: EmptyState.compact(
        icon: isBuiltin ? SkotiqIcons.guider : SkotiqIcons.settings,
        title: isBuiltin ? 'Built-in guider' : 'External guider',
        body: isBuiltin
            ? 'Skotiq calibrates this guider itself. Pulse and multi-star '
                'settings live under Equipment.'
            : 'This guider exposes no PHD2 calibration or Brain controls. '
                'Configure it from Equipment.',
        action: SkotiqButton(
          label: 'Open equipment',
          icon: SkotiqIcons.settings,
          size: ButtonSize.small,
          variant: ButtonVariant.secondary,
          onPressed: () => context.go('/equipment'),
        ),
      ),
    );
  }

  Widget _buildBrainPanel(SkotiqColors colors) {
    final brainParams = ref.watch(brainParamsProvider);
    final guiderState = ref.watch(guiderStateProvider);

    // BrainParamsNotifier only ever calls fetch() while PHD2 itself is
    // connected (brain_and_calibration.dart: connected && deviceId ==
    // kPhd2CanonicalId), and it resets to `loading` on every disconnect. So
    // outside that window `loading` does NOT mean "values are on the way" — it
    // means no request will ever be made. Rendering the shimmer there left six
    // grey rows pulsing indefinitely with no values, no message and no error,
    // and the panel's real error branch (with its Retry button) is unreachable
    // because nothing ever throws. Say what is actually true instead.
    final canFetchBrainParams =
        guiderState.connectionState == DeviceConnectionState.connected &&
            guiderState.deviceId == kPhd2CanonicalId;

    return brainParams.when(
      data: (params) => BrainSettingsPanel(
        isEditing: true,
        raParams: params.raParams.entries
            .map((e) => BrainParam(name: e.key, value: e.value))
            .toList(),
        decParams: params.decParams.entries
            .map((e) => BrainParam(name: e.key, value: e.value))
            .toList(),
        onParamChanged: (axis, name, value) =>
            ref.read(brainParamsProvider.notifier).setParam(axis, name, value),
        onReset: () => ref.read(brainParamsProvider.notifier).fetch(),
      ),
      // Shimmer placeholders match the brain-params field rows so the panel
      // doesn't visibly resize when PHD2 returns its parameter dump — but only
      // while a dump can actually arrive.
      loading: () => canFetchBrainParams
          // Scrollable: the six rows plus padding need more than this flex-3
          // slot gets on a 900 px-tall window, and the placeholder overflowed
          // the column by 47 px there.
          ? SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  _brainShimmerRows,
                  (_) => Padding(
                    padding: const EdgeInsets.only(
                      bottom: SkotiqTokens.spaceMd,
                    ),
                    child: ShimmerLoading(
                      child: Container(
                        height: _brainShimmerRowHeight,
                        decoration: SkotiqDecorations.well(colors),
                      ),
                    ),
                  ),
                ),
              ),
            )
          : _buildBrainUnavailable(colors),
      error: (e, _) => SingleChildScrollView(
        child: EmptyState.compact(
          icon: SkotiqIcons.warning,
          title: 'Brain settings did not load',
          // Surface the real error so the user can act on it instead of
          // staring at a generic "failed" message (silent fallbacks hide
          // bugs). Common cause: PHD2 connected but no equipment profile.
          body: _brainErrorMessage(e),
          action: SkotiqButton(
            label: 'Retry',
            icon: SkotiqIcons.refresh,
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: () => ref.read(brainParamsProvider.notifier).fetch(),
          ),
        ),
      ),
    );
  }

  /// Shown in place of the shimmer when no brain-params fetch can run: PHD2
  /// holds these values, so with PHD2 down there is nothing to load and
  /// nothing to retry until it is connected.
  Widget _buildBrainUnavailable(SkotiqColors colors) {
    return const SingleChildScrollView(
      child: EmptyState.compact(
        icon: SkotiqIcons.brain,
        title: 'Brain settings need PHD2',
        body: "These are PHD2's own guiding parameters. Connect PHD2 to read "
            'and edit them.',
      ),
    );
  }

  /// A [well]-toned inset: the deepest nesting the sheet allows (02 rule 2).
  Widget _well(SkotiqColors colors, {required Widget child}) {
    return Container(
      decoration: SkotiqDecorations.well(colors),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  /// Rows of shimmer standing in for the brain-parameter fields.
  static const int _brainShimmerRows = 6;

  /// Height of one shimmer row: the sheet's control height (03 §3.3), so the
  /// panel does not resize when the real fields arrive.
  static const double _brainShimmerRowHeight = 32;
}

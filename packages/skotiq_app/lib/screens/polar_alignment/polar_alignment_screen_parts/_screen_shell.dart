// ignore_for_file: unused_element

part of '../polar_alignment_screen.dart';

extension _ScreenShell on _PolarAlignmentScreenState {
  /// The page header: identity, the method tabs, the device chips and the
  /// ONE primary, on one row.
  ///
  /// The method switch and the device chips used to sit on a second 60px row
  /// under the header, leaving the header itself mostly empty. Every other
  /// screen with tabs (Imaging, Equipment, Analytics) carries them in the
  /// header's tab slot, so this one does too; the chips are status, so they
  /// lead the actions. Below the shell breakpoint [PageHeader] moves the tabs
  /// to their own row, and the chips follow them into [PageHeader.bottom]
  /// because a phone header has no width for them beside the primary.
  Widget _buildHeader(SkotiqColors colors, bool isRunning) {
    return LayoutBuilder(
      builder: (context, constraints) => _buildHeaderFor(
        colors,
        isRunning,
        roomy:
            constraints.maxWidth >= _PolarAlignmentScreenState.headerRoomyWidth,
      ),
    );
  }

  /// [roomy] is whether the header row has the width for the device chips
  /// and the labelled Back and History beside the title, the tabs and the
  /// primary. Without it the chips drop to a strip under the header and Back
  /// and History shed their labels, rather than the row overflowing.
  Widget _buildHeaderFor(
    SkotiqColors colors,
    bool isRunning, {
    required bool roomy,
  }) {
    final ui = ref.watch(polarAlignmentUiStateProvider);
    final uiNotifier = ref.read(polarAlignmentUiStateProvider.notifier);

    final modeTabs = AdaptiveTabBar(
      horizontalPadding: 0,
      // Two short labels. The bar collapses to bare icons below 480px of
      // strip, which the actions beside it leave on most desktop widths, and
      // a compass and a globe do not say "TPPA" and "All-sky".
      collapseLabelsWhenTight: false,
      tabs: const <AdaptiveTab>[
        AdaptiveTab(label: 'TPPA', icon: SkotiqIcons.compass),
        AdaptiveTab(label: 'All-sky', icon: SkotiqIcons.globe),
      ],
      selectedIndex: ui.mode == PolarAlignmentMode.threePoint ? 0 : 1,
      // A run owns its method; switching mid-run is refused, not queued.
      onSelected: (index) {
        if (isRunning) return;
        uiNotifier.setMode(
          index == 0
              ? PolarAlignmentMode.threePoint
              : PolarAlignmentMode.allSky,
        );
      },
    );

    final narrow = MediaQuery.sizeOf(context).width <
        ShellChromeMetrics.shellLayoutBreakpoint;

    void toggleHistory() => uiNotifier.toggleHistoryPanel();
    final historyTooltip = ui.showHistoryPanel
        ? 'Hide past alignment runs'
        : 'Show past alignment runs';

    void leave() {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/imaging');
      }
    }

    return PageHeader(
      // No leading glyph on a phone: PageHeader's icon is inflexible, so at
      // 360px it kept 28px the title block had already given away and pushed
      // the header over by 11px.
      icon: narrow ? null : SkotiqIcons.compass,
      title: 'Polar alignment',
      // Roomy: the tabs ride in the header row. A phone: PageHeader moves
      // them to a row of their own. Between the two the header row has no
      // width left for a strip once the title and the actions are placed, so
      // the tabs share the chips' strip under it.
      tabs: roomy || narrow ? modeTabs : null,
      bottom: roomy
          ? null
          : Container(
              color: colors.background,
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.space2xl,
                vertical: SkotiqTokens.spaceSm,
              ),
              alignment: Alignment.centerLeft,
              child: narrow
                  ? _buildEquipmentIndicators(colors)
                  : Row(
                      children: [
                        Expanded(child: modeTabs),
                        const SizedBox(width: SkotiqTokens.spaceMd),
                        _buildEquipmentIndicators(colors),
                      ],
                    ),
            ),
      actions: <Widget>[
        if (roomy) _buildEquipmentIndicators(colors),
        // The way back, as a labelled header action — the shape the Darkroom
        // editor and the mosaic screens use. A bare arrow between the title
        // and History read as a stray glyph. While a run is in flight the way
        // back is refused anyway, and on a phone a disabled control is width
        // the Stop button needs.
        if (!roomy && !(narrow && isRunning))
          SkotiqIconButton(
            icon: SkotiqIcons.arrowLeft,
            tooltip: isRunning ? 'Stop alignment first' : 'Back',
            onPressed: isRunning ? null : leave,
          )
        else if (roomy)
          Tooltip(
            message: isRunning ? 'Stop alignment first' : 'Back',
            child: SkotiqButton(
              label: 'Back',
              icon: SkotiqIcons.arrowLeft,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: isRunning ? null : leave,
            ),
          ),
        if (!roomy)
          SkotiqIconButton(
            icon: SkotiqIcons.history,
            tooltip: historyTooltip,
            selected: ui.showHistoryPanel,
            onPressed: toggleHistory,
          )
        else
          Tooltip(
            message: historyTooltip,
            child: SkotiqButton(
              label: 'History',
              icon: SkotiqIcons.history,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: toggleHistory,
            ),
          ),
        ..._headerPrimary(),
      ],
    );
  }

  /// The camera and mount readiness chips.
  ///
  /// They were solid `error`-toned pills whenever a device was disconnected —
  /// two red alarms on a screen whose whole point is that you have not started
  /// yet. Tone follows connection state: success when connected, neutral when
  /// not, because "not connected yet" is a state, not a fault.
  Widget _buildEquipmentIndicators(SkotiqColors colors) {
    final cameraState = ref.watch(cameraStateProvider);
    final mountState = ref.watch(mountStateProvider);
    final cameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final mountConnected =
        mountState.connectionState == DeviceConnectionState.connected;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqChip(
          label: 'Camera',
          icon: SkotiqIcons.camera,
          tone: cameraConnected ? ChipTone.success : ChipTone.neutral,
          dot: true,
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        SkotiqChip(
          label: 'Mount',
          icon: SkotiqIcons.move,
          tone: mountConnected ? ChipTone.success : ChipTone.neutral,
          dot: true,
        ),
      ],
    );
  }

  /// Every unmet prerequisite for starting a run, in reading order.
  ///
  /// Shared by the header's primary (which shows them as its disabled
  /// tooltip) and the idle centre banner (which states them where an operator
  /// who clicked a dead button is already looking). One computation, so the
  /// two can never disagree.
  List<String> _startBlockers() {
    final cameraConnected = ref.watch(cameraStateProvider
        .select((s) => s.connectionState == DeviceConnectionState.connected));
    final mountConnected = ref.watch(mountStateProvider
        .select((s) => s.connectionState == DeviceConnectionState.connected));
    // A parked mount cannot slew between the three points and is not pointing
    // at sky, so the run is refused before it starts. Letting it run returns
    // "Plate solve timed out" — a solver error for a mount the app knew was
    // parked before the click.
    final mountParked = mountConnected &&
        ref.watch(mountStateProvider.select((s) => s.isParked));
    final detectionAsync = ref.watch(plateSolverDetectionProvider);
    final preferenceAsync = ref.watch(plateSolverPreferenceProvider);
    final solverReady = detectionAsync.valueOrNull != null &&
        preferenceAsync.valueOrNull != null &&
        detectionAsync.valueOrNull!
            .supports(preferenceAsync.valueOrNull!.choice);
    final readinessResolved = !detectionAsync.isLoading &&
        !preferenceAsync.isLoading &&
        !detectionAsync.hasError &&
        !preferenceAsync.hasError;
    // The site is a prerequisite in exactly the same sense as the camera, the
    // mount and the solver: the az/alt decomposition of a polar-axis error is
    // a function of latitude, and the app installs a (0, 0) observer at
    // startup, so without this the wizard measures for an observer on the
    // equator. `_startAlignment` refuses too, but a disabled button with a
    // reason is the shape every other prerequisite already uses here.
    final settingsResolved = ref.watch(appSettingsProvider).hasValue;
    final siteReady =
        settingsResolved && ref.watch(appObserverLocationProvider) != null;

    return <String>[
      if (!cameraConnected && !mountConnected)
        'Camera and mount not connected'
      else if (!cameraConnected)
        'Camera not connected'
      else if (!mountConnected)
        'Mount not connected'
      else if (mountParked)
        'Mount is parked — unpark it before aligning',
      if (!siteReady)
        settingsResolved
            ? 'No observing location set'
            : 'Checking observing location…',
      if (!readinessResolved)
        detectionAsync.hasError || preferenceAsync.hasError
            ? 'Could not check plate solver configuration'
            : 'Checking plate solver configuration…'
      else if (!solverReady)
        'Selected plate solver is not ready',
    ];
  }

  /// The header's phase action(s) — the screen's ONE primary.
  ///
  /// These lived in a 16px footer bar at the bottom of the screen, beside a
  /// status line that repeated every unmet prerequisite in warning colour.
  /// 02 rule 4 puts a page's single primary in its header, and the blocker
  /// travels with the button it blocks, as its tooltip.
  List<Widget> _headerPrimary() {
    final state = ref.watch(polarAlignmentStateProvider);
    final isRunning = state.isRunning;
    final blockers = _startBlockers();
    final String? disabledReason =
        blockers.isEmpty ? null : blockers.join(' · ');
    final canStart = blockers.isEmpty;

    /// Stopping a run means waiting for the exposure or plate solve in flight
    /// to reach a checkpoint. The button says so for those seconds instead of
    /// standing unchanged, which reads as a click that never landed.
    Widget stopButton() => SkotiqButton(
          label: _stopping ? 'Stopping…' : 'Stop',
          icon: SkotiqIcons.stop,
          variant: ButtonVariant.destructive,
          size: ButtonSize.small,
          onPressed: _stopping ? null : _stopAlignment,
        );

    Widget doneButton({required VoidCallback? onPressed, String? tooltip}) {
      final button = SkotiqButton(
        label: 'Done',
        icon: SkotiqIcons.check,
        size: ButtonSize.small,
        onPressed: onPressed,
      );
      return tooltip == null
          ? button
          : Tooltip(message: tooltip, child: button);
    }

    switch (state.phase) {
      case PolarAlignPhase.idle:
        return <Widget>[
          Tooltip(
            // The blocker sentence rides on the control it blocks. It used to
            // be a warning line in the footer as well — one problem, two
            // surfaces (02 rule 5).
            message: disabledReason ?? 'Start polar alignment',
            child: SkotiqButton(
              key: PolarAlignmentTutorialKeys.startBtn,
              // Just "Start" on a phone: the header already says what is
              // being started.
              label: MediaQuery.sizeOf(context).width <
                      ShellChromeMetrics.shellLayoutBreakpoint
                  ? 'Start'
                  : 'Start alignment',
              icon: SkotiqIcons.play,
              size: ButtonSize.small,
              onPressed: canStart && !isRunning ? _startAlignment : null,
            ),
          ),
        ];
      case PolarAlignPhase.measuring:
        return <Widget>[stopButton()];
      case PolarAlignPhase.adjusting:
        final hasMeasurement =
            state.initialError != null && state.currentError != null;
        return <Widget>[
          stopButton(),
          doneButton(
            onPressed: hasMeasurement ? _completeAlignment : null,
            tooltip: hasMeasurement
                ? 'Stop and save this alignment'
                : 'Waiting for the first alignment measurement',
          ),
        ];
      case PolarAlignPhase.complete:
      case PolarAlignPhase.error:
        return <Widget>[
          SkotiqButton(
            label: 'Restart',
            icon: SkotiqIcons.undo,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: _resetAlignment,
          ),
          doneButton(
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/imaging');
              }
            },
          ),
        ];
    }
  }
}

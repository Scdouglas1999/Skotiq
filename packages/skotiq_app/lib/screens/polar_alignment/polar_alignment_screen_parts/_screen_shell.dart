// ignore_for_file: unused_element

part of '../polar_alignment_screen.dart';

extension _ScreenShell on _PolarAlignmentScreenState {
  /// The page header: identity, the method switch, and the ONE primary.
  ///
  /// This was a bespoke `surface` bar carrying an h4 title with a subtitle
  /// under it, a Material `SegmentedButton` and two red device chips, and the
  /// primary action lived in a footer at the other end of the screen with the
  /// blocker sentence beside it. 04 §4 gives the screen one 56px header, and
  /// 02 rule 4 puts its single primary in that header.
  Widget _buildHeader(SkotiqColors colors, bool isRunning) {
    final ui = ref.watch(polarAlignmentUiStateProvider);
    final uiNotifier = ref.read(polarAlignmentUiStateProvider.notifier);

    final modeSelector = SegmentedControl(
      segments: const ['TPPA', 'All-sky'],
      selectedIndex: ui.mode == PolarAlignmentMode.threePoint ? 0 : 1,
      onSelected: isRunning
          ? (_) {}
          : (index) => uiNotifier.setMode(
                index == 0
                    ? PolarAlignmentMode.threePoint
                    : PolarAlignmentMode.allSky,
              ),
    );

    // The header row has to hold the title, the way back, History and the
    // primary. On a phone that is more than 360px of controls, so History
    // sheds its label — the tooltip still names it.
    final narrow = MediaQuery.sizeOf(context).width <
        ShellChromeMetrics.shellLayoutBreakpoint;

    void toggleHistory() => uiNotifier.toggleHistoryPanel();
    final historyTooltip = ui.showHistoryPanel
        ? 'Hide past alignment runs'
        : 'Show past alignment runs';

    return PageHeader(
      // No leading glyph on a phone: PageHeader's icon is inflexible, so at
      // 360px it kept 28px the title block had already given away and pushed
      // the header over by 11px.
      icon: narrow ? null : SkotiqIcons.compass,
      title: 'Polar alignment',
      // The method, as the header's context line — not a subtitle sentence
      // under the title (02 rule 5). Dropped on a phone, where the header row
      // has no room for it and the segmented control directly below already
      // names the method.
      context: narrow ? null : ui.mode.displayName,
      bottom: Container(
        color: colors.background,
        padding: const EdgeInsets.fromLTRB(
          SkotiqTokens.space2xl,
          SkotiqTokens.spaceMd,
          SkotiqTokens.space2xl,
          SkotiqTokens.spaceMd,
        ),
        // A Wrap, not a Row with a Spacer: at 360px the method switch and the
        // two device chips do not fit on one line, and a Row overflowed by
        // 109px rather than breaking.
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: SkotiqTokens.spaceMd,
          runSpacing: SkotiqTokens.spaceSm,
          children: [
            modeSelector,
            _buildEquipmentIndicators(colors),
          ],
        ),
      ),
      actions: <Widget>[
        // While a run is in flight the way back is refused anyway, and on a
        // phone a disabled arrow is 40px the Stop button needs.
        if (!(isRunning && narrow))
          SkotiqIconButton(
            icon: SkotiqIcons.arrowLeft,
            tooltip: isRunning ? 'Stop alignment first' : 'Back',
            onPressed: isRunning
                ? null
                : () {
                    if (context.canPop()) {
                      context.pop();
                    } else {
                      context.go('/imaging');
                    }
                  },
          ),
        if (narrow)
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

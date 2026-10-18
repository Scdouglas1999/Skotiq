// ignore_for_file: unused_element

part of '../polar_alignment_screen.dart';

extension _CenterPanel on _PolarAlignmentScreenState {
  /// The idle guide: any unmet prerequisite, then the setup checklist.
  ///
  /// It heads the settings column rather than filling a centre column of its
  /// own. As a centre column it was a 560px card floating over an empty band,
  /// beside a settings column that was empty below its three groups, and its
  /// "set the options on the left" step pointed across the screen at them.
  Widget _buildIdleGuide(SkotiqColors colors) {
    final detectionAsync = ref.watch(plateSolverDetectionProvider);
    final preferenceAsync = ref.watch(plateSolverPreferenceProvider);
    final showSolverBanner = detectionAsync.valueOrNull != null &&
        preferenceAsync.valueOrNull != null &&
        !detectionAsync.valueOrNull!
            .supports(preferenceAsync.valueOrNull!.choice);

    // The az/alt decomposition of a polar-axis error is a function of site
    // latitude, and with no site set the observer falls back to 0°N 0°E — the
    // corrections would be for an observer on the equator. Disclose it on the
    // idle screen alongside the solver prerequisite; _startAlignment refuses
    // outright.
    final settingsLoaded = ref.watch(appSettingsProvider).hasValue;
    final showSiteBanner =
        settingsLoaded && ref.watch(appObserverLocationProvider) == null;

    // One banner per problem (05 §11): the solver and the site already have
    // theirs, so the shared blocker banner carries only what is left.
    final otherBlockers = _startBlockers()
        .where((b) =>
            !b.contains('plate solver') && !b.contains('observing location'))
        .toList();

    const bannerGap = SizedBox(height: SkotiqTokens.spaceSm);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ONE banner, the kit's (05 §11). It was a bespoke warning card with
        // its own heading, paragraph and a filled button — three surfaces
        // for one problem.
        if (showSolverBanner) ...[
          SkotiqBanner(
            tone: BannerTone.warning,
            title: 'Plate solver not configured.',
            message: 'Polar alignment plate-solves each capture to '
                'measure mount error.',
            action: SkotiqButton(
              label: 'Set up plate solver',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => context.push('/settings/plate-solving'),
            ),
          ),
          bannerGap,
        ],
        // A disabled Start explains itself on HOVER, which is no explanation
        // to the operator who clicked it. The blockers that have no banner of
        // their own are stated here, where they are already looking.
        if (otherBlockers.isNotEmpty) ...[
          SkotiqBanner(
            key: startBlockedNoticeKey,
            tone: BannerTone.warning,
            title: 'Cannot start yet.',
            message: otherBlockers.join(' · '),
          ),
          bannerGap,
        ],
        if (showSiteBanner) ...[
          SkotiqBanner(
            tone: BannerTone.warning,
            title: 'No observing location set.',
            message: 'Polar error is measured relative to your site latitude.',
            action: SkotiqButton(
              label: 'Set a location',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => context.push('/settings/location'),
            ),
          ),
          bannerGap,
        ],
        _buildSetupInstructions(colors),
      ],
    );
  }

  /// The run view: the progress rail over whatever the phase shows. Only
  /// built once a run has left idle — see [_buildIdleGuide].
  Widget _buildCenterPanel(
    SkotiqColors colors,
    PolarAlignmentState state,
    PolarAlignmentConfig config,
  ) {
    final live = state.phase == PolarAlignPhase.measuring ||
        state.phase == PolarAlignPhase.adjusting;

    return Container(
      color: colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (live) _buildProgressSteps(colors, state),
          Expanded(
            // The live phases fill the column: the frame takes the width and
            // height left over, and their own layout scrolls only when it
            // has to stack on a narrow column. Wrapping them in a scroll view
            // as well handed them unbounded height, so they always stacked —
            // a 560px frame and its card below it, scrolled, with empty bands
            // either side on a 1080p screen.
            child: switch (state.phase) {
              PolarAlignPhase.measuring => _buildMeasuringStatus(colors, state),
              PolarAlignPhase.adjusting =>
                _buildAdjustmentInstructions(colors, state, config),
              PolarAlignPhase.complete =>
                _cappedScroll(_buildCompleteStatus(colors, state)),
              _ => _cappedScroll(_buildErrorStatus(colors, state)),
            },
          ),
        ],
      ),
    );
  }

  /// A scrolling, width-capped column for the terminal summaries, so their
  /// copy never runs the full width of a wide centre column nor wraps one
  /// word per line in a narrow one.
  Widget _cappedScroll(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceLg),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 2 * SkotiqTokens.spaceLg)
                  .clamp(0.0, double.infinity),
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth:
                      constraints.maxWidth < 480 ? constraints.maxWidth : 560,
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildProgressSteps(SkotiqColors colors, PolarAlignmentState state) {
    final point = state.currentPoint;
    final phase = state.phase;

    return Container(
      key: PolarAlignmentTutorialKeys.progress,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      // Horizontally scrollable so the four-step rail never overflows on a
      // narrow phone; it stays centered when there's room. The minimum width
      // is the COLUMN's, not the window's: sized to the window, the rail was
      // centred on a point off the column's right edge and its last step,
      // Adjust, was cut off.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ProgressStep(
                  colors: colors,
                  number: 1,
                  label: 'Capture 1',
                  isActive: phase == PolarAlignPhase.measuring && point == 1,
                  isComplete: point > 1 || phase == PolarAlignPhase.adjusting,
                ),
                _ProgressConnector(colors: colors, isComplete: point > 1),
                _ProgressStep(
                  colors: colors,
                  number: 2,
                  label: 'Capture 2',
                  isActive: phase == PolarAlignPhase.measuring && point == 2,
                  isComplete: point > 2 || phase == PolarAlignPhase.adjusting,
                ),
                _ProgressConnector(colors: colors, isComplete: point > 2),
                _ProgressStep(
                  colors: colors,
                  number: 3,
                  label: 'Capture 3',
                  isActive: phase == PolarAlignPhase.measuring && point == 3,
                  isComplete: phase == PolarAlignPhase.adjusting,
                ),
                _ProgressConnector(
                    colors: colors,
                    isComplete: phase == PolarAlignPhase.adjusting),
                _ProgressStep(
                  colors: colors,
                  number: 4,
                  label: 'Adjust',
                  isActive: phase == PolarAlignPhase.adjusting,
                  isComplete: phase == PolarAlignPhase.complete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What this method does, and the four things the operator has to do
  /// before starting — at the head of the settings column.
  ///
  /// The steps the app can check are marked done when they are: a "Connect
  /// the camera and the mount" step still open beside two green chips told
  /// the operator to do something already done. The pointing steps cannot be
  /// verified from here, so they stay open rather than claim otherwise.
  Widget _buildSetupInstructions(SkotiqColors colors) {
    final isAllSky = ref.watch(polarAlignmentUiStateProvider).mode ==
        PolarAlignmentMode.allSky;
    final cameraConnected = ref.watch(cameraStateProvider
        .select((s) => s.connectionState == DeviceConnectionState.connected));
    final mountConnected = ref.watch(mountStateProvider
        .select((s) => s.connectionState == DeviceConnectionState.connected));
    final connected = cameraConnected && mountConnected;
    final connectStep = ChecklistStep(
      title: 'Connect the camera and the mount',
      state: connected ? ChecklistStepState.done : ChecklistStepState.todo,
    );

    final steps = isAllSky
        ? <ChecklistStep>[
            const ChecklistStep(
              title: 'Point at any bright star field',
              detail: 'It does not have to be near the pole.',
            ),
            connectStep,
            const ChecklistStep(title: 'Set the exposure below, then start'),
            const ChecklistStep(
              title: 'Follow the live reticle while you adjust',
              detail: 'Azimuth and altitude error, live.',
            ),
          ]
        : <ChecklistStep>[
            const ChecklistStep(
              title: 'Roughly align the mount to the pole',
              detail: 'Within a few degrees is enough.',
            ),
            const ChecklistStep(
              title: 'Point the telescope near the celestial pole',
            ),
            connectStep,
            const ChecklistStep(
              title: 'Set the options below, then start',
              detail: 'The bullseye then tracks the error while you adjust.',
            ),
          ];

    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionTitle(
            icon: isAllSky ? SkotiqIcons.globe : SkotiqIcons.compass,
            title: isAllSky
                ? 'All-sky polar alignment'
                : 'Three-point polar alignment',
          ),
          Text(
            isAllSky
                ? 'Align from any part of the sky. Skotiq plate-solves '
                    'a live frame and shows the azimuth and altitude error '
                    'while you adjust the mount.'
                : 'Skotiq captures three images at different positions, '
                    'plate-solves each one, and works out how far the '
                    "mount's polar axis is from the pole.",
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Checklist(steps: steps),
        ],
      ),
    );
  }
}

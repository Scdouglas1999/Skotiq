// ignore_for_file: unused_element

part of '../polar_alignment_screen.dart';

extension _CenterPanel on _PolarAlignmentScreenState {
  Widget _buildCenterPanel(
    SkotiqColors colors,
    PolarAlignmentState state,
    PolarAlignmentConfig config,
  ) {
    final detectionAsync = ref.watch(plateSolverDetectionProvider);
    final preferenceAsync = ref.watch(plateSolverPreferenceProvider);
    final showSolverBanner = state.phase == PolarAlignPhase.idle &&
        detectionAsync.valueOrNull != null &&
        preferenceAsync.valueOrNull != null &&
        !detectionAsync.valueOrNull!
            .supports(preferenceAsync.valueOrNull!.choice);

    // The az/alt decomposition of a polar-axis error is a function of site
    // latitude, and with no site set the observer falls back to 0°N 0°E — the
    // corrections would be for an observer on the equator. Disclose it on the
    // idle screen alongside the solver prerequisite; _startAlignment refuses
    // outright.
    final settingsLoaded = ref.watch(appSettingsProvider).hasValue;
    final showSiteBanner = state.phase == PolarAlignPhase.idle &&
        settingsLoaded &&
        ref.watch(appObserverLocationProvider) == null;

    // One banner per problem (05 §11): the solver and the site already have
    // theirs, so the shared blocker banner carries only what is left.
    final otherBlockers = state.phase == PolarAlignPhase.idle
        ? _startBlockers()
            .where((b) =>
                !b.contains('plate solver') &&
                !b.contains('observing location'))
            .toList()
        : const <String>[];

    return Container(
      color: colors.background,
      child: Column(
        children: [
          // Progress indicator
          if (state.phase == PolarAlignPhase.measuring ||
              state.phase == PolarAlignPhase.adjusting)
            _buildProgressSteps(colors, state),

          // ONE banner, the kit's (05 §11). It was a bespoke warning card with
          // its own heading, paragraph and a filled button — three surfaces
          // for one problem.
          if (showSolverBanner)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.spaceLg,
                SkotiqTokens.spaceLg,
                SkotiqTokens.spaceLg,
                0,
              ),
              child: SkotiqBanner(
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
            ),

          // Main content area — scroll + width cap so idle copy never wraps
          // one character per line in a narrow center column.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth < 480
                              ? constraints.maxWidth
                              : 560,
                          minWidth: constraints.maxWidth < 400
                              ? constraints.maxWidth
                              : 400,
                        ),
                        // The site warning rides INSIDE the scroll area: the
                        // outer Column has no slack left once the solver banner
                        // is up, and a second fixed-height child overflows an
                        // 800x600 window.
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // A disabled Start explains itself on HOVER,
                            // which is no explanation to the operator who
                            // clicked it. The blockers that have no banner of
                            // their own are stated here, where they are
                            // already looking.
                            if (otherBlockers.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  SkotiqTokens.spaceLg,
                                  0,
                                  SkotiqTokens.spaceLg,
                                  SkotiqTokens.spaceSm,
                                ),
                                child: SkotiqBanner(
                                  key: startBlockedNoticeKey,
                                  tone: BannerTone.warning,
                                  title: 'Cannot start yet.',
                                  message: otherBlockers.join(' · '),
                                ),
                              ),
                            if (showSiteBanner)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  SkotiqTokens.spaceLg,
                                  0,
                                  SkotiqTokens.spaceLg,
                                  SkotiqTokens.spaceSm,
                                ),
                                child: SkotiqBanner(
                                  tone: BannerTone.warning,
                                  title: 'No observing location set.',
                                  message: 'Polar error is measured relative '
                                      'to your site latitude.',
                                  action: SkotiqButton(
                                    label: 'Set a location',
                                    variant: ButtonVariant.secondary,
                                    size: ButtonSize.small,
                                    onPressed: () =>
                                        context.push('/settings/location'),
                                  ),
                                ),
                              ),
                            state.phase == PolarAlignPhase.idle
                                ? _buildSetupInstructions(colors)
                                : state.phase == PolarAlignPhase.measuring
                                    ? _buildMeasuringStatus(colors, state)
                                    : state.phase == PolarAlignPhase.adjusting
                                        ? _buildAdjustmentInstructions(
                                            colors, state, config)
                                        : state.phase ==
                                                PolarAlignPhase.complete
                                            ? _buildCompleteStatus(
                                                colors, state)
                                            : _buildErrorStatus(colors, state),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressSteps(
      SkotiqColors colors, PolarAlignmentState state) {
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
      // narrow phone; it stays centered when there's room.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.sizeOf(context).width -
                48, // account for the 24px horizontal padding either side
          ),
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
    );
  }

  /// The idle centre column: what this method does, and the four things the
  /// operator has to do before starting.
  ///
  /// It was a 64px tinted icon over a 20px bold heading, a centred paragraph
  /// and four bespoke numbered rows. The panel carries it now, the steps are
  /// the kit's [Checklist], and the copy is sentence case.
  Widget _buildSetupInstructions(SkotiqColors colors) {
    final isAllSky = ref.watch(polarAlignmentUiStateProvider).mode ==
        PolarAlignmentMode.allSky;

    final steps = isAllSky
        ? const <ChecklistStep>[
            ChecklistStep(
              title: 'Point at any bright star field',
              detail: 'It does not have to be near the pole.',
            ),
            ChecklistStep(title: 'Connect the camera and the mount'),
            ChecklistStep(
              title: 'Set the exposure on the left, then start',
            ),
            ChecklistStep(
              title: 'Follow the live reticle while you adjust',
              detail: 'Azimuth and altitude, on the right.',
            ),
          ]
        : const <ChecklistStep>[
            ChecklistStep(
              title: 'Roughly align the mount to the pole',
              detail: 'Within a few degrees is enough.',
            ),
            ChecklistStep(title: 'Point the telescope near the celestial pole'),
            ChecklistStep(title: 'Connect the camera and the mount'),
            ChecklistStep(title: 'Set the options on the left, then start'),
          ];

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.space2xl,
        vertical: SkotiqTokens.spaceLg,
      ),
      child: SkotiqPanel(
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
                      'on the reticle while you adjust the mount.'
                  : 'Skotiq captures three images at different positions, '
                      'plate-solves each one, and works out how far the '
                      "mount's polar axis is from the pole.",
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            Checklist(steps: steps),
          ],
        ),
      ),
    );
  }
}

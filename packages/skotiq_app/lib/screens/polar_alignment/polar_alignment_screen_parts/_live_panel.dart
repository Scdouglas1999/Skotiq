part of '../polar_alignment_screen.dart';

/// Width at which the readout strip under the frame lays its parts in a row.
const double _liveStripRowMinWidth = 560;

/// Height of the bullseye in the readout column beside the frame.
const double _liveSideBullseyeHeight = 180;

extension _LivePanel on _PolarAlignmentScreenState {
  /// The body of a run in progress: the progress rail and the live frame,
  /// with the error readout and the step card in one compact column.
  Widget _buildLiveBody(
    SkotiqColors colors,
    PolarAlignmentState state,
    PolarAlignmentConfig config,
  ) {
    final showHistory = ref.watch(
      polarAlignmentUiStateProvider.select((s) => s.showHistoryPanel),
    );
    return PolarAlignmentLiveLayout(
      rail: _buildProgressSteps(colors, state),
      frame: _buildLiveFrame(colors, state),
      side: _buildLiveSide(colors, state, config),
      settings:
          showHistory ? _buildLeftPanel(colors, state, config, true) : null,
    );
  }

  Widget _buildLiveSide(
    SkotiqColors colors,
    PolarAlignmentState state,
    PolarAlignmentConfig localConfig,
  ) {
    // The run's own settings when it carries them: a run started from the API
    // or another window has its own threshold, not this window's.
    final config = state.config ?? localConfig;
    final card = state.phase == PolarAlignPhase.adjusting
        ? _buildAdjustCard(colors, state, config)
        : _buildMeasuringCard(colors, state);
    final errorHistory = ref.watch(polarAlignmentErrorHistoryProvider);
    final trend =
        state.phase == PolarAlignPhase.adjusting && errorHistory.length > 2
            ? _buildLiveTrend(colors, errorHistory, config)
            : null;

    final isAllSky = ref.watch(polarAlignmentUiStateProvider).mode ==
        PolarAlignmentMode.allSky;
    // All-sky keeps its own reticle: its marker and acceptance ring are what
    // the drift method reports. Both are passed the error nullable, so an
    // unmeasured target reads as no reading and not as zero error.
    Widget bullseye(double height) => SizedBox(
          height: height,
          child: isAllSky
              ? Center(
                  child: AllSkyTargetReticle(
                    azimuthErrorArcsec: state.currentError?.azimuthError,
                    altitudeErrorArcsec: state.currentError?.altitudeError,
                    acceptanceThresholdArcsec: config.autoCompleteThreshold,
                    waitingForFirstFrame: state.currentError == null,
                  ),
                )
              : _PolarErrorVisualization(
                  colors: colors,
                  error: state.currentError,
                  phase: state.phase,
                  pulseAnimation: _pulseController,
                ),
        );
    Widget readouts(double width) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildErrorValues(colors, state.currentError, width),
            if (isAllSky) ...[
              const SizedBox(height: SkotiqTokens.spaceXs),
              _buildDriftBaselineCaption(colors, state),
            ] else if (state.currentError == null) ...[
              const SizedBox(height: SkotiqTokens.spaceXs),
              Text(
                'No measurement yet',
                textAlign: TextAlign.center,
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
              ),
            ],
          ],
        );

    return Container(
      key: TourTarget.polarErrorDisplay.key,
      color: colors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const pad = SkotiqTokens.spaceMd;
          final inner = constraints.maxWidth - 2 * pad;
          final beside =
              constraints.maxWidth <= PolarAlignmentLiveLayout.sideWidth + 1;

          if (beside) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  bullseye(_liveSideBullseyeHeight),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  readouts(inner),
                  const SizedBox(height: SkotiqTokens.spaceLg),
                  card,
                  if (trend != null) ...[
                    const SizedBox(height: SkotiqTokens.spaceLg),
                    trend,
                  ],
                ],
              ),
            );
          }

          if (constraints.maxWidth >= _liveStripRowMinWidth) {
            const bullseyeWidth = 170.0;
            const cardWidth = 280.0;
            final middle =
                inner - bullseyeWidth - cardWidth - 2 * SkotiqTokens.spaceMd;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(pad),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: bullseyeWidth, child: bullseye(150)),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        readouts(middle),
                        if (trend != null) ...[
                          const SizedBox(height: SkotiqTokens.spaceMd),
                          trend,
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  SizedBox(width: cardWidth, child: card),
                ],
              ),
            );
          }

          // A phone: the target and the numbers on one row, the card under.
          const smallBullseye = 120.0;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(width: smallBullseye, child: bullseye(110)),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Expanded(
                      child: readouts(
                        inner - smallBullseye - SkotiqTokens.spaceSm,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                card,
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildLiveTrend(
    SkotiqColors colors,
    List<PolarAlignmentError> errors,
    PolarAlignmentConfig config,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(LucideIcons.trendingDown, size: 12, color: colors.textMuted),
            const SizedBox(width: 6),
            Text(
              'Error trend',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                fontWeight: FontWeight.w600,
                color: colors.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        SizedBox(
          height: 64,
          child: ErrorTrendChart(
            colors: colors,
            errors: errors,
            threshold: config.autoCompleteThreshold,
          ),
        ),
      ],
    );
  }
}

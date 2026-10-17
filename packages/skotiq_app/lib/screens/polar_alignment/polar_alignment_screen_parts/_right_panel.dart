// ignore_for_file: unused_element

part of '../polar_alignment_screen.dart';

extension _RightPanel on _PolarAlignmentScreenState {
  Widget _buildRightPanel(
    SkotiqColors colors,
    PolarAlignmentState state,
    PolarAlignmentConfig config,
  ) {
    final errorHistory = ref.watch(polarAlignmentErrorHistoryProvider);
    final isAllSky = ref.watch(polarAlignmentUiStateProvider).mode ==
        PolarAlignmentMode.allSky;

    // Error visualization
    //
    // All-Sky mode shows the Sharpcap-style target reticle with a live
    // moving marker; TPPA mode keeps the legacy bar/dial visualization.
    final Widget visualization = isAllSky
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              // Pass the error through NULLABLE: null means unmeasured, 0 means
              // aligned. Coalescing to 0 makes the idle reticle compute
              // totalError == 0 and announce "Within acceptance — hold steady"
              // before any frame exists.
              child: AllSkyTargetReticle(
                azimuthErrorArcsec: state.currentError?.azimuthError,
                altitudeErrorArcsec: state.currentError?.altitudeError,
                acceptanceThresholdArcsec: config.autoCompleteThreshold,
                waitingForFirstFrame:
                    state.phase == PolarAlignPhase.adjusting &&
                        state.currentError == null,
              ),
            ),
          )
        : Stack(
            alignment: Alignment.center,
            children: [
              _PolarErrorVisualization(
                colors: colors,
                error: state.currentError,
                phase: state.phase,
                pulseAnimation: _pulseController,
              ),
              // A run that never reached a measurement — not started, or ended
              // in error — leaves the rings with nothing to show. Say so, so
              // the empty target is read as "no reading" and not as zero error.
              // The test is whether a measurement EXISTS: a completed run still
              // has one, and captioning its plotted result "No measurement yet"
              // contradicted the numbers printed directly beneath it.
              if (state.phase != PolarAlignPhase.idle &&
                  state.currentError == null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Text(
                    'No measurement yet',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              if (state.phase == PolarAlignPhase.idle)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Text(
                    'After you start, this bullseye shows live '
                    'azimuth and altitude error while you adjust the '
                    'mount. Rings mark 30", 60", and 120" error zones.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          );

    // Task 4.5: Error trend sparkline chart (only in adjustment phase)
    final Widget? trendChart =
        (state.phase == PolarAlignPhase.adjusting && errorHistory.length > 2)
            ? Container(
                height: 100,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  border: Border(top: BorderSide(color: colors.border)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(LucideIcons.trendingDown,
                            size: 12, color: colors.textMuted),
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
                    const SizedBox(height: 8),
                    Expanded(
                      child: ErrorTrendChart(
                        colors: colors,
                        errors: errorHistory,
                        threshold: config.autoCompleteThreshold,
                      ),
                    ),
                  ],
                ),
              )
            : null;

    // Error values
    final Widget errorValues = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildErrorValues(colors, state.currentError),
          // All-Sky derives the polar error from the DRIFT between a fixed
          // baseline solve and the current one, so its precision is a function
          // of how long that baseline has been running — and nothing on screen
          // said how long that was. The first samples produced a 0.0" reading
          // and an 11-degree reading minutes apart, both presented with the
          // same authority.
          if (isAllSky) ...[
            const SizedBox(height: 10),
            _buildDriftBaselineCaption(colors, state),
          ],
        ],
      ),
    );

    return Container(
      key: PolarAlignmentTutorialKeys.errorDisplay,
      color: colors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: 160 * textScale),
                        child: visualization,
                      ),
                    ),
                    if (trendChart != null) trendChart,
                    errorValues,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// How long the All-Sky drift baseline has been accumulating.
  ///
  /// The native run solves ONE baseline frame (`do_baseline`) and then derives
  /// every subsequent misalignment from the drift between that frame and the
  /// current one, so the true interval runs from the BASELINE solve. The wire
  /// carries no baseline timestamp — `PolarAlignmentError.fromEventData` stamps
  /// `DateTime.now()` on receipt — so the best the app can see is the gap
  /// between the first drift solve (`initialError`) and the latest
  /// (`currentError`). That is short of the truth by exactly one iteration
  /// (cadence + exposure + solve), which is why this is rendered as a FLOOR
  /// rather than as a measurement: a reading taken over a few seconds and one
  /// taken over ten minutes are not the same measurement, and the app cannot
  /// claim a precision it does not have.
  Widget _buildDriftBaselineCaption(
    SkotiqColors colors,
    PolarAlignmentState state,
  ) {
    final first = state.initialError;
    final current = state.currentError;
    final elapsed = (first == null || current == null)
        ? null
        : current.timestamp.difference(first.timestamp);
    final String text;
    if (elapsed == null) {
      text = 'Drift baseline: not started';
    } else if (elapsed.inSeconds <= 0) {
      // Only one drift solve so far. The reading is NOT derived over zero time
      // — it covers the one iteration since the baseline frame — so say which
      // sample this is instead of printing a "0s" the run never had.
      text = 'Drift baseline: first drift solve';
    } else {
      text = 'Drift baseline: at least ${formatDriftBaseline(elapsed)}';
    }
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: SkotiqTypography.fontSize11,
        color: colors.textMuted,
      ),
    );
  }

  /// Azimuth / altitude / total polar error, as Readouts.
  ///
  /// These were label-above-value tiles printing "--" before the first solve.
  /// A Readout is value-loud, label-quiet (02 rule 3), and renders an unknown
  /// as an em dash from a null value — never a pair of hyphens.
  Widget _buildErrorValues(SkotiqColors colors, PolarAlignmentError? error) {
    return ReadoutRow(
      gap: SkotiqTokens.spaceLg,
      children: <Readout>[
        Readout(
          label: 'Azimuth',
          value: error == null ? null : formatPolarError(error.azimuthError),
          size: ReadoutSize.sm,
          valueColor: error == null
              ? null
              : _getErrorColor(colors, error.azimuthError.abs()),
        ),
        Readout(
          label: 'Altitude',
          value: error == null ? null : formatPolarError(error.altitudeError),
          size: ReadoutSize.sm,
          valueColor: error == null
              ? null
              : _getErrorColor(colors, error.altitudeError.abs()),
        ),
        // The total is the number the operator is driving to zero, so it is
        // the loud one.
        Readout(
          label: 'Total',
          value: error == null ? null : formatPolarError(error.totalError),
          valueColor:
              error == null ? null : _getErrorColor(colors, error.totalError),
        ),
      ],
    );
  }

  Color _getErrorColor(SkotiqColors colors, double error) {
    if (error < 30) return colors.success;
    if (error < 60) return colors.info;
    if (error < 120) return colors.warning;
    return colors.error;
  }
}

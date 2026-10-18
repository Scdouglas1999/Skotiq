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
              // Inset so the outer ring and its label clear the column edge;
              // the painter sizes the rings to whatever this leaves.
              Padding(
                padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                child: _PolarErrorVisualization(
                  colors: colors,
                  error: state.currentError,
                  phase: state.phase,
                  pulseAnimation: _pulseController,
                ),
              ),
              // A run that never reached a measurement — not started, or ended
              // in error — leaves the rings with nothing to show. Say so, so
              // the empty target is read as "no reading" and not as zero error.
              // The test is whether a measurement EXISTS: a completed run still
              // has one, and captioning its plotted result "No measurement yet"
              // contradicted the numbers printed directly beneath it. Idle says
              // nothing here: the setup checklist already explains the target.
              if (state.phase != PolarAlignPhase.idle &&
                  state.currentError == null)
                Positioned(
                  left: SkotiqTokens.spaceLg,
                  right: SkotiqTokens.spaceLg,
                  bottom: SkotiqTokens.spaceSm,
                  child: Text(
                    'No measurement yet',
                    textAlign: TextAlign.center,
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textMuted),
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
    Widget errorValues(double panelWidth) => Container(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildErrorValues(
                colors,
                state.currentError,
                panelWidth - 2 * SkotiqTokens.spaceLg,
              ),
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
                    errorValues(constraints.maxWidth),
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
  ///
  /// Each readout owns a fixed third of the row and the row aligns their
  /// BOTTOMS, so the three labels share one baseline even though Total is the
  /// larger value. Top-aligned in a centred Wrap, Total's label sat lower than
  /// the other two, and every change in a value's width slid all three
  /// sideways while the operator was turning a bolt. A column too narrow for
  /// three fixed thirds falls back to wrapping rather than ellipsizing a
  /// number.
  ///
  /// [width] is the row's width, passed in rather than measured with a
  /// LayoutBuilder because the column sizes this row intrinsically.
  Widget _buildErrorValues(
    SkotiqColors colors,
    PolarAlignmentError? error,
    double width,
  ) {
    final readouts = <Readout>[
      Readout(
        key: const ValueKey('polar-readout-azimuth'),
        label: 'Azimuth',
        value: error == null ? null : formatPolarError(error.azimuthError),
        size: ReadoutSize.sm,
        valueColor: error == null
            ? null
            : _getErrorColor(colors, error.azimuthError.abs()),
      ),
      Readout(
        key: const ValueKey('polar-readout-altitude'),
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
        key: const ValueKey('polar-readout-total'),
        label: 'Total',
        value: error == null ? null : formatPolarError(error.totalError),
        valueColor:
            error == null ? null : _getErrorColor(colors, error.totalError),
      ),
    ];
    if (width < _errorValuesRowMinWidth) {
      return Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: SkotiqTokens.spaceLg,
        runSpacing: ReadoutRow.runGap,
        children: readouts,
      );
    }
    // Capped, so on the wide idle column the three stay a group under the
    // target instead of spreading to the far edges.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _errorValuesRowMaxWidth),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Total is the larger value, so it gets the larger share.
            for (var i = 0; i < readouts.length; i++)
              Expanded(
                flex: i == readouts.length - 1 ? 4 : 3,
                child: Center(child: readouts[i]),
              ),
          ],
        ),
      ),
    );
  }

  /// Below this the fixed shares are narrower than a degrees-sized value
  /// ("-11° 08' 24\""), which an operator's first measurement often is.
  static const double _errorValuesRowMinWidth = 380;

  /// Widest the error row grows: the outer ring's diameter, near enough.
  static const double _errorValuesRowMaxWidth = 560;

  Color _getErrorColor(SkotiqColors colors, double error) {
    if (error < 30) return colors.success;
    if (error < 60) return colors.info;
    if (error < 120) return colors.warning;
    return colors.error;
  }
}

// Stats bar, status indicator, exposure countdown and visualization toggles.
part of '../flat_preview_panel.dart';

class _StatsBar extends StatelessWidget {
  final FlatWizardState state;

  const _StatsBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final currentFilter = state.filterSettings.isNotEmpty &&
            state.currentFilterIndex < state.filterSettings.length
        ? state.filterSettings[state.currentFilterIndex]
        : null;

    // The frame count reads "0 / 30" before a run, so the aim is on screen.
    final frameTarget =
        currentFilter?.frameCountOverride ?? state.globalSettings.frameCount;
    final readouts = <Readout>[
      Readout(
        label: 'Filter',
        value: currentFilter?.label,
        size: ReadoutSize.sm,
      ),
      Readout(
        label: 'Exposure',
        value: currentFilter?.calibratedExposure?.toStringAsFixed(2),
        unit: 's',
        size: ReadoutSize.sm,
      ),
      Readout(
        label: 'ADU',
        value: currentFilter?.currentAdu?.toStringAsFixed(0),
        size: ReadoutSize.sm,
      ),
      Readout(
        label: 'Frame',
        value: '${currentFilter?.capturedCount ?? 0} / $frameTarget',
        size: ReadoutSize.sm,
      ),
    ];

    // A well under the frame: a data display, not another panel.
    return Container(
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: SkotiqTokens.borderRadiusLg,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceLg,
          vertical: SkotiqTokens.spaceMd,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Keep readouts + status on one line only when there is
            // comfortable room; otherwise stack the status under them.
            final inline = constraints.maxWidth >= _inlineStatusWidth;
            final strip = ReadoutRow(
              gap: SkotiqTokens.space2xl,
              children: readouts,
            );
            final status = _StatusIndicator(
              status: currentFilter?.status ?? FilterCalibrationStatus.pending,
              colors: colors,
            );

            // The run's own last word (how many frames it saved, or why it
            // stopped), once it is over. An error has its banner.
            final outcome = !state.isCapturing && state.errorMessage == null
                ? state.statusMessage
                : null;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (inline)
                  Row(
                    children: [
                      Expanded(child: strip),
                      const SizedBox(width: SkotiqTokens.spaceLg),
                      status,
                    ],
                  )
                else ...[
                  strip,
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  Align(alignment: Alignment.centerRight, child: status),
                ],
                if (outcome != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  Text(
                    outcome,
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textSecondary),
                  ),
                ],
              ],
            );
          },
        ),
    );
  }

  /// Below this width the status indicator drops onto its own line.
  static const double _inlineStatusWidth = 460;
}

/// The one word for a filter's state, wherever the screen says it.
String flatFilterStatusLabel(FilterCalibrationStatus status) =>
    switch (status) {
      FilterCalibrationStatus.pending => 'Pending',
      FilterCalibrationStatus.calibrating => 'Finding exposure',
      FilterCalibrationStatus.calibrated => 'On target',
      FilterCalibrationStatus.capturing => 'Capturing',
      FilterCalibrationStatus.complete => 'Complete',
      FilterCalibrationStatus.partial => 'Partial',
      FilterCalibrationStatus.failed => 'Failed',
      FilterCalibrationStatus.skipped => 'Skipped',
    };

class _StatusIndicator extends StatelessWidget {
  final FilterCalibrationStatus status;
  final SkotiqColors colors;

  const _StatusIndicator({
    required this.status,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      FilterCalibrationStatus.pending => (LucideIcons.clock, colors.textMuted),
      FilterCalibrationStatus.calibrating => (
          LucideIcons.settings,
          colors.warning
        ),
      FilterCalibrationStatus.calibrated => (LucideIcons.check, colors.success),
      FilterCalibrationStatus.capturing => (LucideIcons.camera, colors.success),
      FilterCalibrationStatus.complete => (
          LucideIcons.checkCircle,
          colors.success
        ),
      FilterCalibrationStatus.partial => (
          LucideIcons.alertTriangle,
          colors.warning
        ),
      FilterCalibrationStatus.failed => (LucideIcons.alertCircle, colors.error),
      FilterCalibrationStatus.skipped => (
          LucideIcons.skipForward,
          colors.textMuted
        ),
    };
    final label = flatFilterStatusLabel(status);

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(icon, size: SkotiqTokens.iconGlyphPanelHead, color: color),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Text(
          label,
          style: SkotiqTypography.bodySm.copyWith(color: color),
        ),
      ],
    );
  }
}

class _ExposureCountdown extends StatefulWidget {
  final FlatWizardState state;

  const _ExposureCountdown({required this.state});

  @override
  State<_ExposureCountdown> createState() => _ExposureCountdownState();
}

class _ExposureCountdownState extends State<_ExposureCountdown> {
  /// Redraws the countdown; canceled on dispose so no tick outlives the
  /// widget.
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _scheduleNextTick();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  void _scheduleNextTick() {
    _tickTimer?.cancel();
    _tickTimer = Timer(const Duration(milliseconds: 100), () {
      if (!mounted || !widget.state.isExposing) return;
      setState(() {});
      _scheduleNextTick();
    });
  }

  /// Width of the exposure's own progress bar.
  static const double _barWidth = 96;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    if (widget.state.exposureStartTime == null ||
        widget.state.currentExposureDuration == null) {
      return const SizedBox.shrink();
    }

    final exposure = widget.state.currentExposureDuration!;
    final elapsed = DateTime.now()
            .difference(widget.state.exposureStartTime!)
            .inMilliseconds /
        1000.0;
    final remaining = (exposure - elapsed).clamp(0.0, exposure);
    final progress = elapsed / exposure;

    return Container(
      margin: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: SkotiqTokens.borderRadiusLg,
      ),
      child: Row(
        children: [
          Icon(LucideIcons.timer,
              size: SkotiqTokens.iconSm, color: colors.textSecondary),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Flexible(
            child: Text(
              flatExposureProgressLine(widget.state, remaining),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.withTabular(
                SkotiqTypography.labelStrong.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceLg),
          SizedBox(
            width: _barWidth,
            child: SkotiqProgressBar(value: progress.clamp(0.0, 1.0)),
          ),
        ],
      ),
    );
  }
}

/// What the countdown says: the frame being taken and roughly how long the
/// filter has left while frames are captured, or that the exposure is still
/// being found.
@visibleForTesting
String flatExposureProgressLine(FlatWizardState state, double remainingSecs) {
  final left = '${remainingSecs.toStringAsFixed(1)} s left';
  final filter = state.filterSettings.isNotEmpty &&
          state.currentFilterIndex < state.filterSettings.length
      ? state.filterSettings[state.currentFilterIndex]
      : null;
  if (filter == null || filter.status != FilterCalibrationStatus.capturing) {
    return 'Finding the exposure · $left';
  }
  final target = filter.frameCountOverride ?? state.globalSettings.frameCount;
  final frame = (filter.capturedCount + 1).clamp(1, target);
  final exposure = state.currentExposureDuration ?? 0;
  final rest = remainingSecs + (target - frame) * exposure;
  final eta = target > frame
      ? ' · ≈${DurationFormat.seconds(rest, style: DurationStyle.coarse)}'
          ' to go'
      : '';
  return 'Frame $frame of $target · $left$eta';
}

class _VisualizationsSection extends ConsumerWidget {
  /// Below this width the graph and the filter results stack down to one.
  static const double _sideBySideWidth = 560;

  final FlatWizardState state;

  const _VisualizationsSection({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!state.showAduGraph && !state.showFilterCards) {
      return const SizedBox.shrink();
    }

    final currentFilter = state.filterSettings.isNotEmpty &&
            state.currentFilterIndex < state.filterSettings.length
        ? state.filterSettings[state.currentFilterIndex]
        : null;
    final histogramTarget = currentFilter?.histogramTargetOverride ??
        state.globalSettings.histogramTarget;
    final tolerancePercent = currentFilter?.toleranceOverride ??
        state.globalSettings.tolerancePercent;
    // Target ADU against the camera's detected full scale, so the graph's
    // target band is one a 12, 14 or 16-bit camera can reach.
    final cameraConfig = ref.watch(flatCameraConfigProvider);
    final targetAdu = cameraConfig.targetAduFor(histogramTarget);
    final toleranceAdu = targetAdu * tolerancePercent / 100.0;
    final notifier = ref.read(flatWizardProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          icon: LucideIcons.lineChart,
          title: 'Convergence',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SkotiqIconButton(
                icon: LucideIcons.barChart3,
                tooltip: 'Histogram on the frame',
                size: IconButtonSize.sm,
                selected: state.showHistogramOverlay,
                onPressed: () => notifier
                    .toggleHistogramOverlay(!state.showHistogramOverlay),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              SkotiqIconButton(
                icon: LucideIcons.lineChart,
                tooltip: 'ADU graph',
                size: IconButtonSize.sm,
                selected: state.showAduGraph,
                onPressed: () => notifier.toggleAduGraph(!state.showAduGraph),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              SkotiqIconButton(
                icon: LucideIcons.list,
                tooltip: 'Filter results',
                size: IconButtonSize.sm,
                selected: state.showFilterCards,
                onPressed: () =>
                    notifier.toggleFilterCards(!state.showFilterCards),
              ),
            ],
          ),
        ),

        // Side by side only when there is room for two; on a phone the graph
        // is the section's subject and the results stand in when it is off.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final graph = state.showAduGraph
                  ? _AduConvergenceGraph(
                      history: state.aduHistory,
                      targetAdu: targetAdu,
                      toleranceAdu: toleranceAdu,
                    )
                  : null;
              final results = state.showFilterCards
                  ? _FilterResults(state: state)
                  : null;

              if (constraints.maxWidth < _sideBySideWidth) {
                return graph ?? results ?? const SizedBox.shrink();
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (graph != null) Expanded(child: graph),
                  if (graph != null && results != null)
                    const SizedBox(width: SkotiqTokens.spaceLg),
                  if (results != null) Expanded(child: results),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

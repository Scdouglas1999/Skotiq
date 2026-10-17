// Stats bar, status indicator, exposure countdown and visualization toggles.
part of '../flat_preview_panel.dart';

class _StatsBar extends StatelessWidget {
  final FlatWizardState state;

  const _StatsBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // Get current filter info
    final currentFilter = state.filterSettings.isNotEmpty &&
            state.currentFilterIndex < state.filterSettings.length
        ? state.filterSettings[state.currentFilterIndex]
        : null;

    // Readouts, not a stat strip: an unknown value is an em dash (Readout
    // renders it from a null), never a hyphen, and the frame count reads
    // "0 / 30" instead of "-/-" — a pair of hyphens said nothing about how many
    // frames the run is even aiming for.
    final frameTarget =
        currentFilter?.frameCountOverride ?? state.globalSettings.frameCount;
    final readouts = <Readout>[
      Readout(
        label: 'Filter',
        value: currentFilter?.filterName,
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

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
      ),
      child: Container(
        // A well under the image, not a card: this is a data display inside
        // the preview column (02 rule 2).
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: SkotiqTokens.borderRadiusSm,
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
              children: readouts,
              gap: SkotiqTokens.space2xl,
            );
            final status = _StatusIndicator(
              status: currentFilter?.status ?? FilterCalibrationStatus.pending,
              colors: colors,
            );

            if (inline) {
              return Row(
                children: [
                  Expanded(child: strip),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  status,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                strip,
                const SizedBox(height: SkotiqTokens.spaceMd),
                Align(alignment: Alignment.centerRight, child: status),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Below this width the status indicator drops onto its own line.
  static const double _inlineStatusWidth = 460;
}

class _StatusIndicator extends StatelessWidget {
  final FilterCalibrationStatus status;
  final SkotiqColors colors;

  const _StatusIndicator({
    required this.status,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (status) {
      FilterCalibrationStatus.pending => (
          LucideIcons.clock,
          'Pending',
          colors.textMuted
        ),
      FilterCalibrationStatus.calibrating => (
          LucideIcons.settings,
          'Calibrating',
          colors.warning
        ),
      FilterCalibrationStatus.calibrated => (
          LucideIcons.check,
          'On target',
          colors.success
        ),
      FilterCalibrationStatus.capturing => (
          LucideIcons.camera,
          'Capturing',
          colors.primary
        ),
      FilterCalibrationStatus.complete => (
          LucideIcons.checkCircle,
          'Complete',
          colors.success
        ),
      FilterCalibrationStatus.partial => (
          LucideIcons.alertTriangle,
          'Partial',
          colors.warning
        ),
      FilterCalibrationStatus.failed => (
          LucideIcons.alertCircle,
          'Failed',
          colors.error
        ),
      FilterCalibrationStatus.skipped => (
          LucideIcons.skipForward,
          'Skipped',
          colors.textMuted
        ),
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(icon, size: SkotiqTokens.iconGlyphPanelHead, color: color),
        const SizedBox(width: SkotiqTokens.spaceXs + 2),
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
  // Owned so we can cancel on dispose — without an explicit Timer field this
  // recursive Future.delayed schedules a fresh timer every 100 ms whose
  // closure would outlive the widget tree on teardown (hot reload, widget
  // test, fast navigation).
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    // Trigger rebuilds for countdown animation
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

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    if (widget.state.exposureStartTime == null ||
        widget.state.currentExposureDuration == null) {
      return const SizedBox.shrink();
    }

    final elapsed = DateTime.now()
            .difference(widget.state.exposureStartTime!)
            .inMilliseconds /
        1000.0;
    final remaining = (widget.state.currentExposureDuration! - elapsed)
        .clamp(0.0, widget.state.currentExposureDuration!);
    final progress = elapsed / widget.state.currentExposureDuration!;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.primary,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.timer, size: 18, color: colors.primary),
          const SizedBox(width: 12),
          Text(
            'CAPTURING: ${remaining.toStringAsFixed(1)}s remaining',
            style: SkotiqTypography.labelStrong.copyWith(color: colors.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: SkotiqProgressBar(
              value: progress.clamp(0.0, 1.0),
              height: 6,
            ),
          ),
        ],
      ),
    );
  }
}

class _VisualizationsSection extends ConsumerWidget {
  /// Below this width the two visualizations stack down to one.
  static const double _sideBySideWidth = 560;

  final FlatWizardState state;

  const _VisualizationsSection({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Count visible visualizations
    final visibleCount = [
      state.showAduGraph,
      state.showFilterCards,
    ].where((v) => v).length;

    if (visibleCount == 0) {
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
    // Target ADU against the DETECTED full scale so the convergence graph's
    // target/tolerance bands match what a 12/14/16-bit camera can actually
    // reach (not a hardcoded 16-bit range).
    final cameraConfig = ref.watch(flatCameraConfigProvider);
    final targetAdu = cameraConfig.targetAduFor(histogramTarget);
    final toleranceAdu = targetAdu * tolerancePercent / 100.0;

    return Container(
      margin: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A section title naming what the reader is looking at, not the
          // category word "Visualizations". The two view toggles ride in its
          // trailing slot as kit icon buttons.
          SectionTitle(
            icon: LucideIcons.lineChart,
            title: 'Convergence',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SkotiqIconButton(
                  icon: LucideIcons.lineChart,
                  tooltip: 'ADU graph',
                  size: IconButtonSize.sm,
                  selected: state.showAduGraph,
                  onPressed: () => ref
                      .read(flatWizardProvider.notifier)
                      .toggleAduGraph(!state.showAduGraph),
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                SkotiqIconButton(
                  icon: LucideIcons.layoutGrid,
                  tooltip: 'Filter cards',
                  size: IconButtonSize.sm,
                  selected: state.showFilterCards,
                  onPressed: () => ref
                      .read(flatWizardProvider.notifier)
                      .toggleFilterCards(!state.showFilterCards),
                ),
              ],
            ),
          ),

          // Visualization content.
          //
          // Side by side only when there is room for two: on a phone the
          // region is ~360 wide, and splitting it gave each half a ~98px
          // column that could hold neither a chart nor its empty state.
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
                final cards = state.showFilterCards
                    ? _FilterProgressCards(state: state)
                    : null;

                if (constraints.maxWidth < _sideBySideWidth) {
                  // The convergence chart is the section's subject; the filter
                  // cards stand in only when it is switched off.
                  return graph ?? cards ?? const SizedBox.shrink();
                }
                return Row(
                  children: [
                    if (graph != null) Expanded(child: graph),
                    if (cards != null) Expanded(child: cards),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

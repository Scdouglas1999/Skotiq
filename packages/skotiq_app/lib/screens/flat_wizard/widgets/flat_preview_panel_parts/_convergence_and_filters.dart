// ADU convergence graph and per-filter results.
part of '../flat_preview_panel.dart';

class _AduConvergenceGraph extends StatelessWidget {
  final List<AduMeasurement> history;
  final double targetAdu;
  final double toleranceAdu;

  const _AduConvergenceGraph({
    required this.history,
    required this.targetAdu,
    required this.toleranceAdu,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // The section title above already says "Convergence", so the panel has
    // no head of its own.
    return SkotiqPanel(
      padding: SkotiqTokens.paddingMd,
      child: history.isEmpty
          ? const _CenteredEmptyState(
              icon: LucideIcons.lineChart,
              title: 'No measurements yet',
              body: 'Each exposure plots its ADU against the target.',
            )
          : _buildChart(colors),
    );
  }

  Widget _buildChart(SkotiqColors colors) {
    final spots = <FlSpot>[
      for (int i = 0; i < history.length; i++)
        FlSpot(i.toDouble(), history[i].adu),
    ];

    // Scale the axis so both the measured curve and the target band are always
    // visible, regardless of how far the first attempts overshoot.
    var minY = history.map((m) => m.adu).reduce(math.min);
    var maxY = history.map((m) => m.adu).reduce(math.max);
    minY = math.min(minY, targetAdu - toleranceAdu);
    maxY = math.max(maxY, targetAdu + toleranceAdu);
    final pad = math.max(maxY - minY, 1.0) * 0.1;
    minY -= pad;
    maxY += pad;

    final maxX = math.max((history.length - 1).toDouble(), 1.0);
    // Round ticks inside the range: an interval of a third of a padded range
    // put two labels on top of each other at the bottom edge.
    final ticks = ChartScale.ticksWithin(minY, maxY, 3);
    final kiloDecimals = ChartScale.decimalsFor(ticks.step / 1000);
    bool isTick(double value) => ticks.values
        .any((tick) => (tick - value).abs() <= ticks.step.abs() * 1e-6);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        clipData: const FlClipData.all(),
        gridData: const FlGridData(show: false),
        titlesData: FlTitlesData(
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            axisNameSize: 16,
            axisNameWidget: Text(
              'Exposures, in order',
              style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
            ),
            sideTitles: const SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              interval: ticks.step > 0 ? ticks.step : null,
              getTitlesWidget: (value, meta) => isTick(value)
                  ? Text(
                      '${(value / 1000).toStringAsFixed(kiloDecimals)}k',
                      style: SkotiqTypography.monoXs
                          .copyWith(color: colors.textMuted),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: colors.border.withValues(alpha: 0.5)),
        ),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            HorizontalRangeAnnotation(
              y1: targetAdu - toleranceAdu,
              y2: targetAdu + toleranceAdu,
              color: colors.success.withValues(alpha: 0.12),
            ),
          ],
        ),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            HorizontalLine(
              y: targetAdu,
              color: colors.success.withValues(alpha: 0.7),
              strokeWidth: 1,
              dashArray: [4, 3],
            ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: colors.primary,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: history.length <= 24,
              getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                radius: 2.5,
                color: colors.primary,
                strokeWidth: 0,
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => colors.surface,
            getTooltipItems: (touchedSpots) => touchedSpots
                .map(
                  (spot) => LineTooltipItem(
                    'ADU: ${spot.y.toStringAsFixed(0)}',
                    SkotiqTypography.monoXs.copyWith(color: colors.textPrimary),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}

/// What each filter of the run has so far: its exposure and level, its
/// status and its frame count, one row per filter.
///
/// A quick capture takes one filter, so only that row shows. The list scrolls
/// and keeps the filter being captured in view.
class _FilterResults extends StatefulWidget {
  final FlatWizardState state;

  const _FilterResults({required this.state});

  @override
  State<_FilterResults> createState() => _FilterResultsState();
}

class _FilterResultsState extends State<_FilterResults> {
  final GlobalKey _activeRow = GlobalKey();

  List<FlatFilterSettings> get _rows {
    final state = widget.state;
    final filters = state.filterSettings;
    if (state.mode == FlatWizardMode.quick) {
      final i = state.currentFilterIndex;
      return i >= 0 && i < filters.length ? [filters[i]] : const [];
    }
    return filters.where((f) => f.enabled).toList();
  }

  static bool _isActive(FlatFilterSettings f) =>
      f.status == FilterCalibrationStatus.calibrating ||
      f.status == FilterCalibrationStatus.capturing;

  /// Slot of the filter the run is on, or null between filters.
  int? get _activePosition {
    for (final f in _rows) {
      if (_isActive(f)) return f.filterPosition;
    }
    return null;
  }

  int? _followed;

  @override
  void initState() {
    super.initState();
    _followActive();
  }

  @override
  void didUpdateWidget(covariant _FilterResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    _followActive();
  }

  /// Scrolls the filter being captured into view when the run moves to it.
  void _followActive() {
    final active = _activePosition;
    if (active == _followed) return;
    _followed = active;
    if (active == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _activeRow.currentContext;
      if (!mounted || row == null) return;
      Scrollable.ensureVisible(
        row,
        duration: SkotiqTokens.durationSmooth,
        curve: SkotiqTokens.curveStandard,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final activeIndex = rows.indexWhere(_isActive);

    return SkotiqPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceXs,
      ),
      child: rows.isEmpty
          ? const _CenteredEmptyState(
              icon: LucideIcons.filter,
              title: 'No filters selected',
              body: 'Each filter of a run reports here.',
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < rows.length; i++)
                    _FilterResultRow(
                      key: i == activeIndex ? _activeRow : null,
                      filter: rows[i],
                      globalFrameCount: widget.state.globalSettings.frameCount,
                      showDivider: i < rows.length - 1,
                    ),
                ],
              ),
            ),
    );
  }
}

class _FilterResultRow extends StatelessWidget {
  final FlatFilterSettings filter;
  final int globalFrameCount;
  final bool showDivider;

  const _FilterResultRow({
    super.key,
    required this.filter,
    required this.globalFrameCount,
    required this.showDivider,
  });

  /// Width of the filter name's column, so the facts line up down the list.
  static const double _nameWidth = 72;

  /// Width of the "12 / 30" count, right-aligned.
  static const double _countWidth = 64;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final frameCount = filter.frameCountOverride ?? globalFrameCount;
    final exposure = filter.calibratedExposure;
    final adu = filter.currentAdu;
    final facts = [
      if (exposure != null) '${exposure.toStringAsFixed(2)} s',
      if (adu != null) '${adu.toStringAsFixed(0)} ADU',
    ].join(' · ');
    final tone = _tone(filter.status);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: colors.border))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
        child: Row(
          children: [
            SizedBox(
              width: _nameWidth,
              child: Text(
                filter.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.bodyStrong
                    .copyWith(color: colors.textPrimary),
              ),
            ),
            Expanded(
              child: Text(
                facts,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
              ),
            ),
            // A filter that has not started carries no chip: a column of
            // "Pending" says nothing the counts do not.
            if (filter.status != FilterCalibrationStatus.pending)
              SkotiqChip(
                label: flatFilterStatusLabel(filter.status),
                tone: tone,
                dot: filter.status == FilterCalibrationStatus.capturing ||
                    filter.status == FilterCalibrationStatus.calibrating,
              ),
            SizedBox(
              width: _countWidth,
              child: Text(
                '${filter.capturedCount} / $frameCount',
                textAlign: TextAlign.right,
                style: SkotiqTypography.readoutSm.copyWith(
                  color: filter.capturedCount > 0
                      ? colors.textPrimary
                      : colors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static ChipTone _tone(FilterCalibrationStatus status) => switch (status) {
        FilterCalibrationStatus.pending ||
        FilterCalibrationStatus.skipped =>
          ChipTone.neutral,
        FilterCalibrationStatus.calibrating ||
        FilterCalibrationStatus.partial =>
          ChipTone.warning,
        FilterCalibrationStatus.calibrated ||
        FilterCalibrationStatus.capturing ||
        FilterCalibrationStatus.complete =>
          ChipTone.success,
        FilterCalibrationStatus.failed => ChipTone.error,
      };
}

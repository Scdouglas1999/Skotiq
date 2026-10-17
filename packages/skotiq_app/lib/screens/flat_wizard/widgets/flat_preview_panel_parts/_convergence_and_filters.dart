// ADU convergence graph and per-filter progress cards.
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

    // The section title above already says "Convergence", so the panel does
    // not repeat it as a head. An empty history is the one empty-state
    // pattern, not a bare "No data" centred in a box.
    return Padding(
      padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
      child: SkotiqPanel(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        // Scroll-safe like the frame's own placeholder: the phone controls
        // sheet animates in, and a mid-animation frame hands this panel a
        // 71px slot that the empty state cannot fit.
        child: history.isEmpty
            ? const SingleChildScrollView(
                child: Center(
                  child: EmptyState.compact(
                    icon: LucideIcons.lineChart,
                    title: 'No measurements yet',
                    body: 'Each captured flat plots its ADU against '
                        'the target.',
                  ),
                ),
              )
            : _buildChart(colors),
      ),
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
          bottomTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              interval: (maxY - minY) / 2,
              getTitlesWidget: (value, meta) => Text(
                '${(value / 1000).toStringAsFixed(0)}k',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize8,
                    color: colors.textMuted),
              ),
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
                    TextStyle(
                        fontSize: SkotiqTypography.fontSize10,
                        color: colors.textPrimary),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}

/// Per-filter progress along the bottom of the panel.
///
/// The row scrolls horizontally, but a bare horizontal `ListView` on desktop
/// shows no scrollbar and does not follow the run: with seven profile filters
/// the row was cut off after the fourth, and the filter actually being captured
/// (Ha, with live counts) sat off-screen with nothing on screen to suggest more
/// cards existed. The scrollbar says the row is scrollable; the auto-scroll
/// keeps the card that is doing something in view.
class _FilterProgressCards extends StatefulWidget {
  final FlatWizardState state;

  const _FilterProgressCards({required this.state});

  @override
  State<_FilterProgressCards> createState() => _FilterProgressCardsState();
}

class _FilterProgressCardsState extends State<_FilterProgressCards> {
  /// Card width plus its right margin — see [_FilterCard].
  static const double _cardExtent = 108;

  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<FlatFilterSettings> get _enabled =>
      widget.state.filterSettings.where((f) => f.enabled).toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _followActive());
  }

  @override
  void didUpdateWidget(covariant _FilterProgressCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _followActive());
  }

  void _followActive() {
    if (!mounted || !_controller.hasClients) return;
    final index = _enabled
        .indexWhere((f) => f.status == FilterCalibrationStatus.capturing);
    if (index < 0) return;

    final position = _controller.position;
    final start = index * _cardExtent;
    final end = start + _cardExtent;
    final visibleStart = position.pixels;
    final visibleEnd = visibleStart + position.viewportDimension;
    if (start >= visibleStart && end <= visibleEnd) return;

    final target =
        (start > visibleStart ? end - position.viewportDimension : start)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return;
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabledFilters = _enabled;

    return Container(
      margin: const EdgeInsets.only(left: 8),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 10),
          itemCount: enabledFilters.length,
          itemBuilder: (context, index) {
            final filter = enabledFilters[index];
            return _FilterCard(
              filter: filter,
              globalFrameCount: widget.state.globalSettings.frameCount,
            );
          },
        ),
      ),
    );
  }
}

class _FilterCard extends StatelessWidget {
  final FlatFilterSettings filter;
  final int globalFrameCount;

  const _FilterCard({
    required this.filter,
    required this.globalFrameCount,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final frameCount = filter.frameCountOverride ?? globalFrameCount;
    final progress = frameCount > 0 ? filter.capturedCount / frameCount : 0.0;

    return Container(
      width: 100,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color: filter.status == FilterCalibrationStatus.capturing
              ? colors.primary
              : colors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            filter.filterName,
            style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
          ),
          const Spacer(),
          Text(
            filter.calibratedExposure != null
                ? '${filter.calibratedExposure!.toStringAsFixed(2)}s'
                : 'Not calibrated',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          SkotiqProgressBar(
            value: progress,
            height: 4,
          ),
          const SizedBox(height: 2),
          Text(
            '${filter.capturedCount}/$frameCount',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

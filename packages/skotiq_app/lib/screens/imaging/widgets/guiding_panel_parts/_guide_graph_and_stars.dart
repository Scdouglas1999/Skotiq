// Compact guiding graph, guide-star list and stat widgets.
part of '../guiding_panel.dart';

/// Compact guiding graph widget for the imaging screen overview panel.
/// Displays real RA/Dec error data from guideGraphProvider, or a
/// empty-state message when no guide data is available.
class CompactGuidingGraph extends StatelessWidget {
  final SkotiqColors colors;
  final List<GuideGraphPoint> data;
  final bool isGuiding;
  final bool isConnected;

  const CompactGuidingGraph({
    super.key,
    required this.colors,
    required this.data,
    required this.isGuiding,
    required this.isConnected,
  });

  /// The vertical range, in guide-camera pixels: PHD2 reports raw distances
  /// and no pixel scale reaches this panel, so they cannot be arcseconds.
  static const double range = 4;

  /// How many of the newest samples the panel shows.
  static const int window = 100;

  @override
  Widget build(BuildContext context) {
    final recent =
        data.length > window ? data.sublist(data.length - window) : data;
    final newest = recent.isEmpty ? null : recent.last.time;
    List<Offset> trace(double Function(GuideGraphPoint) error) => <Offset>[
          for (final point in recent)
            Offset(
              -newest!.difference(point.time).inMilliseconds / 1000.0,
              error(point).clamp(-range, range),
            ),
        ];

    return Container(
      height: 120,
      padding: const EdgeInsets.fromLTRB(6, 6, 8, 4),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: SkotiqChart(
        semanticLabel: 'Guide error, last ${recent.length} steps, '
            '±${range.round()} px full scale',
        dense: true,
        legend: true,
        series: <ChartSeries>[
          if (recent.isNotEmpty) ...<ChartSeries>[
            ChartSeries(
              points: trace((p) => p.ra),
              label: 'RA',
              color: SkotiqChartColors.seriesRed,
            ),
            ChartSeries(
              points: trace((p) => p.dec),
              label: 'Dec',
              color: SkotiqChartColors.seriesBlue,
            ),
          ],
        ],
        x: const ChartAxis(kind: ChartAxisKind.elapsed, max: 0, maxTicks: 4),
        y: const ChartAxis(
          min: -range,
          max: range,
          ticks: <double>[-range, 0, range],
          unit: ' px',
        ),
        rules: const <ChartRule>[ChartRule.y(0, dashed: false)],
        emptyText: isGuiding
            ? 'Waiting for guide data...'
            : isConnected
                ? 'Ready to guide'
                : 'No guide data',
      ),
    );
  }
}

/// Per-star tracked-star list for the built-in multi-star guider.
///
/// The internal guider tracks up to 8 reference stars; this surfaces each
/// star's SNR, lock highlight, and per-star residual so the panel is no longer
/// empty when the built-in guider is active. Driven by [guideStarsProvider],
/// which rides the same guiding status path that feeds [CompactGuidingGraph]
/// above. Renders an honest empty-state (not an error) when no stars are
/// tracked yet — e.g. before looping starts.
class GuideStarList extends ConsumerWidget {
  final SkotiqColors colors;

  const GuideStarList({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stars = ref.watch(guideStarsProvider);

    return PanelSection(
      title: 'Tracked Stars (${stars.length})',
      colors: colors,
      child: stars.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(SkotiqIcons.star, size: 14, color: colors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No stars tracked yet',
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      const SizedBox(width: 18),
                      Expanded(
                        flex: 3,
                        child: Text('Star', style: _headerStyle(colors)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text('SNR',
                            textAlign: TextAlign.end,
                            style: _headerStyle(colors)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text('Resid',
                            textAlign: TextAlign.end,
                            style: _headerStyle(colors)),
                      ),
                    ],
                  ),
                ),
                for (final star in stars)
                  _GuideStarRow(star: star, colors: colors),
              ],
            ),
    );
  }

  static TextStyle _headerStyle(SkotiqColors colors) => SkotiqTypography.caption
      .copyWith(fontWeight: FontWeight.w600, color: colors.textMuted);
}

class _GuideStarRow extends StatelessWidget {
  final GuideStar star;
  final SkotiqColors colors;

  const _GuideStarRow({required this.star, required this.colors});

  @override
  Widget build(BuildContext context) {
    final valueStyle =
        SkotiqTypography.caption.copyWith(color: colors.textPrimary);
    final residual = star.residual;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Lock indicator: the active lock star gets a filled accent dot, the
          // rest a hollow muted marker so the lock star reads at a glance.
          SizedBox(
            width: 18,
            child: Icon(
              star.isLock ? SkotiqIcons.crosshair : LucideIcons.circle,
              size: 12,
              color: star.isLock ? colors.primary : colors.textMuted,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              star.isLock
                  ? 'Star ${star.id + 1} (lock)'
                  : 'Star ${star.id + 1}',
              style: valueStyle.copyWith(
                color: star.isLock ? colors.primary : colors.textPrimary,
                fontWeight: star.isLock ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              star.snr.toStringAsFixed(1),
              textAlign: TextAlign.end,
              style: valueStyle,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              residual == null ? '—' : '${residual.toStringAsFixed(2)}px',
              textAlign: TextAlign.end,
              style: valueStyle.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class GuideStat extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const GuideStat({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

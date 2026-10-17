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

  @override
  Widget build(BuildContext context) {
    final hasData = data.isNotEmpty;

    return Container(
      height: 120,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Stack(
        children: [
          // Draw the real graph when we have data
          if (hasData)
            Positioned.fill(
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline9),
                child: CustomPaint(
                  painter: _CompactGuidingGraphPainter(
                    data: data,
                    colors: colors,
                  ),
                ),
              ),
            ),
          // Show empty state when no data
          if (!hasData)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isGuiding
                        ? SkotiqIcons.activity
                        : SkotiqIcons.crosshair,
                    size: 24,
                    color: isGuiding ? colors.success : colors.textMuted,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isGuiding
                        ? 'Waiting for guide data...'
                        : isConnected
                            ? 'Ready to guide'
                            : 'No guide data',
                    style: SkotiqTypography.caption.copyWith(
                        color: isGuiding ? colors.success : colors.textMuted),
                  ),
                ],
              ),
            ),
          // Legend (always visible)
          Positioned(
            bottom: 8,
            left: 8,
            child: Row(
              children: [
                Container(
                    width: 12,
                    height: 2,
                    color: SkotiqChartColors.forTheme(
                        SkotiqChartColors.seriesRed, colors)),
                const SizedBox(width: 4),
                Text('RA',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted)),
                const SizedBox(width: 12),
                Container(
                    width: 12,
                    height: 2,
                    color: SkotiqChartColors.forTheme(
                        SkotiqChartColors.seriesBlue, colors)),
                const SizedBox(width: 4),
                Text('Dec',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// CustomPainter that renders real RA/Dec guide error data.
/// Matches the rendering approach from the guiding_tab.dart _GraphPainter
/// but is simplified for the compact 120px overview panel.
class _CompactGuidingGraphPainter extends CustomPainter {
  final List<GuideGraphPoint> data;
  final SkotiqColors colors;

  _CompactGuidingGraphPainter({
    required this.data,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;

    // Draw center zero-line
    final zeroPaint = Paint()
      ..color = colors.textMuted.withValues(alpha: 0.3)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), zeroPaint);

    if (data.isEmpty) return;

    final raPaint = Paint()
      ..color = SkotiqChartColors.forTheme(
              SkotiqChartColors.seriesRed, colors)
          .withValues(alpha: 0.8)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final decPaint = Paint()
      ..color = SkotiqChartColors.forTheme(
              SkotiqChartColors.seriesBlue, colors)
          .withValues(alpha: 0.8)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Scale: +/- 4 arcsec range (same as the full guiding graph)
    const range = 4.0;
    final scaleY = size.height / (range * 2);
    // Show last 100 points spread across the width
    final stepX = size.width / 100;

    final raPath = Path();
    final decPath = Path();

    for (int i = 0; i < data.length; i++) {
      final point = data[i];
      final x = size.width - ((data.length - 1 - i) * stepX);

      if (x < 0) continue;

      final raY = centerY - (point.ra.clamp(-range, range) * scaleY);
      final decY = centerY - (point.dec.clamp(-range, range) * scaleY);

      if (i == 0 || x < stepX) {
        raPath.moveTo(x, raY);
        decPath.moveTo(x, decY);
      } else {
        raPath.lineTo(x, raY);
        decPath.lineTo(x, decY);
      }
    }

    canvas.drawPath(raPath, raPaint);
    canvas.drawPath(decPath, decPaint);
  }

  @override
  bool shouldRepaint(covariant _CompactGuidingGraphPainter oldDelegate) {
    return oldDelegate.data != data;
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
                // Column header.
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

  static TextStyle _headerStyle(SkotiqColors colors) =>
      SkotiqTypography.caption
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
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

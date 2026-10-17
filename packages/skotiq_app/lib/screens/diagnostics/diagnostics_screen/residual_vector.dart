part of '../diagnostics_screen.dart';

class _ResidualVectorCard extends StatelessWidget {
  final List<AstrometryResidualVectorRow> residuals;
  final SkotiqColors colors;

  const _ResidualVectorCard({required this.residuals, required this.colors});

  @override
  Widget build(BuildContext context) {
    return _DiagCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.wind, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                'Astrometric Residuals',
                style: SkotiqTypography.h5.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '${residuals.length} vectors',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (residuals.isEmpty)
            // Match the PSF card's empty state so two adjacent diagnostics
            // cards never disagree on icon+title+body styling.
            const EmptyState(
              icon: LucideIcons.wind,
              title: 'No astrometric residual data for this session.',
              body: 'Capture plate-solved frames to generate residual vectors.',
            )
          else
            AspectRatio(
              aspectRatio: 1.5,
              child: CustomPaint(
                painter: _ResidualVectorPainter(
                  residuals: residuals,
                  vectorColor: colors.primary,
                  gridColor: colors.border,
                  bgColor: colors.surfaceAlt,
                ),
              ),
            ),
          if (residuals.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ResidualStats(residuals: residuals, colors: colors),
          ],
        ],
      ),
    );
  }
}

class _ResidualStats extends StatelessWidget {
  final List<AstrometryResidualVectorRow> residuals;
  final SkotiqColors colors;

  const _ResidualStats({required this.residuals, required this.colors});

  @override
  Widget build(BuildContext context) {
    final magnitudes = residuals.map((r) => r.magnitudeArcsec).toList();
    final mean = magnitudes.reduce((a, b) => a + b) / magnitudes.length;
    final maxMag = magnitudes.reduce(math.max);
    final minMag = magnitudes.reduce(math.min);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _StatChip(
          label: context.l10n.text('diagnosticsMean'),
          value: '${mean.toStringAsFixed(2)}"',
          colors: colors,
        ),
        _StatChip(
          label: context.l10n.text('diagnosticsMin'),
          value: '${minMag.toStringAsFixed(2)}"',
          colors: colors,
        ),
        _StatChip(
          label: context.l10n.text('diagnosticsMax'),
          value: '${maxMag.toStringAsFixed(2)}"',
          colors: colors,
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const _StatChip({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: SkotiqTypography.labelStrong.copyWith(
            color: colors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _ResidualVectorPainter extends CustomPainter {
  final List<AstrometryResidualVectorRow> residuals;
  final Color vectorColor;
  final Color gridColor;
  final Color bgColor;

  _ResidualVectorPainter({
    required this.residuals,
    required this.vectorColor,
    required this.gridColor,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (residuals.isEmpty) return;

    // Background
    final bgPaint = Paint()..color = bgColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(SkotiqTokens.radiusXs),
      ),
      bgPaint,
    );

    // Grid lines
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.3)
      ..strokeWidth = 0.5;
    for (int i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (int i = 1; i < 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Find max magnitude for scaling vectors
    final maxMag = residuals
        .map((r) => r.magnitudeArcsec)
        .reduce(math.max)
        .clamp(0.1, double.infinity);
    final scaleFactor = math.min(size.width, size.height) * 0.08 / maxMag;

    final vectorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    for (final r in residuals) {
      // x, y are 0-1 normalized field positions
      final px = r.x * size.width;
      final py = r.y * size.height;
      final dx = r.dxArcsec * scaleFactor;
      final dy = r.dyArcsec * scaleFactor;

      // Color by magnitude: green for small, red for large
      final normalizedMag = (r.magnitudeArcsec / maxMag).clamp(0.0, 1.0);
      final color = Color.lerp(
        vectorColor,
        vectorColor.withValues(alpha: 0.3),
        1.0 - normalizedMag,
      )!;
      vectorPaint.color = color;

      // Draw dot at position
      final dotPaint = Paint()
        ..color = vectorColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(px, py), 2, dotPaint);

      // Draw vector arrow
      canvas.drawLine(Offset(px, py), Offset(px + dx, py + dy), vectorPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ResidualVectorPainter old) =>
      residuals != old.residuals;
}

// Issues card

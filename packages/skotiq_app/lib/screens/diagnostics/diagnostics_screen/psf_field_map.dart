part of '../diagnostics_screen.dart';

class _PsfFieldMapCard extends StatelessWidget {
  final List<PsfFieldTileRow> psfTiles;
  final SkotiqColors colors;

  const _PsfFieldMapCard({required this.psfTiles, required this.colors});

  @override
  Widget build(BuildContext context) {
    return _DiagCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.grid, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                'PSF Field Map',
                style: SkotiqTypography.h5.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '${psfTiles.length} tiles',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (psfTiles.isEmpty)
            // Shared EmptyState keeps diagnostics placeholders visually aligned
            // with the science analytics tabs that already use icon+title+body.
            const EmptyState(
              icon: LucideIcons.grid,
              title: 'No PSF field tile data for this session.',
              body: 'Capture plate-solved frames to generate PSF maps.',
            )
          else
            AspectRatio(
              aspectRatio: 1.5,
              // Reuses the shared, public PsfFieldMapView painter (also embedded
              // in the Morning Report workbench at per-sub granularity).
              child: PsfFieldMapView(tiles: psfTiles),
            ),
          if (psfTiles.isNotEmpty) ...[
            const SizedBox(height: 8),
            // Color legend
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LegendDot(
                  color: colors.success,
                  label: context.l10n.text('diagnosticsLowHfr'),
                ),
                const SizedBox(width: 16),
                _LegendDot(
                  color: colors.warning,
                  label: context.l10n.text('diagnosticsMedium'),
                ),
                const SizedBox(width: 16),
                _LegendDot(
                  color: colors.error,
                  label: context.l10n.text('diagnosticsHighHfr'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }
}

// Residual vector card

part of '../catalog_overlay_widget.dart';

/// Side panel that shows full catalog details for the selected object.
/// Driven by `selectedCatalogOverlayObjectProvider` — the preview wraps
/// this in a `Visibility` or `AnimatedSlide` of its own choosing.
class CatalogOverlayDetailsPanel extends ConsumerWidget {
  final SkotiqColors colors;
  final double width;
  const CatalogOverlayDetailsPanel({
    super.key,
    required this.colors,
    this.width = 320,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final object = ref.watch(selectedCatalogOverlayObjectProvider);
    if (object == null) return const SizedBox.shrink();

    final panelWidth = clampPanelWidth(
      MediaQuery.sizeOf(context).width,
      fraction: 0.28,
      min: 200,
      max: width,
    );

    return Container(
      width: panelWidth,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    object.displayName,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(LucideIcons.x, size: 18),
                  color: colors.textMuted,
                  tooltip: 'Close',
                  onPressed: () => ref
                      .read(selectedCatalogOverlayObjectProvider.notifier)
                      .state = null,
                ),
              ],
            ),
            if (object.id != object.displayName)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  object.id,
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            _row(colors, 'Catalog', object.source),
            _row(colors, 'Type', _kindName(object.kind)),
            _row(colors, 'RA', _formatRA(object.raHours)),
            _row(colors, 'Dec', _formatDec(object.decDegrees)),
            if (object.magnitude != null)
              _row(colors, 'Magnitude', object.magnitude!.toStringAsFixed(2)),
            if (object.sizeArcMin != null)
              _row(colors, 'Size',
                  "${object.sizeArcMin!.toStringAsFixed(2)} arcmin"),
            if (object.alternateIds != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Alternate identifiers',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      object.alternateIds!,
                      style: TextStyle(color: colors.textPrimary, fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(SkotiqColors colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _kindName(CatalogOverlayKind kind) {
    switch (kind) {
      case CatalogOverlayKind.star:
        return 'Star';
      case CatalogOverlayKind.galaxy:
        return 'Galaxy';
      case CatalogOverlayKind.openCluster:
        return 'Open cluster';
      case CatalogOverlayKind.globularCluster:
        return 'Globular cluster';
      case CatalogOverlayKind.nebula:
        return 'Nebula';
      case CatalogOverlayKind.planetaryNebula:
        return 'Planetary nebula';
      case CatalogOverlayKind.supernovaRemnant:
        return 'Supernova remnant';
      case CatalogOverlayKind.other:
        return 'Other';
    }
  }

  static String _formatRA(double raHours) =>
      CoordinateFormat.ra(raHours, seconds: SecondsPrecision.oneDecimalPadded);

  static String _formatDec(double decDeg) => CoordinateFormat.dec(decDeg);
}

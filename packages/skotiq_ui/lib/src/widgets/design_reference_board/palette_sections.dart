part of '../design_reference_board.dart';

class _SemanticPaletteSection extends StatelessWidget {
  const _SemanticPaletteSection({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final swatches = <(String, Color)>[
      ('Primary', colors.primary),
      ('Accent', colors.accent),
      ('Background', colors.background),
      ('Surface', colors.surface),
      ('Surface Alt', colors.surfaceAlt),
      ('Surface Hover', colors.surfaceHover),
      ('Surface Elevated', colors.surfaceElevated),
      ('Surface Overlay', colors.surfaceOverlay),
      ('Border', colors.border),
      ('Border Highlight', colors.borderHighlight),
      ('Text Primary', colors.textPrimary),
      ('Text Secondary', colors.textSecondary),
      ('Text Muted', colors.textMuted),
      ('Success', colors.success),
      ('Warning', colors.warning),
      ('Error', colors.error),
      ('Info', colors.info),
    ];
    return ShowcaseSection.boxed(
      title: 'Semantic palette',
      child: Wrap(
        spacing: SkotiqTokens.spaceMd,
        runSpacing: SkotiqTokens.spaceMd,
        children: [
          for (final swatch in swatches)
            ShowcaseSwatch.board(
              label: swatch.$1,
              color: swatch.$2,
              frame: colors,
            ),
        ],
      ),
    );
  }
}

// Domain palettes (chart series + gradients, annotation types, backends)

class _DomainPaletteSection extends StatelessWidget {
  const _DomainPaletteSection({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return ShowcaseSection.boxed(
      title: 'Domain palettes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SubLabel('Chart series', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const Wrap(
            spacing: SkotiqTokens.spaceMd,
            runSpacing: SkotiqTokens.spaceMd,
            children: [
              ShowcaseSwatch.boardCompact(
                label: 'Blue',
                color: SkotiqChartColors.seriesBlue,
              ),
              ShowcaseSwatch.boardCompact(
                label: 'Violet',
                color: SkotiqChartColors.seriesViolet,
              ),
              ShowcaseSwatch.boardCompact(
                label: 'Green',
                color: SkotiqChartColors.seriesGreen,
              ),
              ShowcaseSwatch.boardCompact(
                label: 'Amber',
                color: SkotiqChartColors.seriesAmber,
              ),
              ShowcaseSwatch.boardCompact(
                label: 'Indigo',
                color: SkotiqChartColors.seriesIndigo,
              ),
              ShowcaseSwatch.boardCompact(
                label: 'Deep Blue',
                color: SkotiqChartColors.seriesDeepBlue,
              ),
              ShowcaseSwatch.boardCompact(
                label: 'Red',
                color: SkotiqChartColors.seriesRed,
              ),
              ShowcaseSwatch.boardCompact(
                label: 'Orange',
                color: SkotiqChartColors.seriesOrange,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Data-viz gradients', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _GradientBar(
            label: 'PSF (tight → bloated)',
            stops: SkotiqChartColors.psfGradient,
            colors: colors,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _GradientBar(
            label: 'Uniformity',
            stops: SkotiqChartColors.uniformityGradient,
            colors: colors,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _GradientBar(
            label: 'Clip-high',
            stops: SkotiqChartColors.clipHighGradient,
            colors: colors,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _GradientBar(
            label: 'Clip-low',
            stops: SkotiqChartColors.clipLowGradient,
            colors: colors,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Annotation object types', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              for (final (label, color) in _objectTypeSamples)
                _DotChip(label: label, color: color, colors: colors),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _SubLabel('Driver backends', colors: colors),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              for (final (label, color) in _backendSamples(colors))
                _DotChip(label: label, color: color, colors: colors),
            ],
          ),
        ],
      ),
    );
  }

  // Sample domain hues. The app owns the real mappings (it knows the object
  // and driver types); the board only shows how such hues sit on the palette.
  static const _objectTypeSamples = <(String, Color)>[
    ('Galaxy', CatalogAnnotationColors.galaxy),
    ('Nebula', CatalogAnnotationColors.nebula),
    ('Star Cluster', CatalogAnnotationColors.starCluster),
    ('Planetary Nebula', CatalogAnnotationColors.planetaryNebula),
    ('Star', CatalogAnnotationColors.star),
    ('Double Star', CatalogAnnotationColors.doubleStar),
    ('Asterism', CatalogAnnotationColors.asterism),
  ];

  static List<(String, Color)> _backendSamples(SkotiqColors colors) => [
    ('Native SDK', colors.success),
    ('ASCOM', colors.info),
    ('Alpaca', colors.warning),
    ('INDI', DriverBackendColors.indi),
    ('Simulator', colors.textMuted),
  ];
}

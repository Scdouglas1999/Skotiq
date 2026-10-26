import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Per-overlay explainer dialog and legend strip.
///
/// Implements P2.2 of the science gap list — every science overlay now has
/// a discoverable explanation of what the colors mean and what action they
/// suggest. Used by both the Imaging HUD overlay chips and the Analytics
/// Overlay Composer.
class ScienceOverlayLegend {
  static const _entries = <String, _LegendEntry>{
    'psf': _LegendEntry(
      label: 'PSF heatmap',
      icon: LucideIcons.layoutGrid,
      summary:
          'Median FWHM per tile. Green tiles = tight stars; red = bloated or elongated.',
      readMoreId: 'PSF Field Map',
      gradientStops: ['Tight', 'Average', 'Bloated'],
      gradientColors: SkotiqChartColors.psfGradient,
    ),
    'uniformity': _LegendEntry(
      label: 'Uniformity',
      icon: LucideIcons.boxSelect,
      summary:
          'Background brightness CV per tile. Flat is good; gradients warn of vignetting or moonglow.',
      gradientStops: ['Flat', 'Mild', 'Strong'],
      gradientColors: SkotiqChartColors.uniformityGradient,
    ),
    'clip_high': _LegendEntry(
      label: 'Clip high',
      icon: LucideIcons.arrowUpRightSquare,
      summary:
          'Tiles where pixels saturate. Red regions are losing highlight detail — drop exposure or gain.',
      gradientStops: ['Safe', 'Some clip', 'Saturated'],
      gradientColors: SkotiqChartColors.clipHighGradient,
    ),
    'clip_low': _LegendEntry(
      label: 'Clip low',
      icon: LucideIcons.arrowDownLeftSquare,
      summary:
          'Tiles where pixels hit the noise floor. Blue regions show lost shadow signal — increase exposure.',
      gradientStops: ['Safe', 'Some clip', 'Floor'],
      gradientColors: SkotiqChartColors.clipLowGradient,
    ),
    'residuals': _LegendEntry(
      label: 'Astrometric residuals',
      icon: LucideIcons.move,
      summary:
          'Each arrow points from a star to where the catalog and the solve place it. A pattern that grows toward the edges is optical distortion.',
      readMoreId: 'Astrometric Residuals',
    ),
    'moving': _LegendEntry(
      label: 'Moving object tracks',
      icon: LucideIcons.rocket,
      summary:
          'Multi-frame trails of detected moving candidates. Confidence is encoded in opacity.',
      readMoreId: 'Moving Object Candidates',
    ),
    'fwhm': _LegendEntry(
      label: 'FWHM surface',
      icon: LucideIcons.layoutTemplate,
      summary:
          '3D surface of FWHM across the field. A flat plane = even focus. A tilted plane = tilt.',
      readMoreId: 'PSF Field Map',
    ),
  };

  /// Show the legend dialog for a single overlay key. `key` must match one of
  /// the entries declared above; unknown keys silently no-op.
  static void show(BuildContext context, String key) {
    final entry = _entries[key];
    if (entry == null) return;
    final colors = SkotiqColors.of(context);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
          side: BorderSide(color: colors.borderHighlight),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: SkotiqDecorations.chip(colors, tone: colors.primary),
              child: Icon(entry.icon, color: colors.primary, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                entry.label,
                style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 480,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                entry.summary,
                style: SkotiqTypography.bodySm
                    .copyWith(color: colors.textSecondary, height: 1.5),
              ),
              if (entry.gradientStops != null &&
                  entry.gradientColors != null) ...[
                const SizedBox(height: 16),
                _GradientRow(
                  stops: entry.gradientStops!,
                  swatches: entry.gradientColors!,
                  colors: colors,
                ),
              ],
            ],
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.of(context).pop(),
            label: 'Got it',
            variant: ButtonVariant.ghost,
          ),
        ],
      ),
    );
  }

  /// Inline legend strip — three swatches with labels. Renders nothing for
  /// overlays without a defined gradient.
  static Widget inlineFor(BuildContext context, String key) {
    final entry = _entries[key];
    if (entry == null ||
        entry.gradientColors == null ||
        entry.gradientStops == null) {
      return const SizedBox.shrink();
    }
    final colors = SkotiqColors.of(context);
    return _GradientRow(
      stops: entry.gradientStops!,
      swatches: entry.gradientColors!,
      colors: colors,
      compact: true,
    );
  }
}

class _LegendEntry {
  final String label;
  final IconData icon;
  final String summary;

  /// Key into the analytics tab's `_kScienceInfoContent` map for a deeper
  /// "what is this?" panel. Used today only by the analytics tab itself.
  final String? readMoreId;

  /// Three-stop colour ramp for swatch displays. When null, no inline swatch
  /// is rendered.
  final List<Color>? gradientColors;
  final List<String>? gradientStops;

  const _LegendEntry({
    required this.label,
    required this.icon,
    required this.summary,
    this.readMoreId,
    this.gradientColors,
    this.gradientStops,
  });
}

class _GradientRow extends StatelessWidget {
  final List<Color> swatches;
  final List<String> stops;
  final SkotiqColors colors;
  final bool compact;

  const _GradientRow({
    required this.swatches,
    required this.stops,
    required this.colors,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final swatchSize = compact ? 10.0 : 14.0;
    // The entries above name the ramp as fixed [SkotiqChartColors]
    // constants; this is where it becomes a painted colour. Red night is a
    // WAVELENGTH constraint, so drawing `seriesGreen` raw put a solid green
    // swatch on a red-night screen — and this strip sits inline on the Imaging
    // HUD, not just in a dialog the user opened on purpose.
    final resolved = swatches
        .map((c) => SkotiqChartColors.forTheme(c, colors))
        .toList(growable: false);
    final children = <Widget>[];
    for (var i = 0; i < resolved.length; i++) {
      children.add(
        Container(
          width: swatchSize,
          height: swatchSize,
          decoration: BoxDecoration(
            color: resolved[i],
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            border: Border.all(color: colors.border, width: 0.5),
          ),
        ),
      );
      children.add(const SizedBox(width: 4));
      children.add(
        Text(
          stops[i],
          // 03 §2: 10 and 11 are not sizes. A legend stop is a caption in
          // both the compact and the full legend.
          style: SkotiqTypography.caption.copyWith(
            color: colors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
      if (i != resolved.length - 1) {
        children.add(const SizedBox(width: 10));
      }
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

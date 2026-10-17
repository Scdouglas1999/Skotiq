import 'package:flutter/material.dart';

import '_design_showcase_primitives.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' show ObjectType, DriverType;

import '../components/skotiq_alert.dart';
import '../components/skotiq_button.dart';
import '../components/skotiq_card.dart';
import '../components/skotiq_checkbox.dart';
import '../components/skotiq_progress_bar.dart';
import '../components/skotiq_switch.dart';
import '../components/skotiq_text_field.dart';
import '../components/screen_header.dart';
import '../components/status_dot.dart';
import '../components/status_pill.dart';
import '../components/sub_tab_button.dart';
import '../theme/annotation_type_colors.dart';
import '../theme/backend_protocol_colors.dart';
import '../theme/skotiq_chart_colors.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

part 'design_reference_board/palette_sections.dart';
part 'design_reference_board/typography_section.dart';
part 'design_reference_board/component_sections.dart';
part 'design_reference_board/board_primitives.dart';

/// A single, fully-static reference board that renders the entire Skotiq
/// design language on one canvas: the semantic palette, the chart / annotation /
/// backend domain palettes, the complete named typography scale (every style
/// labelled with its name + spec), and a representative pass over the component
/// library (cards, buttons, inputs, pills, dots, progress, alerts, headers).
///
/// Unlike [SkotiqDesignSystemGallery] this board is intentionally
/// stateless and interaction-free so it produces a deterministic frame — it is
/// the source widget for the committed golden-screenshot reference images under
/// `docs/design/goldens/`. Render it inside a themed [MaterialApp] and the whole
/// board re-skins from the active [SkotiqColors] extension, so the same
/// widget yields the light/dark board and the red-night board.
class SkotiqDesignReferenceBoard extends StatelessWidget {
  const SkotiqDesignReferenceBoard({super.key, this.themeLabel});

  /// Human label for the theme this board is rendered under (e.g. "Dark",
  /// "Red Night"). Shown in the board header so a captured PNG is
  /// self-identifying.
  final String? themeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Material(
      color: colors.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(SkotiqTokens.space2xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1320),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _boardHeader(colors),
                const SizedBox(height: SkotiqTokens.space2xl),
                _twoColumn(
                  left: _SemanticPaletteSection(colors: colors),
                  right: _DomainPaletteSection(colors: colors),
                ),
                const SizedBox(height: SkotiqTokens.space2xl),
                ShowcaseSection.boxed(
                  title: 'Typography scale',
                  child: _TypographyScale(colors: colors),
                ),
                const SizedBox(height: SkotiqTokens.space2xl),
                _twoColumn(
                  left: _ComponentsSection(colors: colors),
                  right: _StatusAndFeedbackSection(colors: colors),
                ),
                const SizedBox(height: SkotiqTokens.space2xl),
                ShowcaseSection.boxed(
                  title: 'Layout primitives',
                  child: _LayoutPrimitivesSection(colors: colors),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _boardHeader(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'Skotiq Design Language',
              style: SkotiqTypography.h1.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            if (themeLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SkotiqTokens.spaceMd,
                    vertical: SkotiqTokens.spaceXs,
                  ),
                  decoration: SkotiqDecorations.emphasisSurface(
                    colors.primary,
                    borderRadius: SkotiqTokens.borderRadiusSm,
                  ),
                  child: Text(
                    themeLabel!.toUpperCase(),
                    style: SkotiqTypography.overline.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'Precision-instrument visual baseline — semantic palette, domain '
          'colors, full type scale, and the component library on one canvas.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }

  Widget _twoColumn({required Widget left, required Widget right}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 880) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              left,
              const SizedBox(height: SkotiqTokens.space2xl),
              right,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: SkotiqTokens.space2xl),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

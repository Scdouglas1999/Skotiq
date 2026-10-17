/// Building blocks shared by the two design-showcase surfaces:
/// `design_reference_board.dart` (the deterministic golden canvas) and
/// `design_system_gallery.dart` (the interactive QA gallery). They rendered the
/// same two things — a titled section and a colour swatch — from two
/// independent copies that had already drifted apart.
///
/// Deliberately NOT exported from `skotiq_ui.dart`: these are showcase
/// chrome, not shipping components, and nothing outside those two files should
/// reach for them. Each variant reproduces its original rendering exactly, so
/// the committed golden PNGs are unchanged.
library;

import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// A titled block of specimens.
class ShowcaseSection extends StatelessWidget {
  /// Gallery form: an `h4` heading over bare content, with trailing space.
  const ShowcaseSection.plain({
    super.key,
    required this.title,
    required this.child,
  }) : boxed = false;

  /// Reference-board form: an overline label over a bordered surface panel.
  const ShowcaseSection.boxed({
    super.key,
    required this.title,
    required this.child,
  }) : boxed = true;

  final String title;
  final Widget child;
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: boxed
              ? SkotiqTypography.overline.copyWith(color: colors.textMuted)
              : SkotiqTypography.h4.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        if (boxed)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: SkotiqTokens.borderRadiusMd,
              border: Border.all(color: colors.border),
            ),
            child: child,
          )
        else
          child,
      ],
    );

    if (boxed) return column;
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.space2xl),
      child: column,
    );
  }
}

/// A colour chip with its name, and — on the reference board — its hex value.
class ShowcaseSwatch extends StatelessWidget {
  /// Gallery form: no hex readout, roomier label.
  const ShowcaseSwatch.gallery({
    super.key,
    required this.label,
    required this.color,
  }) : width = 112,
       swatchHeight = 44,
       showHex = false,
       denseLabel = false,
       frame = null;

  /// Reference-board form. [frame] supplies the border/text colours so a domain
  /// palette can be drawn against a theme this widget is not mounted in.
  const ShowcaseSwatch.board({
    super.key,
    required this.label,
    required this.color,
    required this.frame,
  }) : width = 116,
       swatchHeight = 44,
       showHex = true,
       denseLabel = true;

  /// Reference-board form at the tighter size used inside dense grids.
  const ShowcaseSwatch.boardCompact({
    super.key,
    required this.label,
    required this.color,
  }) : width = 92,
       swatchHeight = 34,
       showHex = true,
       denseLabel = true,
       frame = null;

  final String label;
  final Color color;
  final SkotiqColors? frame;
  final double width;
  final double swatchHeight;
  final bool showHex;
  final bool denseLabel;

  @override
  Widget build(BuildContext context) {
    final colors = frame ?? context.skotiqColors;

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: swatchHeight,
            decoration: BoxDecoration(
              color: color,
              borderRadius: SkotiqTokens.borderRadiusSm,
              border: Border.all(color: colors.border),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            label,
            style:
                (denseLabel
                        ? SkotiqTypography.captionSm
                        : SkotiqTypography.caption)
                    .copyWith(color: colors.textSecondary),
          ),
          if (showHex)
            Text(
              _hex(color),
              style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
            ),
        ],
      ),
    );
  }

  static String _hex(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

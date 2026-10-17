import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// A panel — the `surface`-toned container that every non-tappable block of
/// content sits in.
///
/// Replaces [SkotiqCard] wherever the container was never a control.
/// Depth comes from TONE, so a panel carries no visible border on the dark
/// palettes (only the 4% ring in [SkotiqDecorations.panel] so the edge
/// does not vanish on a poor monitor) and a real 1px `border` on light, where
/// white on off-white has no tone to separate with.
///
/// A panel has no hover and no `onTap`: a tappable container is a ROW or a
/// CANDIDATE, not a panel. A panel inside a panel does not exist either — the
/// deepest the ladder goes is `panel → well`.
class SkotiqPanel extends StatelessWidget {
  const SkotiqPanel({
    super.key,
    required this.child,
    this.head,
    this.padding = SkotiqTokens.paddingLg,
    this.flush = false,
    this.selected = false,
    this.dashed = false,
  });

  /// The panel's content.
  final Widget child;

  /// An optional [PanelHead] rendered above [child] with a 12px gap.
  final Widget? head;

  /// Internal padding. Ignored when [flush] is true.
  final EdgeInsets padding;

  /// Zero padding, clipped to the panel radius — for panels whose content is
  /// an image or a chart that should run to the corners.
  final bool flush;

  /// Draws the 1px `primary` ring at [SkotiqTokens.opacitySelectedRing]
  /// instead of the resting outline.
  final bool selected;

  /// An EMPTY SLOT: no fill, and a dashed 1px `borderHighlight` outline
  /// instead of the panel face (03 §1.1 gives `borderHighlight` to "dashed
  /// empty slots"; 06 Equipment's unfilled device bay is one).
  ///
  /// A dash says "something belongs here and is missing" in a way a solid
  /// outline cannot: a solid one reads as a panel that happens to be blank.
  /// Ignored when [selected] is true — a slot cannot be both empty and chosen.
  final bool dashed;

  /// The dash and gap lengths of an empty slot's outline, in logical pixels.
  static const double dashLength = 4;
  static const double dashGap = 4;

  /// The gap between a [PanelHead] and the panel body.
  static const double headGap = SkotiqTokens.spaceMd;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final decoration = selected
        ? SkotiqDecorations.panelSelected(colors)
        : SkotiqDecorations.panel(colors);

    Widget content = child;
    if (head != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          head!,
          const SizedBox(height: headGap),
          // NOT Flexible: a panel is normally laid out in a scroll view, where
          // the incoming height is unbounded and a flex child would throw.
          child,
        ],
      );
    }

    if (dashed && !selected) {
      return CustomPaint(
        painter: _DashedSlotBorder(
          color: colors.borderHighlight,
          radius: SkotiqTokens.radiusLg,
        ),
        child: Padding(
          padding: flush ? EdgeInsets.zero : padding,
          child: content,
        ),
      );
    }

    if (flush) {
      return Container(
        decoration: decoration,
        clipBehavior: Clip.antiAlias,
        child: content,
      );
    }

    return Container(decoration: decoration, padding: padding, child: content);
  }
}

/// The dashed outline of an empty slot.
///
/// Flutter has no dashed `Border`, and the alternatives are worse than 30
/// lines of painter: a dash image does not scale with the radius, and a
/// repeated child does not follow a corner.
class _DashedSlotBorder extends CustomPainter {
  const _DashedSlotBorder({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      // Inset by half the stroke so the dash sits INSIDE the slot's box, the
      // way a `Border` does; otherwise the slot is 1px larger than a filled
      // panel beside it and the grid stops lining up.
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + SkotiqPanel.dashLength, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + SkotiqPanel.dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedSlotBorder oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// The one-row label at the top of a [SkotiqPanel]:
/// `[icon 15 muted] [eyebrow] … [trailing gap 8]`, 20px tall.
///
/// The eyebrow is [SkotiqTypography.eyebrow] in `textMuted` and uppercased
/// here so call sites write the label the way it reads in prose.
class PanelHead extends StatelessWidget {
  const PanelHead({
    super.key,
    required this.label,
    this.icon,
    this.trailing = const <Widget>[],
  });

  /// The panel label. Rendered uppercase.
  final String label;

  /// Optional 15px leading icon in `textMuted`.
  final IconData? icon;

  /// Trailing widgets, laid out with an 8px gap.
  final List<Widget> trailing;

  /// The head's fixed height in logical pixels.
  static const double height = 20;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return SizedBox(
      height: height,
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: _panelHeadIconSize, color: colors.textMuted),
            const SizedBox(width: SkotiqTokens.spaceSm),
          ],
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (var i = 0; i < trailing.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: SkotiqTokens.spaceSm),
            trailing[i],
          ],
        ],
      ),
    );
  }
}

/// Icon size inside a panel head, in logical pixels (03 §6: 15–16 in panel
/// heads).
const double _panelHeadIconSize = SkotiqTokens.iconGlyphPanelHead;

import 'package:flutter/material.dart';

import 'skotiq_colors.dart';
import 'skotiq_tokens.dart';

/// Shared [BoxDecoration] helpers for the Skotiq UI.
///
/// The Observatory set is [panel], [well], [panelSelected], [railItemSelected],
/// [chip], [filterChip], [field], [popover], [dialog], [glass] and [hairline]
/// (`docs/design/overhaul/03-tokens.md` §5.2). Depth comes from TONE — the
/// `background → surface → elevated → overlay` ladder plus the deeper [well] —
/// so a panel carries no visible border on the dark palettes and lines are
/// reserved for dividers and focused controls.
///
/// Everything below the Observatory set is the pre-overhaul API, kept so the
/// screen layer compiles; each is deprecated and deleted in wave 4.
abstract final class SkotiqDecorations {
  SkotiqDecorations._();

  /// True when this palette paints dark ink on a light ground.
  ///
  /// Read off `background` rather than a flag so an accent-derived palette
  /// (which is a `copyWith` of [SkotiqColors.light] or `.dark`) answers
  /// correctly without carrying one more field.
  static bool _isLight(SkotiqColors colors) =>
      colors.background.computeLuminance() > 0.5;

  static const Color _white = Color(0xFFFFFFFF);

  // ---------------------------------------------------------------------
  // The Observatory set
  // ---------------------------------------------------------------------

  /// A panel: the standard `surface`-toned container.
  ///
  /// On the dark palettes it carries a 1px white ring at
  /// [SkotiqTokens.opacityPanelOutline] — 4%, near-invisible, there only so
  /// the edge does not vanish on a poor monitor. On light it takes a real 1px
  /// `border`, because white on off-white has no tone to separate with. Never a
  /// shadow: a panel does not float.
  static BoxDecoration panel(SkotiqColors colors) {
    return BoxDecoration(
      color: colors.surface,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      border: Border.all(
        color: _isLight(colors)
            ? colors.border
            : _white.withValues(alpha: SkotiqTokens.opacityPanelOutline),
      ),
    );
  }

  /// A well: the inset inside a panel that holds a chart, an image, an empty
  /// area or a number field.
  ///
  /// A well never nests inside another well, and a panel never nests inside a
  /// panel: `panel → well` is the deepest the ladder goes.
  static BoxDecoration well(SkotiqColors colors) {
    return BoxDecoration(
      color: colors.well,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
    );
  }

  /// A selected panel — a chosen candidate, the running step.
  ///
  /// The selection is a `primary` ring at [SkotiqTokens.opacitySelectedRing]
  /// over the panel's own fill, not a tinted background: the content stays the
  /// colour it was, so selecting something does not restate its status.
  static BoxDecoration panelSelected(SkotiqColors colors) {
    return BoxDecoration(
      color: colors.surface,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      border: Border.all(
        color: colors.primary.withValues(
          alpha: SkotiqTokens.opacitySelectedRing,
        ),
      ),
    );
  }

  /// The selected rail item, strip item or settings nav row.
  ///
  /// A 12% `primary` wash and no border. The icon and label take
  /// [SkotiqColors.primary] at the call site.
  static BoxDecoration railItemSelected(SkotiqColors colors) {
    return BoxDecoration(
      color: colors.primary.withValues(alpha: SkotiqTokens.opacityAccentTint),
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
    );
  }

  /// A chip: a status pill, a count, a filter tag.
  ///
  /// [tone] is one of the status semantics or `primary`; the fill is that
  /// colour at [SkotiqTokens.opacityStatusFill] and the text is the same
  /// colour at full strength. A null [tone] is the neutral chip and takes a
  /// solid `surfaceHover` fill with `textSecondary` text. A chip has NO border
  /// — the fill is the boundary.
  /// [radius] overrides the chip radius for the handful of call sites that
  /// draw a chip-toned SQUARE — a score badge, a 44px count tile. It exists so
  /// those can leave the deprecated `tintedBadge` / `statusChip`, which took
  /// a whole `BorderRadius` and were the only reason those two survived.
  static BoxDecoration chip(
    SkotiqColors colors, {
    Color? tone,
    double? radius,
  }) {
    return BoxDecoration(
      color: tone == null
          ? colors.surfaceHover
          : tone.withValues(alpha: SkotiqTokens.opacityStatusFill),
      borderRadius: BorderRadius.circular(radius ?? SkotiqTokens.radiusXs),
    );
  }

  /// A panel that carries a TONE: the same face as [panel] with a status or
  /// accent tint instead of the `surface` fill.
  ///
  /// The successor to the deprecated `emphasisSurface`, which took a bare
  /// `Color` and could not reach the palette, so it invented its own fill and
  /// border opacities. This one takes the palette and the tone separately, so
  /// the tint is on the token scale ([SkotiqTokens.opacityStatusFill]) and
  /// the ring is the selected-ring one every other tinted surface uses.
  ///
  /// Rare by design: 02 rule 4 says one panel style. Reach for it only where
  /// the tone IS the message — a warning block, a "session only" surface.
  static BoxDecoration panelTinted(SkotiqColors colors, {required Color tone}) {
    return BoxDecoration(
      color: tone.withValues(alpha: SkotiqTokens.opacityStatusFill),
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      border: Border.all(
        color: tone.withValues(alpha: SkotiqTokens.opacitySelectedRing),
      ),
    );
  }

  /// A filter chip: transparent, outlined, toggled by its text colour.
  ///
  /// Distinct from [chip] because it is a CONTROL, not a readout, and an
  /// outline is how an unselected control says it can be pressed.
  static BoxDecoration filterChip(SkotiqColors colors) {
    return BoxDecoration(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      border: Border.all(color: colors.borderHighlight),
    );
  }

  /// A text or number field.
  ///
  /// Recessed to [SkotiqColors.well] so an input reads as somewhere to put
  /// something. Focus and error replace the near-invisible resting ring with a
  /// real 1px line, which is the one place in the language where a border
  /// carries state.
  static BoxDecoration field(
    SkotiqColors colors, {
    bool focused = false,
    bool hasError = false,
  }) {
    final Color ring;
    if (hasError) {
      ring = colors.error;
    } else if (focused) {
      ring = colors.primary;
    } else {
      ring = _isLight(colors)
          ? colors.border
          : _white.withValues(alpha: SkotiqTokens.opacityPanelOutline);
    }
    return BoxDecoration(
      color: colors.well,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      border: Border.all(color: ring),
    );
  }

  /// The floating layer: menus, dropdowns, tooltips, toasts.
  ///
  /// This and [dialog] are the only two decorations in the app that cast a
  /// shadow, because they are the only two that are genuinely above the page.
  static BoxDecoration popover(SkotiqColors colors) {
    final light = _isLight(colors);
    return BoxDecoration(
      color: colors.surfaceElevated,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXl),
      border: Border.all(
        color: light
            ? colors.border
            : _white.withValues(alpha: SkotiqTokens.opacityHairline),
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: light
              ? const Color(0xFF14181F).withValues(alpha: 0.14)
              : const Color(0xFF000000).withValues(alpha: 0.45),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }

  /// A dialog or the command palette — the top of the stack.
  static BoxDecoration dialog(SkotiqColors colors) {
    final light = _isLight(colors);
    return BoxDecoration(
      color: colors.surfaceOverlay,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXl),
      border: Border.all(
        color: light
            ? colors.border
            : _white.withValues(alpha: SkotiqTokens.opacityHairline),
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: light
              ? const Color(0xFF14181F).withValues(alpha: 0.22)
              : const Color(0xFF000000).withValues(alpha: 0.6),
          blurRadius: 64,
          offset: const Offset(0, 24),
        ),
      ],
    );
  }

  /// Glass — a translucent panel used ONLY over imagery.
  ///
  /// Anchored to the image rather than to the theme: the frame is dark in
  /// every mode, so the light palette uses the DARK glass and its contents use
  /// the dark text ladder. Red night keeps its own surface and a red edge,
  /// because the wavelength rule outranks the anchoring one.
  ///
  /// This returns the fill and edge only. The blur is the caller's:
  /// wrap the content in `BackdropFilter(filter: ImageFilter.blur(sigmaX: 12,
  /// sigmaY: 12))`, and put the `RepaintBoundary` OUTSIDE any animation gate —
  /// a boundary inside the gate silently kills the animation.
  static BoxDecoration glass(SkotiqColors colors) {
    if (colors.isRedNight) {
      return BoxDecoration(
        color: colors.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.primary.withValues(alpha: 0.14)),
      );
    }
    return BoxDecoration(
      color: SkotiqColors.dark.surface.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      border: Border.all(color: _white.withValues(alpha: 0.10)),
    );
  }

  /// A 1px divider. Prefer `Divider(height: 1, thickness: 1)`; use this when
  /// the line is one edge of a box you are already painting.
  static BoxDecoration hairline(SkotiqColors colors) {
    return BoxDecoration(
      border: Border(bottom: BorderSide(color: colors.border)),
    );
  }

  // ---------------------------------------------------------------------
  // Pre-overhaul API — deprecated, deleted in wave 4
  // ---------------------------------------------------------------------

  /// The chip fill, expressed from a bare tone so the deprecated badge and
  /// pill helpers below can share it with [chip].
  static BoxDecoration _chipOfTone(Color tone, {BorderRadius? borderRadius}) {
    return BoxDecoration(
      color: tone.withValues(alpha: SkotiqTokens.opacityStatusFill),
      borderRadius:
          borderRadius ?? BorderRadius.circular(SkotiqTokens.radiusXs),
    );
  }

  /// Subtle tinted container for icon chips and accent badges.
  @Deprecated(
    'Use SkotiqDecorations.well for the icon square. Removed in wave 4.',
  )
  static BoxDecoration iconChip(
    Color color, {
    BorderRadius? borderRadius,
    bool bordered = true,
    double borderAlpha = 0.16,
  }) {
    // Cannot reach `well` from a bare Color — the well tone belongs to the
    // palette — so the tint stays and only the radius moves onto the scale.
    return BoxDecoration(
      color: color.withValues(alpha: SkotiqTokens.opacitySubtle),
      borderRadius:
          borderRadius ?? BorderRadius.circular(SkotiqTokens.radiusSm),
      border: bordered
          ? Border.all(color: color.withValues(alpha: borderAlpha))
          : null,
    );
  }

  /// Tinted surface with emphasis border.
  @Deprecated('Use SkotiqDecorations.panel. Removed in wave 4.')
  static BoxDecoration emphasisSurface(
    Color color, {
    BorderRadius? borderRadius,
  }) {
    // Cannot reach `panel` from a bare Color for the same reason as
    // [iconChip]; wave 3 rewrites these call sites screen by screen.
    return BoxDecoration(
      color: color.withValues(alpha: SkotiqTokens.opacitySubtle),
      borderRadius:
          borderRadius ?? BorderRadius.circular(SkotiqTokens.radiusLg),
      border: Border.all(
        color: color.withValues(alpha: SkotiqTokens.opacityStrong),
      ),
    );
  }

  /// Tinted badge background without a border.
  @Deprecated('Use SkotiqDecorations.chip. Removed in wave 4.')
  static BoxDecoration tintedBadge(Color color, {BorderRadius? borderRadius}) =>
      _chipOfTone(color, borderRadius: borderRadius);

  /// Status or state indicator chip.
  @Deprecated('Use SkotiqDecorations.chip. Removed in wave 4.')
  static BoxDecoration statusChip(
    Color color, {
    BorderRadius? borderRadius,
    bool bordered = true,
  }) {
    // `bordered` is honoured no longer: a chip has no border in this language,
    // the fill is its boundary. The parameter stays so the call sites compile.
    return _chipOfTone(color, borderRadius: borderRadius);
  }

  /// Background and border colors for solid accent buttons on hover.
  @Deprecated('SkotiqButton paints itself. Removed in wave 4.')
  static ({Color background, Color border}) filledButtonColors(
    Color base, {
    required bool isHovered,
    required bool isDisabled,
  }) {
    if (isDisabled) {
      return (
        background: base.withValues(alpha: SkotiqTokens.opacityHalf),
        border: base.withValues(alpha: SkotiqTokens.opacityHalf),
      );
    }
    return (
      background: isHovered
          ? Color.lerp(base, _white, SkotiqTokens.buttonHoverLighten)!
          : base,
      border: Color.lerp(
        base,
        const Color(0xFF000000),
        SkotiqTokens.buttonBorderDarken,
      )!,
    );
  }

  /// Selected or active toggle surface.
  @Deprecated('Use SkotiqDecorations.panelSelected. Removed in wave 4.')
  static BoxDecoration selectedSurface(
    Color color, {
    BorderRadius? borderRadius,
    double fillAlpha = SkotiqTokens.opacityStatusFill,
  }) {
    return BoxDecoration(
      color: color.withValues(alpha: fillAlpha),
      borderRadius:
          borderRadius ?? BorderRadius.circular(SkotiqTokens.radiusLg),
      border: Border.all(
        color: color.withValues(alpha: SkotiqTokens.opacitySelectedRing),
      ),
    );
  }

  /// Selected navigation rail / sidebar item.
  @Deprecated('Use SkotiqDecorations.railItemSelected. Removed in wave 4.')
  static BoxDecoration navSelected(
    SkotiqColors colors, {
    BorderRadius? borderRadius,
  }) {
    final base = railItemSelected(colors);
    return borderRadius == null
        ? base
        : base.copyWith(borderRadius: borderRadius);
  }

  /// Selected card with accent tint and emphasis border.
  @Deprecated('Use SkotiqDecorations.panelSelected. Removed in wave 4.')
  static BoxDecoration cardSelected(
    Color accent, {
    Color? background,
    BorderRadius? borderRadius,
    double borderWidth = 1,
  }) {
    final fill = background != null
        ? Color.alphaBlend(
            accent.withValues(alpha: SkotiqTokens.opacityTint),
            background,
          )
        : accent.withValues(alpha: SkotiqTokens.opacityTint);
    return BoxDecoration(
      color: fill,
      borderRadius:
          borderRadius ?? BorderRadius.circular(SkotiqTokens.radiusLg),
      border: Border.all(
        color: accent.withValues(alpha: SkotiqTokens.opacitySelectedRing),
        width: borderWidth,
      ),
    );
  }

  /// Hover state for interactive rows.
  @Deprecated(
    'A panel has no hover; a tappable row takes a surfaceHover fill. '
    'Removed in wave 4.',
  )
  static BoxDecoration cardHover(
    SkotiqColors colors, {
    BorderRadius? borderRadius,
  }) {
    return BoxDecoration(
      color: colors.surfaceHover,
      borderRadius:
          borderRadius ?? BorderRadius.circular(SkotiqTokens.radiusLg),
    );
  }

  /// Drag-and-drop feedback frame.
  @Deprecated('Use SkotiqDecorations.popover. Removed in wave 4.')
  static BoxDecoration dragFeedback(
    SkotiqColors colors, {
    BorderRadius? borderRadius,
    Color? accentColor,
  }) {
    final base = popover(colors);
    return borderRadius == null
        ? base
        : base.copyWith(borderRadius: borderRadius);
  }

  /// Circular or rounded KPI / score badge.
  @Deprecated('Use SkotiqDecorations.chip. Removed in wave 4.')
  static BoxDecoration kpiBadge(
    Color color, {
    BorderRadius? borderRadius,
    BoxShape shape = BoxShape.circle,
  }) {
    // The shape is preserved because a circle and a rounded rect are not the
    // same box; only the fill and the border move onto the chip rule.
    return BoxDecoration(
      shape: shape,
      color: color.withValues(alpha: SkotiqTokens.opacityStatusFill),
      borderRadius: shape == BoxShape.circle
          ? null
          : (borderRadius ?? BorderRadius.circular(SkotiqTokens.radiusXs)),
    );
  }

  /// Full decoration for a solid accent button.
  @Deprecated('SkotiqButton paints itself. Removed in wave 4.')
  static BoxDecoration filledButton(
    Color base, {
    required bool isHovered,
    required bool isDisabled,
    BorderRadius? borderRadius,
  }) {
    // Buttons have no border in this language: the fill is the button.
    final background = isDisabled
        ? base.withValues(alpha: SkotiqTokens.opacityHalf)
        : (isHovered
              ? Color.lerp(base, _white, SkotiqTokens.buttonHoverLighten)!
              : base);
    return BoxDecoration(
      color: background,
      borderRadius:
          borderRadius ?? BorderRadius.circular(SkotiqTokens.radiusSm),
    );
  }
}

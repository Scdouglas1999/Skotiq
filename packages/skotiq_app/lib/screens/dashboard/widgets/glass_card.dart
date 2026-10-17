import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'smart_night_prompt_card.dart' show floatingPromptReservedHeightProvider;

/// Shared visual constants for dashboard cards.
///
/// Every dashboard card composes its content with these so headers, padding,
/// icons, and status chips line up across the grid instead of drifting per
/// card. Tweak a value here and the whole dashboard moves together.
class DashboardCardStyle {
  DashboardCardStyle._();

  /// Uniform internal padding for every card body. Matches the design
  /// system's medium spacing token so cards read as one family.
  static const EdgeInsets contentPadding = EdgeInsets.all(SkotiqTokens.spaceMd);

  /// Vertical gap between a card's header and its body.
  static const double headerGap = SkotiqTokens.spaceSm;

  /// Header icon glyph size (inside the tinted badge).
  static const double headerIconSize = 15;

  /// Header title text size.
  static const double headerTitleSize = 13;

  /// Status chip text size used in card headers.
  static const double statusChipTextSize = 10;

  // Phone-compact variants
  //
  // On a phone the cockpit tiles must pack tighter — especially in landscape
  // (~410 px tall) where desktop-sized padding/fonts crowd content off-screen.
  // These resolvers return the compact value on the phone tier and the desktop
  // value otherwise, so every card shrinks together off the same single knob as
  // the constants above. Body/title text stays >= 12.5 sp so it remains legible
  // at arm's length.

  /// Card body padding, tightened on phone.
  static EdgeInsets contentPaddingFor(BuildContext context) =>
      Responsive.isPhone(context)
          ? const EdgeInsets.all(SkotiqTokens.spaceSm)
          : contentPadding;

  /// Header→body gap, tightened on phone.
  static double headerGapFor(BuildContext context) =>
      Responsive.isPhone(context) ? SkotiqTokens.spaceXs : headerGap;

  /// Header icon glyph size, tightened on phone.
  static double headerIconSizeFor(BuildContext context) =>
      Responsive.isPhone(context) ? 13 : headerIconSize;

  /// Header title size, tightened on phone (kept legible).
  static double headerTitleSizeFor(BuildContext context) =>
      Responsive.isPhone(context) ? 12.5 : headerTitleSize;
}

class DashboardGlassCard extends StatelessWidget {
  final SkotiqColors colors;
  final Widget child;

  /// Explicit padding override. When null the card uses the phone-aware
  /// [DashboardCardStyle.contentPaddingFor] so tiles tighten on a phone.
  final EdgeInsets? padding;

  const DashboardGlassCard({
    super.key,
    required this.colors,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SkotiqTokens.borderRadiusMd,
        border: Border.all(color: colors.border),
        boxShadow: SkotiqTokens.elevationLevel1,
      ),
      child: Padding(
        padding: padding ?? DashboardCardStyle.contentPaddingFor(context),
        child: child,
      ),
    );
  }
}

/// Standardized header row for dashboard cards.
///
/// Lays out a tinted icon badge, a title, and an optional trailing widget
/// (typically a [DashboardStatusChip] and/or inline metrics) on a single
/// baseline with consistent sizing across every card. Use this instead of
/// hand-rolling a header `Row` so the grid stays visually aligned.
class DashboardCardHeader extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String title;

  /// Tint applied to the icon and its badge. Defaults to the muted text
  /// colour so an inactive card reads as neutral; pass a status colour
  /// (success/warning/etc.) to signal an active subsystem.
  final Color? accent;

  /// Optional trailing content aligned to the end of the header row.
  final Widget? trailing;

  const DashboardCardHeader({
    super.key,
    required this.colors,
    required this.icon,
    required this.title,
    this.accent,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final tint = accent ?? colors.textMuted;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
          decoration: SkotiqDecorations.tintedBadge(
            tint,
            borderRadius: SkotiqTokens.borderRadiusSm,
          ),
          child: Icon(
            icon,
            size: DashboardCardStyle.headerIconSizeFor(context),
            color: tint,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            title,
            // 03 §2: a card's title is one size on every device. The
            // phone/desktop 12.5-vs-13 split was a second scale that only this
            // card knew about.
            style: SkotiqTypography.bodyStrong.copyWith(
              color: colors.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: SkotiqTokens.spaceSm),
          trailing!,
        ],
      ],
    );
  }
}

/// Standardized status chip for dashboard card headers.
///
/// Renders a pill that is tinted when [active] and neutral otherwise, keeping
/// the on/off treatment identical across cards.
class DashboardStatusChip extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final bool active;

  /// Colour used when [active]. Defaults to success green.
  final Color? activeColor;

  const DashboardStatusChip({
    super.key,
    required this.colors,
    required this.label,
    required this.active,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final tint = activeColor ?? colors.success;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: 2,
      ),
      decoration: active
          ? SkotiqDecorations.statusChip(
              tint,
              borderRadius: SkotiqTokens.borderRadiusFull,
              bordered: false,
            )
          : BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
            ),
      child: Text(
        label,
        style: SkotiqTypography.eyebrow.copyWith(
          color: active ? tint : colors.textMuted,
        ),
      ),
    );
  }
}

/// Scrollable wrapper for dashboard zone columns that keeps the scrollbar in a
/// dedicated gutter so its thumb never paints over card content or crosses a
/// card's rounded border.
///
/// The default [MaterialScrollBehavior] on desktop overlays the scrollbar on
/// the trailing edge of whatever is scrolled — which, for a column of bordered
/// cards, lands the thumb directly on top of the cards. This widget owns a
/// [ScrollController], reserves [gutter] pixels of trailing padding on the
/// content, and draws the [Scrollbar] inside that reserved strip.
class DashboardScrollView extends ConsumerStatefulWidget {
  final Widget child;
  final EdgeInsets padding;

  /// Width of the reserved scrollbar gutter on the trailing edge.
  static const double gutter = 14.0;

  /// Visual thickness of the scrollbar thumb. Kept narrower than [gutter] so
  /// the thumb is fully inset with breathing room on both sides.
  static const double _thumbThickness = 6.0;

  const DashboardScrollView({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  @override
  ConsumerState<DashboardScrollView> createState() =>
      _DashboardScrollViewState();
}

class _DashboardScrollViewState extends ConsumerState<DashboardScrollView> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reserve the gutter on the trailing edge by adding it to the content's
    // right padding; the cards therefore stop short of where the thumb draws.
    // Reserve the floating prompt's band at the bottom while it is up. It is
    // drawn over this scroll view, so without the reserve the last card in the
    // extent cannot be scrolled out from under it — live, the "Build tonight's
    // plan?" nudge sat over the Moon card and hid the Moonrise time.
    final promptBand = ref.watch(floatingPromptReservedHeightProvider);
    final contentPadding = widget.padding.add(
      EdgeInsets.only(
        right: DashboardScrollView.gutter,
        bottom: promptBand,
      ),
    ) as EdgeInsets;

    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(DashboardScrollView._thumbThickness),
        radius: const Radius.circular(SkotiqTokens.radiusFull),
        // Inset the track so the thumb sits centred in the reserved gutter,
        // clear of the card border to its left.
        crossAxisMargin:
            (DashboardScrollView.gutter - DashboardScrollView._thumbThickness) /
                2,
        mainAxisMargin: SkotiqTokens.spaceXs,
      ),
      child: Scrollbar(
        controller: _controller,
        // Reserve space for the thumb at all times so the layout doesn't
        // shift when the scrollbar fades in on hover.
        thumbVisibility: false,
        child: SingleChildScrollView(
          controller: _controller,
          padding: contentPadding,
          child: widget.child,
        ),
      ),
    );
  }
}

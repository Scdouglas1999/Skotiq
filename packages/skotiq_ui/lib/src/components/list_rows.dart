import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import 'readout.dart';

/// Icon size at the head of a list row, in logical pixels (05 §9: 15 muted).
const double _rowIconSize = SkotiqTokens.iconGlyphRow;

/// A row in a list: 13px text, 8px vertical padding, a hairline underneath,
/// a 15px muted leading icon and a trailing mono timestamp.
///
/// This — not a panel — is the tappable container in this language. A panel has
/// no hover and no `onTap`; a row has both.
class ListRow extends StatefulWidget {
  const ListRow({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
    this.trailingWidget,
    this.onTap,
    this.showDivider = true,
  });

  /// The row's text.
  final String title;

  /// An optional 15px leading glyph in `textMuted`.
  final IconData? icon;

  /// A trailing mono timestamp or count in `textMuted`.
  final String? trailing;

  /// A trailing widget, used instead of [trailing] when the row ends in a
  /// control or a chip.
  final Widget? trailingWidget;

  /// Non-null makes the row tappable and gives it a `surfaceHover` fill.
  final VoidCallback? onTap;

  /// Draws the 1px hairline under the row. The LAST row in a list passes
  /// false — a line under the final row is the bottom of nothing.
  final bool showDivider;

  /// Vertical padding.
  static const double verticalPadding = SkotiqTokens.spaceSm;

  /// Gap between the icon, the title and the trailing slot.
  static const double gap = 10;

  @override
  State<ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<ListRow> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (!mounted || _hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final tappable = widget.onTap != null;

    final row = Container(
      padding: const EdgeInsets.symmetric(
        vertical: ListRow.verticalPadding,
        horizontal: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: tappable && _hovered ? colors.surfaceHover : Colors.transparent,
        borderRadius: SkotiqTokens.borderRadiusSm,
        border: widget.showDivider
            ? Border(bottom: BorderSide(color: colors.border))
            : null,
      ),
      child: Row(
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            Icon(widget.icon, size: _rowIconSize, color: colors.textMuted),
            const SizedBox(width: ListRow.gap),
          ],
          Expanded(
            child: Text(
              widget.title,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.trailingWidget != null) ...<Widget>[
            const SizedBox(width: ListRow.gap),
            widget.trailingWidget!,
          ] else if (widget.trailing != null) ...<Widget>[
            const SizedBox(width: ListRow.gap),
            Text(
              widget.trailing!,
              style: SkotiqTypography.readoutXs.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );

    if (!tappable) return row;

    return Semantics(
      button: true,
      // Semantics publishes isEnabled only when the field is given; without it
      // a live row announces as dimmed.
      enabled: true,
      label: widget.title,
      child: MouseRegion(
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(child: row),
        ),
      ),
    );
  }
}

/// A device in the Tonight → Equipment panel:
/// `[icon 15] [name 14/500] … [ReadoutRow(size: sm, gap 18)]`.
class DeviceRow extends StatelessWidget {
  const DeviceRow({
    super.key,
    required this.name,
    this.readouts = const <Readout>[],
    this.icon,
    this.leading,
    this.trailing,
    this.onTap,
  });

  /// The device's name.
  final String name;

  /// Its live values, right-aligned.
  final List<Readout> readouts;

  /// An optional 15px leading glyph in `textMuted`.
  final IconData? icon;

  /// A leading widget used instead of [icon] — a `StatusDot`, a chip.
  final Widget? leading;

  /// A trailing widget at the end of the row, after [readouts].
  ///
  /// A device that is NOT connected has no values to report, and a row of
  /// `Readout(value: null)` says "three things I cannot measure" where the
  /// truth is one thing: it is not connected. 06 Tonight asks for that as a
  /// word, so the row takes one — [trailing] is where it goes. Style it at the
  /// call site; the row does not assume it is text.
  final Widget? trailing;

  /// Non-null makes the row tappable.
  final VoidCallback? onTap;

  /// Gap between the small readouts at the end of the row.
  static const double readoutGap = 18;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: ListRow.verticalPadding),
      child: Row(
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            const SizedBox(width: ListRow.gap),
          ] else if (icon != null) ...<Widget>[
            Icon(icon, size: _rowIconSize, color: colors.textMuted),
            const SizedBox(width: ListRow.gap),
          ],
          Expanded(
            child: Text(
              name,
              // 14 at weight 500. `button` is the only style on the scale with
              // those metrics; 03 §2 forbids inventing a second one.
              style: SkotiqTypography.button.copyWith(
                color: colors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (readouts.isNotEmpty) ...<Widget>[
            const SizedBox(width: ListRow.gap),
            ReadoutRow(gap: readoutGap, children: readouts),
          ],
          if (trailing != null) ...<Widget>[
            const SizedBox(width: ListRow.gap),
            trailing!,
          ],
        ],
      ),
    );

    if (onTap == null) return row;

    return Semantics(
      button: true,
      enabled: true,
      label: name,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(child: row),
        ),
      ),
    );
  }
}

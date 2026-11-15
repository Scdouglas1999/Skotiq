import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import 'readout.dart';

/// Icon size at the head of a list row, in logical pixels (05 §9: 15 muted).
const double _rowIconSize = SkotiqTokens.iconGlyphRow;

/// A row in a list, and the tappable container in this language: a panel has
/// no hover and no `onTap`; a row has both.
///
/// One line: [title] in 13px `bodySm` with an optional 15px muted [icon] — a
/// side list, search results. Two lines, when [subtitle] is given: the title
/// steps up to `bodyStrong` with one muted `bodySm` line beneath it — the row
/// of a page's main list (saved sequences, past nights, targets).
///
/// After the text, in order: [trailingWidget] (a status chip or a control),
/// [trailing] (a right-aligned mono figure or timestamp) and at most two
/// [actions] (icon buttons). Anything more belongs behind one "more" menu,
/// which is then one of the two actions.
///
/// 8px vertical padding and a hairline underneath; a [selected] row trades the
/// hairline for the accent ring every selected surface uses.
class ListRow extends StatefulWidget {
  const ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.trailingWidget,
    this.actions = const <Widget>[],
    this.onTap,
    this.selected = false,
    this.showDivider = true,
  }) : assert(actions.length <= maxActions, 'Put further actions in a menu.');

  final String title;

  /// One muted line of facts under the title. Never a second sentence.
  final String? subtitle;

  /// An optional 15px leading glyph in `textMuted`.
  final IconData? icon;

  /// A trailing mono figure or timestamp in `textMuted`.
  final String? trailing;

  /// A trailing widget before [trailing]: a status chip or a control.
  final Widget? trailingWidget;

  /// Up to [maxActions] icon buttons at the row's end. They keep their own
  /// taps and their own names; the rest of the row is [onTap].
  final List<Widget> actions;

  /// Non-null makes the row tappable and gives it a `surfaceHover` fill.
  final VoidCallback? onTap;

  /// Marks the row as the one whose detail is open.
  final bool selected;

  /// Draws the 1px hairline under the row. The LAST row in a list passes
  /// false — a line under the final row is the bottom of nothing.
  final bool showDivider;

  static const double verticalPadding = SkotiqTokens.spaceSm;

  /// Gap between the icon, the text and the trailing slots.
  static const double gap = 10;

  /// Gap between the title and the subtitle.
  static const double lineGap = 2;

  /// The most icon buttons a row carries.
  static const int maxActions = 2;

  @override
  State<ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<ListRow> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (!mounted || _hovered == value) return;
    setState(() => _hovered = value);
  }

  BoxBorder? _border(SkotiqColors colors) {
    if (widget.selected) {
      return Border.all(
        color: colors.primary.withValues(
          alpha: SkotiqTokens.opacitySelectedRing,
        ),
      );
    }
    if (widget.showDivider) {
      return Border(bottom: BorderSide(color: colors.border));
    }
    return null;
  }

  Widget _text(SkotiqColors colors) {
    final subtitle = widget.subtitle;
    final title = Text(
      widget.title,
      style:
          (subtitle == null
                  ? SkotiqTypography.bodySm
                  : SkotiqTypography.bodyStrong)
              .copyWith(color: colors.textPrimary),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (subtitle == null) return title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        title,
        const SizedBox(height: ListRow.lineGap),
        Text(
          subtitle,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final tappable = widget.onTap != null;

    // Everything but the actions, padding included: the part the row's own
    // tap and name cover.
    Widget body = Padding(
      padding: EdgeInsets.fromLTRB(
        SkotiqTokens.spaceSm,
        ListRow.verticalPadding,
        widget.actions.isEmpty ? SkotiqTokens.spaceSm : 0,
        ListRow.verticalPadding,
      ),
      child: Row(
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            Icon(widget.icon, size: _rowIconSize, color: colors.textMuted),
            const SizedBox(width: ListRow.gap),
          ],
          Expanded(child: _text(colors)),
          if (widget.trailingWidget != null) ...<Widget>[
            const SizedBox(width: ListRow.gap),
            widget.trailingWidget!,
          ],
          if (widget.trailing != null) ...<Widget>[
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

    if (tappable) {
      body = Semantics(
        button: true,
        // Semantics publishes isEnabled only when the field is given; without
        // it a live row announces as dimmed.
        enabled: true,
        selected: widget.selected,
        label: widget.subtitle == null
            ? widget.title
            : '${widget.title}, ${widget.subtitle}',
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(child: body),
        ),
      );
    }

    final row = Container(
      decoration: BoxDecoration(
        color: tappable && _hovered ? colors.surfaceHover : Colors.transparent,
        borderRadius: SkotiqTokens.borderRadiusSm,
        border: _border(colors),
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: body),
          for (final action in widget.actions) ...<Widget>[
            const SizedBox(width: SkotiqTokens.spaceXs),
            action,
          ],
          if (widget.actions.isNotEmpty)
            const SizedBox(width: SkotiqTokens.spaceXs),
        ],
      ),
    );

    if (!tappable) return row;

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      cursor: SystemMouseCursors.click,
      child: row,
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

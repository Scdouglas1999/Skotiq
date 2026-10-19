// The building blocks the Mount, Guide and Solve tab bodies share: a ruled
// section with a title row, a grid of equal-width buttons, and the scroll
// view a tab body sits in. The panel is 300 px wide, so everything here
// lays out in rows of equal columns and ellipsizes rather than overflows.
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Inner padding of one section (the boards' `10px 12px`).
const EdgeInsets kNightPanelSectionPadding =
    EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceMd, vertical: 10);

/// Gap between the rows inside a section.
const double kNightPanelRowGap = 6;

/// Gap between the cells of a button grid.
const double kNightPanelCellGap = 4;

/// A tab body: its sections stacked in a vertical scroll view.
class NightPanelScroll extends StatelessWidget {
  const NightPanelScroll({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// One ruled section: a bold title, an optional muted fact on the right,
/// then [children] separated by [kNightPanelRowGap].
class NightPanelSection extends StatelessWidget {
  const NightPanelSection({
    super.key,
    required this.title,
    this.trailing,
    this.trailingColor,
    required this.children,
  });

  final String title;

  /// "Tracking · sidereal", "ASTAP", "live from PHD2".
  final String? trailing;

  /// Overrides the trailing text's muted color with a status color.
  final Color? trailingColor;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final trailing = this.trailing;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: kNightPanelSectionPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // The title keeps its natural width (up to a cap) and the
                // trailing fact takes the rest, right-aligned.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: colors.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      trailing,
                      textAlign: TextAlign.end,
                      style: SkotiqTypography.caption
                          .copyWith(color: trailingColor ?? colors.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
            for (final child in children) ...[
              const SizedBox(height: kNightPanelRowGap),
              child,
            ],
          ],
        ),
      ),
    );
  }
}

/// One button of a [NightPanelButtonGrid].
class NightPanelButtonSpec {
  const NightPanelButtonSpec({
    required this.label,
    required this.onPressed,
    this.disabledReason,
    this.tooltip,
    this.selected = false,
    this.emphasized = false,
    this.destructive = false,
    this.busy = false,
    this.key,
  });

  final String label;

  /// Null disables the button; [disabledReason] then says why.
  final VoidCallback? onPressed;

  /// Tooltip and semantics hint of a disabled button.
  final String? disabledReason;

  /// Tooltip of an enabled button (a caution, not a reason).
  final String? tooltip;

  /// The current choice of a set (the tracking rate in use).
  final bool selected;

  /// The section's main action (filled).
  final bool emphasized;

  /// Moves hardware somewhere the operator must mean (Park).
  final bool destructive;

  /// The action this button started is in flight.
  final bool busy;

  final Key? key;

  bool get enabled => onPressed != null;
}

/// Buttons in rows of [columns] equal cells.
class NightPanelButtonGrid extends StatelessWidget {
  const NightPanelButtonGrid({
    super.key,
    required this.buttons,
    this.columns = 3,
  });

  final List<NightPanelButtonSpec> buttons;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < buttons.length; start += columns) {
      if (rows.isNotEmpty) {
        rows.add(const SizedBox(height: kNightPanelCellGap));
      }
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var c = 0; c < columns; c++) ...[
              if (c > 0) const SizedBox(width: kNightPanelCellGap),
              Expanded(
                child: start + c < buttons.length
                    ? NightPanelButton(spec: buttons[start + c])
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}

/// A small button that carries its disabled reason in a tooltip and in the
/// semantics hint.
class NightPanelButton extends StatelessWidget {
  NightPanelButton({required this.spec}) : super(key: spec.key);

  final NightPanelButtonSpec spec;

  @override
  Widget build(BuildContext context) {
    final reason = spec.enabled ? null : spec.disabledReason;
    final variant = spec.destructive
        ? ButtonVariant.destructive
        : spec.emphasized || spec.selected
            ? ButtonVariant.primary
            : ButtonVariant.secondary;
    final button = SkotiqButton(
      label: spec.label,
      onPressed: spec.onPressed,
      variant: variant,
      size: ButtonSize.small,
      isLoading: spec.busy,
      semanticsHint: reason ?? spec.tooltip,
    );
    final message = reason ?? spec.tooltip;
    final child = Semantics(
      selected: spec.selected,
      child: SizedBox(width: double.infinity, child: button),
    );
    if (message == null) return child;
    return Tooltip(message: message, child: child);
  }
}

/// A muted line of small print under a section's controls.
class NightPanelNote extends StatelessWidget {
  const NightPanelNote(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Text(
      text,
      style:
          SkotiqTypography.caption.copyWith(color: color ?? colors.textMuted),
    );
  }
}

/// [MetricGrid] in three columns, the boards' value grid. Long values
/// (sexagesimal coordinates) take two columns so they keep their seconds at
/// 1.3x text.
class NightPanelValues extends StatelessWidget {
  const NightPanelValues({
    super.key,
    required this.items,
    this.columns = 3,
    this.semanticLabel,
  });

  final List<MetricGridItem> items;
  final int columns;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) =>
      MetricGrid(items: items, columns: columns, semanticLabel: semanticLabel);
}

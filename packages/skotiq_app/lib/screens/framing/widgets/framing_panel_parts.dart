// The pieces the Framing side column is built from. They follow the Tonight
// right panel (night_control/panel/panel_widgets.dart): a section is a bold
// title with a muted note on the same line, its rows 6 px apart, and a
// hairline under it; secondary actions are the panel's 28 px buttons.
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../night_control/panel/panel_widgets.dart';

export '../../night_control/panel/panel_widgets.dart'
    show
        NightPanelButton,
        NightPanelGrid,
        NightPanelLabel,
        NightPanelRow,
        kNightPanelRowGap;

/// Width of the label column of every label/control row in the column, so
/// Survey, Preview, Overlap and Start line up down the panel.
const double kFramingLabelWidth = 64;

/// One block of the Framing column.
///
/// The title row carries an optional note ([note], toned by [noteColor]) and
/// optional [actions] (icon buttons, a switch). With [collapsible] the title
/// row toggles the body; the chevron says which way.
class FramingPanelSection extends StatefulWidget {
  const FramingPanelSection({
    super.key,
    required this.title,
    this.children = const <Widget>[],
    this.note,
    this.noteColor,
    this.noteKey,
    this.actions = const <Widget>[],
    this.collapsible = false,
    this.initiallyExpanded = true,
    this.divider = true,
  });

  final String title;
  final List<Widget> children;

  /// "My First Rig", "Ready", "NGC 1976 · mag 4.0".
  final String? note;

  /// Colors [note]; null is muted.
  final Color? noteColor;

  /// Key on the note text, for a test that means this section's status.
  final Key? noteKey;

  /// Trailing controls on the title row.
  final List<Widget> actions;

  final bool collapsible;
  final bool initiallyExpanded;
  final bool divider;

  /// The most of the title row the note may take.
  static const double noteShare = 0.6;

  @override
  State<FramingPanelSection> createState() => _FramingPanelSectionState();
}

class _FramingPanelSectionState extends State<FramingPanelSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final expanded = !widget.collapsible || _expanded;
    final note = widget.note;

    // The note takes its own width, up to [noteShare] of the row; the title
    // gets the rest, flush left, the note flush right against the actions.
    Widget titleRow = LayoutBuilder(
      builder: (context, constraints) => Row(
        children: <Widget>[
          if (widget.collapsible) ...<Widget>[
            Icon(
              expanded ? SkotiqIcons.chevronDown : SkotiqIcons.chevronRight,
              size: SkotiqTokens.iconXs,
              color: colors.textMuted,
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
          ],
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                widget.title,
                style: SkotiqTypography.labelStrong.copyWith(
                  color: colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (note != null) ...<Widget>[
            const SizedBox(width: SkotiqTokens.spaceSm),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * FramingPanelSection.noteShare,
              ),
              child: KeyedSubtree(
                key: widget.noteKey,
                child: Text(
                  note,
                  textAlign: TextAlign.end,
                  style: SkotiqTypography.caption.copyWith(
                    color: widget.noteColor ?? colors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          for (final action in widget.actions) ...<Widget>[
            const SizedBox(width: SkotiqTokens.spaceXs),
            action,
          ],
        ],
      ),
    );
    // Every title row is the height of the 28 px controls some of them carry,
    // so sections with and without actions keep one rhythm.
    titleRow = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SkotiqTokens.buttonHeightSm),
      child: titleRow,
    );
    if (widget.collapsible) {
      titleRow = Semantics(
        button: true,
        expanded: expanded,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: SkotiqTokens.borderRadiusInline4,
          child: titleRow,
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: widget.divider
            ? Border(bottom: BorderSide(color: colors.border))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd,
          vertical: SkotiqTokens.spaceSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            titleRow,
            if (expanded)
              for (final child in widget.children) ...<Widget>[
                const SizedBox(height: kNightPanelRowGap),
                child,
              ],
          ],
        ),
      ),
    );
  }
}

/// A muted (or toned) line of help under a control.
class FramingNote extends StatelessWidget {
  const FramingNote(this.text, {super.key, this.color, this.icon});

  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final ink = color ?? colors.textMuted;
    final label = Text(
      text,
      style: SkotiqTypography.captionSm.copyWith(color: ink),
    );
    if (icon == null) return label;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: SkotiqTokens.iconXs, color: ink),
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Expanded(child: label),
      ],
    );
  }
}

/// A label column and a control, the label in the shared
/// [kFramingLabelWidth] column.
class FramingFormRow extends StatelessWidget {
  const FramingFormRow({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FormRow(label: label, labelWidth: kFramingLabelWidth, child: child);
  }
}

/// The column's slider: the kit colors on a 24 px track row instead of
/// Material's 48 px touch row, with the value read out on the right.
class FramingSlider extends StatelessWidget {
  const FramingSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.valueLabel,
    this.divisions,
    this.semanticLabel,
    this.focusNode,
    this.onChangeStart,
    this.valueWidth = 40,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;

  /// The value as text beside the track; null leaves no readout.
  final String? valueLabel;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final double valueWidth;

  static const double height = 24;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final slider = SliderTheme(
      data: SkotiqSliderStyle.theme(colors).copyWith(
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.never,
        padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.radiusSm),
      ),
      child: SizedBox(
        height: height,
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          focusNode: focusNode,
          onChangeStart: onChangeStart,
          onChanged: onChanged,
          semanticFormatterCallback:
              valueLabel == null ? null : (_) => valueLabel!,
        ),
      ),
    );
    final labelled = semanticLabel == null
        ? slider
        : Semantics(label: semanticLabel, child: slider);
    if (valueLabel == null) return labelled;
    return Row(
      children: <Widget>[
        Expanded(child: labelled),
        SizedBox(
          width: valueWidth,
          child: Text(
            valueLabel!,
            textAlign: TextAlign.end,
            style: SkotiqTypography.monoXs.copyWith(
              color: onChanged == null ? colors.textMuted : colors.textPrimary,
            ),
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}

/// Two actions side by side, stacked one over the other when the column is
/// too narrow for both labels.
class FramingButtonPair extends StatelessWidget {
  const FramingButtonPair({
    super.key,
    required this.first,
    required this.second,
    this.stackBelow = 300,
  });

  final Widget first;
  final Widget second;
  final double stackBelow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < stackBelow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              first,
              const SizedBox(height: SkotiqTokens.spaceXs),
              second,
            ],
          );
        }
        return Row(
          children: <Widget>[
            Expanded(child: first),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

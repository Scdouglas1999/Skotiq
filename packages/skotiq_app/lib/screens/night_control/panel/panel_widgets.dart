// The pieces every right-panel tab body is built from: a section with its
// title row, the body that scrolls (or not) the way the layout asks, the
// dense button, a label/value row and the view-model to kit mappings.
import 'package:flutter/material.dart';
import 'package:skotiq_core/errors.dart' show userFacingError;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../night_control_contracts.dart';
import '../night_control_layout.dart';
import '../night_tone_color.dart';
import '../../../utils/snackbar_helper.dart';

/// Insets of a panel section, as on the boards (10 px top and bottom, 12 px
/// at the sides).
const EdgeInsets kNightPanelSectionPadding = EdgeInsets.symmetric(
  horizontal: SkotiqTokens.spaceMd,
  vertical: 10,
);

/// Gap between the rows of a section.
const double kNightPanelRowGap = 6;

/// A tab body: its sections in a column that scrolls on its own in the
/// column layouts and sizes to its content in the single column, where the
/// page scrolls.
///
/// [fill], when given, goes last and takes the height the sections leave,
/// never less than [fillMinHeight]; in the single column it is
/// [fillMinHeight] tall. It gets a bounded height either way, so it can
/// scroll on its own (Overview's log).
class NightPanelBody extends StatelessWidget {
  const NightPanelBody({
    super.key,
    required this.children,
    this.fill,
    this.fillMinHeight = 180,
  });

  final List<Widget> children;
  final Widget? fill;
  final double fillMinHeight;

  @override
  Widget build(BuildContext context) {
    final fill = this.fill;
    final scrolls =
        NightControlDensity.maybeOf(context)?.slotsScrollThemselves ?? true;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ...children,
        if (fill != null && !scrolls)
          SizedBox(height: fillMinHeight, child: fill),
      ],
    );
    if (!scrolls) return column;
    if (fill == null) {
      return SingleChildScrollView(primary: false, child: column);
    }
    return CustomScrollView(
      primary: false,
      slivers: <Widget>[
        SliverToBoxAdapter(child: column),
        SliverLayoutBuilder(
          // Measured against the sections above, not the scroll position,
          // so the height holds still while the body scrolls.
          builder: (context, constraints) {
            final left = constraints.viewportMainAxisExtent -
                constraints.precedingScrollExtent;
            return SliverToBoxAdapter(
              child: SizedBox(
                height: left > fillMinHeight ? left : fillMinHeight,
                child: fill,
              ),
            );
          },
        ),
      ],
    );
  }
}

/// One block of a tab: a bold title, an optional muted (or toned) note on
/// the right, then its rows. A hairline separates it from the next.
class NightPanelSection extends StatelessWidget {
  const NightPanelSection({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.trailingTone,
    this.trailingSemantics,
    this.divider = true,
    this.gap = kNightPanelRowGap,
    this.fillsHeight = false,
  });

  final String title;

  /// "vs night median", "At setpoint", "no weather source".
  final String? trailing;

  /// Colors [trailing]; null is muted.
  final MetricGridTone? trailingTone;

  /// Read instead of [trailing] when the note alone would be unclear.
  final String? trailingSemantics;

  final List<Widget> children;
  final bool divider;
  final double gap;

  /// The section takes the height it is given and its last child the part
  /// of it the title and the other children leave.
  final bool fillsHeight;

  /// The most of the title row the note may take.
  static const double noteShare = 0.6;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final note = trailing;
    return DecoratedBox(
      decoration: BoxDecoration(
        border:
            divider ? Border(bottom: BorderSide(color: colors.border)) : null,
      ),
      child: Padding(
        padding: kNightPanelSectionPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: fillsHeight ? MainAxisSize.max : MainAxisSize.min,
          children: <Widget>[
            LayoutBuilder(
              // The note takes its own width, up to [noteShare] of the row;
              // the title gets the rest, flush left, the note flush right.
              builder: (context, constraints) => Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
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
                        maxWidth: constraints.maxWidth * noteShare,
                      ),
                      child: Semantics(
                        label: trailingSemantics,
                        excludeSemantics: trailingSemantics != null,
                        child: Text(
                          note,
                          textAlign: TextAlign.end,
                          style: SkotiqTypography.caption.copyWith(
                            color: trailingTone == null
                                ? colors.textMuted
                                : nightToneColor(trailingTone!, colors),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            for (var i = 0; i < children.length; i++) ...<Widget>[
              SizedBox(height: gap),
              if (fillsHeight && i == children.length - 1)
                Expanded(child: children[i])
              else
                children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// A muted one- or two-line note under a section's controls.
class NightPanelNote extends StatelessWidget {
  const NightPanelNote(this.text, {super.key, this.tone, this.maxLines = 3});

  final String text;
  final MetricGridTone? tone;

  /// Null for text that must be read whole (an error).
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Text(
      text,
      style: SkotiqTypography.captionSm.copyWith(
        color: tone == null ? colors.textMuted : nightToneColor(tone!, colors),
      ),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// The panel's button: a quiet fill, the primary tint when [selected], the
/// primary color when [emphasized]. 28 px tall under a pointer and the
/// platform's touch minimum under a finger. Disabled with a
/// [disabledReason] it says why in a tooltip and in its semantics hint.
class NightPanelButton extends StatelessWidget {
  const NightPanelButton({
    super.key,
    required this.label,
    this.onPressed,
    this.selected = false,
    this.emphasized = false,
    this.destructive = false,
    this.busy = false,
    this.disabledReason,
    this.tooltip,
    this.semanticLabel,
    this.mono = false,
  });

  final String label;

  /// Null disables the button; [disabledReason] then says why.
  final VoidCallback? onPressed;

  /// The current choice of a set (the tracking rate in use, the filter).
  final bool selected;

  /// The section's main action.
  final bool emphasized;

  /// Moves hardware somewhere the operator must mean (Park).
  final bool destructive;

  /// The action this button started is in flight: a spinner stands in for
  /// the label and a second press does nothing.
  final bool busy;

  final String? disabledReason;

  /// Tooltip and semantics hint of an enabled button (a caution, not a
  /// reason).
  final String? tooltip;

  /// Read instead of [label] ("Move focuser in 500 steps" for "−500").
  final String? semanticLabel;

  /// Figures in the mono face (jog steps).
  final bool mono;

  static const double pointerHeight = SkotiqTokens.buttonHeightSm;

  static const double _spinnerSize = 12;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final height = SkotiqTouchTarget.minExtent(
      context,
      desktopExtent: pointerHeight,
    );
    final enabled = onPressed != null;
    final acts = enabled && !busy;
    final fill = selected
        ? colors.primary.withValues(alpha: PanelTabStrip.selectedAlpha)
        : emphasized
            ? colors.primary
            : colors.surfaceElevated;
    final ink = emphasized && !selected
        ? colors.onPrimary
        : selected
            ? colors.textPrimary
            : !enabled
                ? colors.textMuted
                : destructive
                    ? colors.error
                    : colors.textSecondary;
    final base = mono ? SkotiqTypography.monoSm : SkotiqTypography.labelSm;
    final radius = BorderRadius.circular(SkotiqTokens.radiusLg);
    final hint = enabled ? tooltip : disabledReason;

    // Always the same wrappers, whatever the state: rebuilt under a new
    // parent when a reason came or went, Loop, Find star and Stop dropped
    // out of the Linux accessibility tree each time looping enabled or
    // disabled them. A tooltip with no message builds no wrapper at all,
    // so one with nothing to add shows the label (in full, where the grid
    // cut it short).
    return Tooltip(
      message: hint ?? label,
      // The semantics node below carries the hint.
      excludeFromSemantics: true,
      child: Opacity(
        // The other options dim; the selected one stays legible, since it
        // is the value in force (the current filter, the run's frame type).
        opacity: enabled || selected ? 1 : SkotiqTokens.opacityMuted,
        child: Semantics(
          button: true,
          enabled: acts,
          selected: selected,
          label: semanticLabel ?? label,
          hint: hint,
          excludeSemantics: true,
          onTap: acts ? onPressed : null,
          child: SizedBox(
            height: height,
            child: Material(
              color: fill,
              borderRadius: radius,
              child: InkWell(
                borderRadius: radius,
                onTap: acts ? onPressed : null,
                hoverColor: emphasized ? null : colors.surfaceHover,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SkotiqTokens.spaceXs,
                    ),
                    child: busy
                        ? SizedBox(
                            width: _spinnerSize,
                            height: _spinnerSize,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: ink,
                            ),
                          )
                        : Text(
                            label,
                            style: base.copyWith(
                              color: ink,
                              fontWeight: selected || emphasized
                                  ? FontWeight.w600
                                  : null,
                            ),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One button of a [NightPanelButtonGrid]: a [NightPanelButton]'s fields,
/// for a section that builds its buttons as data.
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
  final VoidCallback? onPressed;
  final String? disabledReason;
  final String? tooltip;
  final bool selected;
  final bool emphasized;
  final bool destructive;
  final bool busy;
  final Key? key;
}

/// [NightPanelButton]s in rows of [columns] equal cells.
class NightPanelButtonGrid extends StatelessWidget {
  const NightPanelButtonGrid({
    super.key,
    required this.buttons,
    this.columns = 3,
  });

  final List<NightPanelButtonSpec> buttons;
  final int columns;

  @override
  Widget build(BuildContext context) => NightPanelGrid(
        columns: columns,
        children: <Widget>[
          for (final spec in buttons)
            NightPanelButton(
              key: spec.key,
              label: spec.label,
              onPressed: spec.onPressed,
              disabledReason: spec.disabledReason,
              tooltip: spec.tooltip,
              selected: spec.selected,
              emphasized: spec.emphasized,
              destructive: spec.destructive,
              busy: spec.busy,
            ),
        ],
      );
}

/// [MetricGrid] in three columns, the panel's value grid. Long values
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

/// Equal-width cells in rows of [columns], [NightPanelButton]s mostly.
class NightPanelGrid extends StatelessWidget {
  const NightPanelGrid({
    super.key,
    required this.columns,
    required this.children,
    this.gap = SkotiqTokens.spaceXs,
  });

  final int columns;
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < children.length; start += columns) {
      if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
      rows.add(
        Row(
          children: <Widget>[
            for (var c = 0; c < columns; c++) ...<Widget>[
              if (c > 0) SizedBox(width: gap),
              Expanded(
                child: start + c < children.length
                    ? children[start + c]
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// "Saves to   Skotiq/M74/Ha/": a muted label left, a mono value right.
class NightPanelRow extends StatelessWidget {
  const NightPanelRow({super.key, required this.label, required this.value});

  final String label;

  /// Null renders the kit's unknown dash.
  final String? value;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(
            label,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              value ?? kReadoutUnknown,
              textAlign: TextAlign.end,
              style: SkotiqTypography.monoXs.copyWith(
                color: colors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small caption over a control ("Exposure s", "Frame").
class NightPanelLabel extends StatelessWidget {
  const NightPanelLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Text(
        text,
        style: SkotiqTypography.readoutLabel.copyWith(
          color: context.skotiqColors.textMuted,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Runs a device command from a panel control. A failure shows as a snackbar
/// built from [errorKey] (a `{detail}` string); nothing is retried.
Future<void> nightPanelAttempt(
  BuildContext context,
  String errorKey,
  Future<void> Function() action,
) async {
  final l10n = SkotiqLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await action();
  } catch (error) {
    final detail = userFacingError(error);
    messenger?.showErrorSnackBar(
      l10n.text(errorKey, params: <String, String>{'detail': detail}),
    );
  }
}

List<MetricGridItem> nightMetricItems(
  List<MetricVm> metrics,
  SkotiqLocalizations l10n,
) =>
    <MetricGridItem>[
      for (final m in metrics)
        MetricGridItem(
          label: m.label.resolve(l10n),
          value: m.value,
          delta: m.delta,
          deltaTone: m.deltaTone,
          valueTone: m.valueTone,
        ),
    ];


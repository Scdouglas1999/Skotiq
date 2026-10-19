// The pieces every right-panel tab body is built from: a section with its
// title row, the body that scrolls (or not) the way the layout asks, the
// dense 28 px button, a label/value row and the view-model to kit mappings.
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../night_control_contracts.dart';
import '../night_control_layout.dart';

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
class NightPanelBody extends StatelessWidget {
  const NightPanelBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    final scrolls =
        NightControlDensity.maybeOf(context)?.slotsScrollThemselves ?? true;
    if (!scrolls) return column;
    return SingleChildScrollView(primary: false, child: column);
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
  });

  final String title;

  /// "vs night median", "At setpoint", "no weather source".
  final String? trailing;

  /// Colors [trailing]; null is muted.
  final MetricTone? trailingTone;

  /// Read instead of [trailing] when the note alone would be unclear.
  final String? trailingSemantics;

  final List<Widget> children;
  final bool divider;
  final double gap;

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
          mainAxisSize: MainAxisSize.min,
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
            for (final child in children) ...<Widget>[
              SizedBox(height: gap),
              child,
            ],
          ],
        ),
      ),
    );
  }
}

/// A muted one- or two-line note under a section's controls.
class NightPanelNote extends StatelessWidget {
  const NightPanelNote(this.text, {super.key, this.tone});

  final String text;
  final MetricTone? tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Text(
      text,
      style: SkotiqTypography.captionSm.copyWith(
        color: tone == null ? colors.textMuted : nightToneColor(tone!, colors),
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The panel's 28 px button: a quiet fill, the primary tint when
/// [selected]. Disabled with a [disabledReason] it says why in a tooltip and
/// in its semantics hint.
class NightPanelButton extends StatelessWidget {
  const NightPanelButton({
    super.key,
    required this.label,
    this.onPressed,
    this.selected = false,
    this.disabledReason,
    this.semanticLabel,
    this.mono = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final String? disabledReason;

  /// Read instead of [label] ("Move focuser in 500 steps" for "−500").
  final String? semanticLabel;

  /// Figures in the mono face (jog steps).
  final bool mono;

  static const double height = SkotiqTokens.buttonHeightSm;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final enabled = onPressed != null;
    final fill = selected
        ? colors.primary.withValues(alpha: PanelTabStrip.selectedAlpha)
        : colors.surfaceElevated;
    final ink = selected
        ? colors.textPrimary
        : enabled
            ? colors.textSecondary
            : colors.textMuted;
    final base = mono ? SkotiqTypography.monoSm : SkotiqTypography.labelSm;
    final radius = BorderRadius.circular(SkotiqTokens.radiusLg);

    Widget button = Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel ?? label,
      hint: enabled ? null : disabledReason,
      excludeSemantics: true,
      onTap: onPressed,
      child: SizedBox(
        height: height,
        child: Material(
          color: fill,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onPressed,
            hoverColor: colors.surfaceHover,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceXs,
                ),
                child: Text(
                  label,
                  style: base.copyWith(
                    color: ink,
                    fontWeight: selected ? FontWeight.w600 : null,
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
    );
    if (!enabled) {
      // The other options dim; the selected one stays legible, since it is
      // the value in force (the current filter, the run's frame type).
      if (!selected) {
        button = Opacity(opacity: SkotiqTokens.opacityMuted, child: button);
      }
      if (disabledReason != null) {
        button = Tooltip(message: disabledReason, child: button);
      }
    }
    return button;
  }
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

/// Runs a device command from a panel control. A failure shows as a toast
/// built from [errorKey] (a `{detail}` string); nothing is retried.
Future<void> nightPanelAttempt(
  BuildContext context,
  String errorKey,
  Future<void> Function() action,
) async {
  final l10n = SkotiqLocalizations.of(context);
  final overlay = Overlay.maybeOf(context);
  try {
    await action();
  } catch (error) {
    if (overlay == null || !overlay.mounted) return;
    final detail = nightPanelErrorText(error);
    SkotiqToastHelper.showInOverlay(
      overlay: overlay,
      message: l10n.text(errorKey, params: <String, String>{'detail': detail}),
      severity: SkotiqAlertSeverity.error,
    );
  }
}

/// An error as a sentence: the `Exception:` labels each layer adds on the
/// way up from the driver are peeled off.
String nightPanelErrorText(Object error) {
  final raw = '$error'.trim();
  final label = RegExp(
    r'^(Exception|StateError|Bad state|Operation failed)\s*:\s*',
    caseSensitive: false,
  );
  var text = raw;
  for (var i = 0; i < 4; i++) {
    final peeled = text.replaceFirst(label, '').trim();
    if (peeled == text || peeled.isEmpty) break;
    text = peeled;
  }
  return text;
}

// ---------------------------------------------------------------------------
// Mappings
// ---------------------------------------------------------------------------

Color nightToneColor(MetricTone tone, SkotiqColors colors) => switch (tone) {
      MetricTone.neutral => colors.textPrimary,
      MetricTone.good => colors.success,
      MetricTone.warning => colors.warning,
      MetricTone.bad => colors.error,
    };

MetricGridTone nightGridTone(MetricTone tone) => switch (tone) {
      MetricTone.neutral => MetricGridTone.neutral,
      MetricTone.good => MetricGridTone.good,
      MetricTone.warning => MetricGridTone.warning,
      MetricTone.bad => MetricGridTone.bad,
    };

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
          deltaTone: nightGridTone(m.deltaTone),
          valueTone: nightGridTone(m.valueTone),
        ),
    ];

SeriesChartTone nightChartTone(SeriesTone tone) => switch (tone) {
      SeriesTone.primary => SeriesChartTone.primary,
      SeriesTone.secondary => SeriesChartTone.secondary,
      SeriesTone.tertiary => SeriesChartTone.tertiary,
      SeriesTone.muted => SeriesChartTone.muted,
      SeriesTone.warning => SeriesChartTone.warning,
      SeriesTone.error => SeriesChartTone.error,
    };

/// `HH:mm` of a view-model time, which is already on the operator's clock.
String nightPanelClock(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

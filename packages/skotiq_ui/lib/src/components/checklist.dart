import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// Where a checklist step stands.
enum ChecklistStepState {
  /// Finished. The title is struck through and the disc carries a check.
  done,

  /// The step to do next. The disc takes the accent tint and a halo.
  next,

  /// Not reached yet.
  todo,
}

/// One step of the setup checklist.
@immutable
class ChecklistStep {
  const ChecklistStep({
    required this.title,
    this.detail,
    this.state = ChecklistStepState.todo,
    this.action,
  });

  /// What the operator has to do, in sentence case.
  final String title;

  /// One line of detail.
  final String? detail;

  /// Where this step stands.
  final ChecklistStepState state;

  /// A `secondary sm` button. The page's single primary lives in the hero, not
  /// here.
  final Widget? action;
}

/// The numbered setup list on Tonight — the ONE place a setup problem is
/// stated.
///
/// It replaces ten tour toasts and four catalog nags. Done steps are struck
/// through, the next one is highlighted, and every step that is still open
/// carries its own action.
class Checklist extends StatelessWidget {
  const Checklist({super.key, required this.steps});

  /// The steps, in the order they must be done.
  final List<ChecklistStep> steps;

  /// The numbered disc's diameter.
  static const double discSize = 28;

  /// The halo drawn around the "next" disc.
  static const double haloWidth = 4;

  /// Vertical padding inside a row.
  ///
  /// 14 — `spaceMd + 2`, rounded down from `spaceLg` for density. This is the
  /// row's internal rhythm and 07 rule 3 allows it by name.
  static const double rowPadding = SkotiqTokens.spaceMd + 2;

  /// Gap between the disc and the text.
  static const double gap = SkotiqTokens.spaceMd;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < steps.length; i++)
          _ChecklistRow(
            index: i + 1,
            step: steps[i],
            colors: colors,
            showDivider: i < steps.length - 1,
          ),
      ],
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.index,
    required this.step,
    required this.colors,
    required this.showDivider,
  });

  final int index;
  final ChecklistStep step;
  final SkotiqColors colors;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final done = step.state == ChecklistStepState.done;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: Checklist.rowPadding),
      decoration: showDivider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.border)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _Disc(index: index, state: step.state, colors: colors),
          const SizedBox(width: Checklist.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  step.title,
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: done ? colors.textSecondary : colors.textPrimary,
                    decoration: done ? TextDecoration.lineThrough : null,
                    decorationColor: colors.textSecondary,
                  ),
                ),
                if (step.detail != null)
                  Text(
                    step.detail!,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (step.action != null) ...<Widget>[
            const SizedBox(width: Checklist.gap),
            step.action!,
          ],
        ],
      ),
    );
  }
}

/// The numbered disc at the head of a checklist row.
class _Disc extends StatelessWidget {
  const _Disc({required this.index, required this.state, required this.colors});

  final int index;
  final ChecklistStepState state;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case ChecklistStepState.done:
        return _disc(
          fill: colors.success.withValues(
            alpha: SkotiqTokens.opacityStatusFill,
          ),
          child: Icon(
            LucideIcons.check,
            size: _discGlyphSize,
            color: colors.success,
          ),
        );
      case ChecklistStepState.next:
        return _disc(
          fill: colors.primary.withValues(
            alpha: SkotiqTokens.opacityAccentTintHover,
          ),
          halo: colors.primary.withValues(alpha: SkotiqTokens.opacityHairline),
          child: Text(
            '$index',
            style: SkotiqTypography.readoutBadge
                .apply(fontSizeFactor: _discNumberScale)
                .copyWith(color: colors.primary),
          ),
        );
      case ChecklistStepState.todo:
        return _disc(
          fill: colors.well,
          child: Text(
            '$index',
            style: SkotiqTypography.readoutBadge
                .apply(fontSizeFactor: _discNumberScale)
                .copyWith(color: colors.textMuted),
          ),
        );
    }
  }

  Widget _disc({required Color fill, Color? halo, required Widget child}) {
    return Container(
      width: Checklist.discSize,
      height: Checklist.discSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        boxShadow: halo == null
            ? null
            // A static ring, not a glow and not a pulse: the halo says "this
            // one next" without asking for a frame.
            : <BoxShadow>[
                BoxShadow(color: halo, spreadRadius: Checklist.haloWidth),
              ],
      ),
      child: child,
    );
  }
}

/// The step number is `readoutBadge` at 12px (05 §17), which is that style
/// scaled — never a fontSize literal.
const double _discNumberScale = 12 / 16;

/// The check glyph inside a completed disc.
const double _discGlyphSize = SkotiqTokens.iconXs;

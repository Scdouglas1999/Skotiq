import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Corner radius of a Darkroom panel.
const double darkroomPanelRadius = SkotiqTokens.radiusLg + 2;

/// A Darkroom panel: surface fill, hairline border, a 16px heading with an
/// optional note beside it and actions on the right.
class CalibrationSection extends StatelessWidget {
  const CalibrationSection({
    super.key,
    required this.title,
    required this.child,
    this.note,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? note;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Semantics(
      container: true,
      label: title,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(darkroomPanelRadius),
          border: Border.all(color: colors.border),
        ),
        padding: const EdgeInsets.fromLTRB(
          SkotiqTokens.spaceXl,
          SkotiqTokens.spaceMd + 2,
          SkotiqTokens.spaceXl,
          SkotiqTokens.spaceMd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.end,
                    spacing: SkotiqTokens.spaceMd,
                    runSpacing: SkotiqTokens.spaceXs,
                    children: [
                      Text(
                        title,
                        style: SkotiqTypography.sectionTitle.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      if (note != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            note!,
                            style: SkotiqTypography.caption.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: SkotiqTokens.spaceSm),
                        actions[i],
                      ],
                    ],
                  ),
                ],
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            child,
          ],
        ),
      ),
    );
  }
}

/// One row of a panel list, closed by a hairline.
class CalibrationRow extends StatelessWidget {
  const CalibrationRow({super.key, required this.child, this.last = false});

  final Widget child;

  /// The final row of its list draws no hairline under it.
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm + 1),
        child: child,
      ),
    );
  }
}

/// A quiet label in front of a value: "Dark 90 s", "Bias 50 frames".
class CalibrationLabeled extends StatelessWidget {
  const CalibrationLabeled({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.mono = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
          ),
          TextSpan(
            text: value,
            style: (mono ? SkotiqTypography.monoSm : SkotiqTypography.bodySm)
                .copyWith(color: valueColor ?? colors.textPrimary),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The overline above a group of rows: "DARKS · 4".
class CalibrationOverline extends StatelessWidget {
  const CalibrationOverline(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: SkotiqTokens.spaceMd,
        bottom: SkotiqTokens.spaceXs,
      ),
      child: Text(
        text.toUpperCase(),
        style: SkotiqTypography.monoXs.copyWith(
          color: context.skotiqColors.textMuted,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

/// A short, centered message in a panel with nothing to list.
class CalibrationEmpty extends StatelessWidget {
  const CalibrationEmpty(this.message, {super.key, this.icon});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXl),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: colors.textMuted),
            const SizedBox(width: SkotiqTokens.spaceSm),
          ],
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A checkbox with its label, the whole line tappable.
class CalibrationCheckLine extends StatelessWidget {
  const CalibrationCheckLine({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
          child: Row(
            children: [
              SkotiqCheckbox(
                  value: value, onChanged: (v) => onChanged(v ?? false)),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Flexible(
                child: Text(
                  label,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: context.skotiqColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

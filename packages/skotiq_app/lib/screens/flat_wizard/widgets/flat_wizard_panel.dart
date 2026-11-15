import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A Flat wizard panel: the title with one quiet clause on its baseline and
/// the panel's actions at the right.
class FlatWizardPanel extends StatelessWidget {
  const FlatWizardPanel({
    super.key,
    required this.title,
    required this.child,
    this.note,
    this.actions = const <Widget>[],
  });

  final String title;

  /// One clause after the title, in the muted body style.
  final String? note;

  /// Ghost or icon buttons at the right of the head.
  final List<Widget> actions;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Semantics(
      container: true,
      label: title,
      child: SkotiqPanel(
        head: Row(
          children: [
            Expanded(
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
                    Text(
                      note!,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            for (final action in actions) ...[
              const SizedBox(width: SkotiqTokens.spaceSm),
              action,
            ],
          ],
        ),
        child: child,
      ),
    );
  }
}

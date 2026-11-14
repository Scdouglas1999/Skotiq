// "Next step" on Tonight's Overview: once nothing blocks the rig, the first
// thing to do with it that the operator has neither done nor put aside.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../sequencer/widgets/smart_night_dialog.dart';
import '../panel_widgets.dart';

/// Shows [nextUsePromptProvider]'s step, or nothing when it has none.
class NightNextStepSection extends ConsumerWidget {
  const NightNextStepSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = ref.watch(nextUsePromptProvider);
    if (step == null) return const SizedBox.shrink();
    return NightNextStepView(
      step: step,
      onAction: () => _open(context, step),
      onDismiss: () => nightPanelAttempt(
        context,
        'nightPanelErrNextStepDismiss',
        () => ref
            .read(tutorialProgressDaoProvider)
            .dismissPromptForScreen(nextUsePromptScreenId(step.id)),
      ),
    );
  }

  static void _open(BuildContext context, NextUseStep step) {
    // Smart Night is a dialog over the current screen, not a route, so its
    // step opens the dialog here instead of leaving Tonight.
    if (step.id == NextUseActionId.buildSmartNight) {
      showSmartNightDialog(context);
      return;
    }
    GoRouter.of(context).go(step.deepLinkRoute);
  }
}

/// The section for one [step], apart from the providers so a test can pump it.
class NightNextStepView extends StatelessWidget {
  const NightNextStepView({
    super.key,
    required this.step,
    required this.onAction,
    required this.onDismiss,
  });

  final NextUseStep step;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  static IconData iconFor(String iconKey) => switch (iconKey) {
        'sparkles' => LucideIcons.sparkles,
        'crop' => LucideIcons.crop,
        'crosshair' => LucideIcons.crosshair,
        'focus' => LucideIcons.focus,
        'camera' => LucideIcons.camera,
        _ => LucideIcons.arrowRight,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    return NightPanelSection(
      title: l10n.text('nightPanelNextStep'),
      gap: SkotiqTokens.spaceSm,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                iconFor(step.iconKey),
                size: SkotiqTokens.iconSm,
                color: colors.primary,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    step.title,
                    style: SkotiqTypography.labelStrongSm
                        .copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Text(
                    step.body,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        Wrap(
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceXs,
          children: <Widget>[
            SkotiqButton(
              label: step.actionLabel,
              size: ButtonSize.small,
              variant: ButtonVariant.secondary,
              onPressed: onAction,
            ),
            SkotiqButton(
              label: l10n.text('nightPanelNextStepDismiss'),
              size: ButtonSize.small,
              variant: ButtonVariant.ghost,
              onPressed: onDismiss,
            ),
          ],
        ),
      ],
    );
  }
}

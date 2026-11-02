// The end-of-night calibration's request to cap the telescope, on Tonight.
//
// A filter wheel without a dark slot needs the telescope capped before the
// night's darks and bias. The request used to show only in Settings, so an
// operator watching Tonight never saw the night-end automation stop and wait.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Shown while the end-of-night calibration waits for a cap; hidden otherwise.
class EndOfNightCapBanner extends ConsumerWidget {
  const EndOfNightCapBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(endOfNightCalibrationProvider);
    if (status.phase != EonPhase.waitingForCap) return const SizedBox.shrink();
    final service = ref.read(endOfNightCalibrationProvider.notifier);
    final colors = SkotiqColors.of(context);
    final deadline = status.capDeadline;
    final detail = deadline == null
        ? 'The filter wheel has no dark slot. Put the cap on, then confirm.'
        : 'The filter wheel has no dark slot. Put the cap on, then confirm. '
            'Without a confirmation the darks and bias are skipped at '
            '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(deadline))} '
            'and the night-end steps go on without them.';

    final message = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.aperture, size: 18, color: colors.warning),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Cap the telescope for the end-of-night darks',
                style: SkotiqTypography.labelStrongSm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Text(
                detail,
                style: SkotiqTypography.labelSm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      children: [
        SkotiqButton(
          label: 'The telescope is capped',
          icon: LucideIcons.check,
          size: ButtonSize.small,
          onPressed: service.confirmCapped,
        ),
        SkotiqButton(
          label: 'Skip the darks',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: service.cancel,
        ),
      ],
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.14),
        border: Border(
          top: BorderSide(color: colors.warning, width: 1.5),
          bottom: BorderSide(color: colors.warning.withValues(alpha: 0.6)),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.space2xl,
        vertical: SkotiqTokens.spaceMd,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 640) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                message,
                const SizedBox(height: SkotiqTokens.spaceSm),
                actions,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: message),
              const SizedBox(width: SkotiqTokens.spaceLg),
              actions,
            ],
          );
        },
      ),
    );
  }
}

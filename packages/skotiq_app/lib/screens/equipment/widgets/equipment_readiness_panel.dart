import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/readiness/readiness_panel.dart';
import 'equipment_blocker_row.dart';

/// The Readiness block of the Equipment side panel: a [SectionTitle] with the
/// outstanding count, then one row per item that still needs action.
///
/// Only OUTSTANDING items are listed. A green row per already-satisfied check
/// is the app congratulating itself; the count in the title carries "all
/// clear" in one word, and the checklist on Tonight is where first-light setup
/// is represented in full.
class EquipmentReadinessPanel extends ConsumerWidget {
  const EquipmentReadinessPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final report = ref.watch(readinessReportProvider);

    // The title must count what the list below actually SHOWS. Blocked rows
    // cannot be hidden at all, so only caution rows can go missing — those are
    // subtracted here and reported as dismissed.
    // A BLOCKER cannot be dismissed away. The dismissed set is session state
    // that a caution row writes, but a stale or foreign entry in it must never
    // hide something that is blocking first light — so only cautions are
    // filtered, and the count below counts exactly what is listed.
    final dismissed = ref.watch(dismissedReadinessItemsProvider);
    final items = [
      ...report.blockedItems,
      for (final item in report.cautionItems)
        if (!dismissed.contains(item.id)) item,
    ];
    final hiddenCaution =
        report.cautionItems.where((item) => dismissed.contains(item.id)).length;
    final blockers =
        items.where((item) => item.level == ReadinessLevel.blocked).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionTitle(
          icon: LucideIcons.listChecks,
          title: 'Readiness',
          trailing: SkotiqChip(
            label: _countLabel(items.length, blockers),
            tone: blockers > 0
                ? ChipTone.error
                : items.isEmpty
                    ? ChipTone.success
                    : ChipTone.warning,
          ),
        ),
        if (items.isEmpty)
          EquipmentBlockerRow(
            toneColor: colors.success,
            title: 'Ready for first light',
            detail: hiddenCaution > 0
                ? '$hiddenCaution ${hiddenCaution == 1 ? 'item is' : 'items are'} '
                    'dismissed for this session.'
                : 'Everything first light needs is in place.',
            showDivider: false,
          )
        else
          for (var i = 0; i < items.length; i++)
            EquipmentBlockerRow(
              toneColor: readinessLevelColor(items[i].level, colors),
              title: items[i].title,
              detail: items[i].detail,
              showDivider: i < items.length - 1,
              action: items[i].hasFix
                  ? SkotiqButton(
                      label: items[i].fixLabel!,
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      onPressed: () => context.go(items[i].fixRoute!),
                    )
                  : null,
              trailing: items[i].level == ReadinessLevel.caution
                  ? SkotiqIconButton(
                      icon: LucideIcons.x,
                      tooltip: 'Dismiss for this session',
                      size: IconButtonSize.sm,
                      onPressed: () {
                        final notifier =
                            ref.read(dismissedReadinessItemsProvider.notifier);
                        notifier.state = {...notifier.state, items[i].id};
                      },
                    )
                  : null,
            ),
      ],
    );
  }

  static String _countLabel(int outstanding, int blockers) {
    if (outstanding == 0) return 'All clear';
    if (blockers > 0) {
      return '$blockers ${blockers == 1 ? 'blocker' : 'blockers'}';
    }
    return '$outstanding to review';
  }
}

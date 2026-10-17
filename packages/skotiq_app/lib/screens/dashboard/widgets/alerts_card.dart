import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../widgets/operation_status_bar.dart';
import 'glass_card.dart';

class AlertsCard extends ConsumerWidget {
  final SkotiqColors colors;

  const AlertsCard({super.key, required this.colors});

  SkotiqAlertSeverity _mapSeverity(UiNotificationLevel level) {
    return switch (level) {
      UiNotificationLevel.info => SkotiqAlertSeverity.info,
      UiNotificationLevel.success => SkotiqAlertSeverity.success,
      UiNotificationLevel.warning => SkotiqAlertSeverity.warning,
      UiNotificationLevel.error => SkotiqAlertSeverity.error,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(uiNotificationProvider);
    final hasOperation = ref.watch(hasActiveOperationProvider);
    final recent =
        notifications.reversed.take(2).toList(); // Show fewer in compact

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.bell,
            title: 'Alerts',
            accent: hasOperation || notifications.isNotEmpty
                ? colors.warning
                : null,
            trailing: notifications.isNotEmpty
                ? SkotiqButton(
                    onPressed: () =>
                        ref.read(uiNotificationProvider.notifier).clearAll(),
                    label: 'Clear',
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                  )
                : null,
          ),
          const SizedBox(height: DashboardCardStyle.headerGap),
          if (hasOperation) ...[
            const OperationStatusBar(),
            const SizedBox(height: 8),
          ],
          if (recent.isEmpty && !hasOperation)
            Text(
              'No active alerts.',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            )
          else
            Column(
              children: recent
                  .map(
                    (notification) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SkotiqAlert(
                        message: notification.message,
                        title: notification.title,
                        severity: _mapSeverity(notification.level),
                        compact: true,
                        onDismiss: () => ref
                            .read(uiNotificationProvider.notifier)
                            .dismiss(notification.id),
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }
}

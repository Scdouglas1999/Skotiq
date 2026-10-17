import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'run_dashboard_format.dart';
import 'run_dashboard_providers.dart';

/// Persistent banner above the Run Dashboard for **critical** executor
/// events that the user must not miss.
///
/// The Trigger Feed only shows the last 5 events, so a critical one scrolls off
/// in seconds — and the operator is often away from the laptop for an hour.
/// Critical events also route to `uiNotificationProvider` and, when
/// `audibleAlertsOnCritical` is set, to a system bell; this banner is the
/// visual signal.
///
/// NO TIMEOUT: the banner stays until the user dismisses it. The most-recent
/// event shows prominently and older ones collapse to a "+N more" pill.
class RunDashboardCriticalBanner extends ConsumerStatefulWidget {
  const RunDashboardCriticalBanner({super.key});

  @override
  ConsumerState<RunDashboardCriticalBanner> createState() =>
      _RunDashboardCriticalBannerState();
}

class _RunDashboardCriticalBannerState
    extends ConsumerState<RunDashboardCriticalBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final events = ref.watch(runDashboardCriticalEventsProvider);
    final droppedCount = ref.watch(runDashboardDroppedCriticalCountProvider);
    if (events.isEmpty) return const SizedBox.shrink();

    final head = events.first;
    final tail = events.skip(1).toList(growable: false);

    return Container(
      width: double.infinity,
      decoration: SkotiqDecorations.statusChip(
        colors.error,
        borderRadius: BorderRadius.zero,
        bordered: false,
      ).copyWith(
        border: Border(
          top: BorderSide(color: colors.error, width: 1.5),
          bottom: BorderSide(color: colors.error.withValues(alpha: 0.6)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BannerRow(
            colors: colors,
            event: head,
            onDismiss: () => ref
                .read(runDashboardCriticalEventsProvider.notifier)
                .dismiss(head.eventId),
            trailing: tail.isEmpty
                ? null
                : _MorePill(
                    colors: colors,
                    count: tail.length,
                    expanded: _expanded,
                    onToggle: () => setState(() => _expanded = !_expanded),
                  ),
          ),
          if (_expanded)
            for (final e in tail)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: colors.error.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                child: _BannerRow(
                  colors: colors,
                  event: e,
                  compact: true,
                  onDismiss: () => ref
                      .read(runDashboardCriticalEventsProvider.notifier)
                      .dismiss(e.eventId),
                ),
              ),
          if (droppedCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.space2xl,
                SkotiqTokens.spaceXs,
                SkotiqTokens.space2xl,
                SkotiqTokens.spaceXs,
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.archive,
                    size: 12,
                    color: colors.error.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      '+$droppedCount earlier critical '
                      'event${droppedCount == 1 ? '' : 's'} not shown',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        fontWeight: FontWeight.w600,
                        color: colors.error.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (events.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.space2xl,
                0,
                SkotiqTokens.space2xl,
                SkotiqTokens.spaceSm,
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => ref
                      .read(runDashboardCriticalEventsProvider.notifier)
                      .clearAll(),
                  icon: const Icon(LucideIcons.checkCheck, size: 14),
                  label: const Text('Dismiss all'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BannerRow extends StatelessWidget {
  final SkotiqColors colors;
  final RunDashboardEvent event;
  final VoidCallback onDismiss;
  final Widget? trailing;
  final bool compact;

  const _BannerRow({
    required this.colors,
    required this.event,
    required this.onDismiss,
    this.trailing,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final padding = compact
        ? const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.space2xl,
            vertical: SkotiqTokens.spaceSm,
          )
        : const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.space2xl,
            vertical: SkotiqTokens.spaceMd,
          );
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.alertOctagon,
            color: colors.error,
            size: compact ? 16 : 20,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      event.category,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize9,
                        fontWeight: FontWeight.w800,
                        color: colors.error,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        event.title,
                        style: TextStyle(
                          fontSize: compact
                              ? SkotiqTypography.fontSize12
                              : SkotiqTypography.fontSize14,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatTimeOfDay(event.time),
                      style: SkotiqTypography.withTabular(
                        SkotiqTypography.captionSm.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                if (event.message.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.message,
                    style: TextStyle(
                      fontSize: compact
                          ? SkotiqTypography.fontSize11
                          : SkotiqTypography.fontSize12,
                      color: colors.textSecondary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          if (trailing != null) ...[
            trailing!,
            const SizedBox(width: SkotiqTokens.spaceSm),
          ],
          IconButton(
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            icon: const Icon(LucideIcons.x, size: 16),
            color: colors.textSecondary,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

class _MorePill extends StatelessWidget {
  final SkotiqColors colors;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const _MorePill({
    required this.colors,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          border: Border.all(color: colors.error.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
              size: 12,
              color: colors.error,
            ),
            const SizedBox(width: 4),
            Text(
              '+$count more',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                fontWeight: FontWeight.w700,
                color: colors.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

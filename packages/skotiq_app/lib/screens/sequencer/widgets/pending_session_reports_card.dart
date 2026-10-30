import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'session_report_dialog.dart';

/// The Session Reports an unattended night queued instead of opening.
///
/// A report for a run the autopilot dispatched would otherwise arrive as a
/// modal over whatever screen the operator was on, one per re-dispatch. They
/// queue instead (see `sessionReportPresentationProvider`), and this card is
/// where they come back — without it the queue is where reports go to be
/// forgotten, and the "open it from Sequencer ▸ History" notice is a false
/// claim.
///
/// Renders nothing when the queue is empty, so a hand-driven night never sees
/// it.
class PendingSessionReportsCard extends ConsumerWidget {
  const PendingSessionReportsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final pending = ref.watch(pendingSessionReportsProvider);
    if (pending.isEmpty) return const SizedBox.shrink();

    final time = DateFormat.Hm();
    // Newest first: the last run of the night is the one being asked about.
    final ordered = pending.reversed.toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.inbox, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ordered.length == 1
                      ? '1 session report from unattended imaging'
                      : '${ordered.length} session reports from unattended '
                          'imaging',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize15,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              SkotiqButton(
                label: 'Dismiss all',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () =>
                    ref.read(pendingSessionReportsProvider.notifier).clear(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'These ran while the autopilot held the rig, so they were not '
            'opened over your work.',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize13,
                color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          for (final report in ordered)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Finished ${time.format(report.endedAt)}',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  SkotiqButton(
                    label: 'Open report',
                    icon: LucideIcons.fileText,
                    variant: ButtonVariant.outline,
                    size: ButtonSize.small,
                    onPressed: () {
                      // Retire it as it is opened: a report the operator has
                      // seen must not reappear in the queue.
                      ref
                          .read(pendingSessionReportsProvider.notifier)
                          .remove(report);
                      SessionReportDialog.show(
                        context,
                        report.sessionId,
                        runId: report.runId,
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

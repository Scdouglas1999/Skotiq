import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'session_report_dialog.dart';

/// The session reports an unattended night queued instead of opening over
/// whatever the operator was doing (see `sessionReportPresentationProvider`).
/// Shown at the top of Analytics > History; renders nothing when the queue is
/// empty.
class PendingSessionReportsCard extends ConsumerWidget {
  const PendingSessionReportsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final pending = ref.watch(pendingSessionReportsProvider);
    if (pending.isEmpty) return const SizedBox.shrink();

    // Newest first: the last run of the night is the one being asked about.
    final ordered = pending.reversed.toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: SkotiqPanel(
        head: PanelHead(
          icon: LucideIcons.inbox,
          label: ordered.length == 1
              ? '1 session report from unattended imaging'
              : '${ordered.length} session reports from unattended imaging',
          trailing: [
            SkotiqButton(
              label: 'Dismiss all',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () =>
                  ref.read(pendingSessionReportsProvider.notifier).clear(),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'These ran while the autopilot held the rig, so they were not '
              'opened over your work.',
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            for (final (index, report) in ordered.indexed)
              ListRow(
                title: 'Finished ${ClockFormat.hm(report.endedAt.toLocal())}',
                showDivider: index < ordered.length - 1,
                trailingWidget: SkotiqButton(
                  label: 'Open report',
                  icon: LucideIcons.fileText,
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: () {
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
              ),
          ],
        ),
      ),
    );
  }
}

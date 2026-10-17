import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'campaign_rollup_dialog.dart';
import 'science_session_summary.dart' show scienceSessionTargetIdProvider;

/// Compact multi-night campaign summary for the Science tab.
///
/// Surfaces progress toward integration goals across every session on the
/// active target — the same data as [CampaignRollupDialog] without forcing a
/// modal first.
class ScienceCampaignStrip extends ConsumerWidget {
  const ScienceCampaignStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final active = ref.watch(sessionStateProvider).dbSessionId;
    final sessions = ref.watch(allSessionsProvider).valueOrNull;
    final sessionId = active ??
        ((sessions == null || sessions.isEmpty) ? null : sessions.first.id);
    final targetId = sessionId == null
        ? null
        : ref.watch(scienceSessionTargetIdProvider(sessionId)).valueOrNull;
    if (targetId == null) return const SizedBox.shrink();

    final rollupAsync = ref.watch(campaignRollupProvider(targetId));
    return rollupAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (rollup) {
        if (rollup.sessions.isEmpty) return const SizedBox.shrink();
        final filters = rollup.filters;
        final primary = filters.isNotEmpty ? filters.first : null;
        final pct = primary?.percentComplete;
        final pctLabel = pct == null ? null : '${(pct * 100).round()}%';

        return Semantics(
          button: true,
          enabled: true,
          child: SkotiqCard(
            onTap: () => CampaignRollupDialog.show(context, targetId),
            padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
            child: Row(
              children: [
                Icon(LucideIcons.history, size: 16, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rollup.targetName,
                        style: SkotiqTypography.bodyStrong
                            .copyWith(color: colors.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${rollup.sessions.length} session'
                        '${rollup.sessions.length == 1 ? "" : "s"}'
                        '${primary != null ? " · ${primary.filter}" : ""}'
                        '${primary != null ? " · ${primary.capturedFrames} frames" : ""}'
                        '${pctLabel != null ? " · $pctLabel of goal" : ""}',
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (pct != null) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(
                      value: pct.clamp(0.0, 1.0),
                      strokeWidth: 5,
                      backgroundColor: colors.well,
                      color: colors.primary,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Icon(
                  LucideIcons.chevronRight,
                  size: 16,
                  color: colors.textMuted,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../sequencer/run_status_presentation.dart';
import '../glass_card.dart';

/// Recap of the most recent sequence run: status, name, relative time, and —
/// when the stored stats blob parses — a row of stat chips (integration time,
/// frames, rejections, duration). Falls back to the bare status row when the
/// stats JSON is missing or malformed, and to a friendly one-liner when there
/// are no runs yet.
class LastNightRecapCard extends ConsumerWidget {
  final SkotiqColors colors;

  const LastNightRecapCard({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runsAsync = ref.watch(sequenceRunsProvider);
    // watchAllRuns() orders by startedAt desc, so the head is the newest run.
    final lastRun = runsAsync.maybeWhen(
      data: (runs) => runs.isEmpty ? null : runs.first,
      orElse: () => null,
    );
    // Only claim "Last night" when the run genuinely was last night; a
    // weeks-old run under that header reads as a stale-data bug.
    final isRecent = lastRun != null &&
        DateTime.now().difference(lastRun.startedAt) <
            const Duration(hours: 24);

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.history,
            title: context.l10n.text(isRecent ? 'dbLastNight' : 'dbLastRun'),
            accent: colors.textMuted,
          ),
          const SizedBox(height: DashboardCardStyle.headerGap),
          if (lastRun == null)
            Text(
              context.l10n.text('dbNoRunsYet'),
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textMuted,
              ),
            )
          else
            _runBody(context, ref, lastRun),
        ],
      ),
    );
  }

  Widget _runBody(BuildContext context, WidgetRef ref, SequenceRun run) {
    final stats = _tryParse(run.statsJson);
    // Watched during build, not read inside the tap handler: read at tap time
    // the family provider is still `AsyncLoading`, so the very first click
    // would always take the no-session fallback.
    final sessionId =
        ref.watch(sequenceRunSessionIdProvider(run.id)).valueOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(_statusIcon(run.status),
                size: 16, color: _statusColor(run.status, colors)),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                run.sequenceName,
                style: SkotiqTypography.body.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${_statusLabel(context, run.status)} · '
          '${_relativeTime(context, run.startedAt)}',
          style: SkotiqTypography.withTabular(
            SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ),
        if (stats != null) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              _StatChip(
                colors: colors,
                icon: LucideIcons.timer,
                value: stats.formatDuration(stats.integrationSecs),
                label: context.l10n.text('dbIntegration'),
              ),
              _StatChip(
                colors: colors,
                icon: LucideIcons.image,
                value: '${stats.framesCaptured}',
                label: context.l10n.text('dbFrames'),
              ),
              if (stats.framesRejected > 0)
                _StatChip(
                  colors: colors,
                  icon: LucideIcons.xCircle,
                  value: '${stats.framesRejected}',
                  label: context.l10n.text('dbRejected'),
                  tint: colors.warning,
                ),
              _StatChip(
                colors: colors,
                icon: LucideIcons.clock,
                value: stats.formatDuration(stats.wallClockSecs),
                label: context.l10n.text('dbDuration'),
              ),
            ],
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceMd),
        Align(
          alignment: Alignment.centerRight,
          child: SkotiqButton(
            label: context.l10n.text('dbOpenLastRun'),
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            // A button on a card must not promise less than the card: the
            // body around it deep-links this run to its Session Review, so the
            // button cannot land on the empty Sequence BUILDER. Same resolution
            // the Morning Report tile uses: the run's session when it has one,
            // the History tab when it does not.
            onPressed: () => context.go(_openLastRunDestination(sessionId)),
          ),
        ),
      ],
    );
  }

  /// Where "Open last run" goes: the run's own Session Review when the run
  /// produced a session, otherwise the Sequencer's History TAB (never the
  /// builder).
  static String _openLastRunDestination(int? sessionId) => sessionId == null
      ? '/sequencer?tab=history'
      : '/session-review?session=$sessionId';

  /// Defensive parse: the stored blob may be empty/null/malformed. Any failure
  /// → null so we degrade to the bare status row instead of throwing.
  ParsedRunStats? _tryParse(String json) {
    if (json.isEmpty) return null;
    try {
      final parsed = ParsedRunStats.fromJson(json);
      // A run with zero frames and zero wall-clock carries no useful chips.
      if (parsed.framesCaptured == 0 && parsed.wallClockSecs <= 0) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'completed':
        return LucideIcons.checkCircle;
      case 'failed':
        return LucideIcons.xCircle;
      case 'aborted':
        return LucideIcons.octagon;
      case 'running':
        return LucideIcons.activity;
      default:
        return LucideIcons.history;
    }
  }

  Color _statusColor(String status, SkotiqColors colors) {
    switch (status) {
      case 'completed':
        return colors.success;
      case 'failed':
      case 'aborted':
        return colors.error;
      case 'running':
        return colors.info;
      default:
        return colors.textMuted;
    }
  }

  String _statusLabel(BuildContext context, String status) {
    final l10n = context.l10n;
    switch (status) {
      case 'completed':
        return l10n.text('dbRunCompleted');
      case 'failed':
        return l10n.text('dbRunFailed');
      case 'aborted':
        return l10n.text('dbRunAborted');
      case 'running':
        return l10n.text('dbRunRunning');
      default:
        // Raw status tokens are schema vocabulary, not operator copy — a
        // capitalised "Paused-stopped" claims a pause that never happened.
        // [runStatusLabel] is the one mapping every surface shares, and it
        // owns the readable degradation for a status it does not know.
        if (status.isEmpty) return l10n.text('dbRunUnknown');
        return runStatusLabel(status);
    }
  }

  String _relativeTime(BuildContext context, DateTime when) {
    final l10n = context.l10n;
    String plural(int value, String oneKey, String manyKey) => value == 1
        ? l10n.text(oneKey)
        : l10n.text(manyKey, params: {'value': '$value'});

    final diff = DateTime.now().difference(when);
    if (diff.isNegative || diff.inMinutes < 1) return l10n.text('dbJustNow');
    if (diff.inMinutes < 60) {
      return plural(diff.inMinutes, 'dbMinuteAgo', 'dbMinutesAgo');
    }
    if (diff.inHours < 24) {
      return plural(diff.inHours, 'dbHourAgo', 'dbHoursAgo');
    }
    final d = diff.inDays;
    if (d < 30) return plural(d, 'dbDayAgo', 'dbDaysAgo');
    return plural((d / 30).floor(), 'dbMonthAgo', 'dbMonthsAgo');
  }
}

class _StatChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String value;
  final String label;
  final Color? tint;

  const _StatChip({
    required this.colors,
    required this.icon,
    required this.value,
    required this.label,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final accent = tint ?? colors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: accent),
          const SizedBox(width: 6),
          Text(
            value,
            style: SkotiqTypography.withTabular(
              SkotiqTypography.labelStrongSm.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

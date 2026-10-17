import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../sequencer/widgets/session_report_dialog.dart';
import 'adaptive_chart_container.dart';

/// Multi-night campaign rollup dialog (Feature B).
///
/// Opens from the project tracking panel; renders per-filter goal progress,
/// session count + date range, mean HFR / seeing / effective imaging, and a
/// session list with deep-links into the per-session report (Feature A).
class CampaignRollupDialog extends ConsumerWidget {
  final int targetId;

  const CampaignRollupDialog({super.key, required this.targetId});

  static Future<void> show(BuildContext context, int targetId) {
    return showDialog<void>(
      context: context,
      builder: (_) => CampaignRollupDialog(targetId: targetId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final rollupAsync = ref.watch(campaignRollupProvider(targetId));

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 720,
          designMaxHeight: 760,
        ),
        child: rollupAsync.when(
          data: (rollup) => _Body(rollup: rollup, colors: colors),
          loading: () => AdaptiveChartContainer.fixed(
            height: 200,
            child: Center(
              child: CircularProgressIndicator(color: colors.primary),
            ),
          ),
          error: (err, _) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.alertTriangle, size: 32, color: colors.error),
                const SizedBox(height: 12),
                Text(
                  'Could not build campaign rollup',
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 6),
                Text(
                  '$err',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textMuted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final CampaignRollup rollup;
  final SkotiqColors colors;

  const _Body({required this.rollup, required this.colors});

  String _formatHours(double seconds) {
    final hours = seconds / 3600.0;
    return '${hours.toStringAsFixed(1)}h';
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return kReadoutUnknown;
    return DateFormat('MMM d, yyyy').format(dt);
  }

  String _formatDateTime(DateTime dt) =>
      DateFormat('MMM d, yyyy HH:mm').format(dt);

  @override
  Widget build(BuildContext context) {
    final totalPct = rollup.totalPercentComplete;
    // The card describes three different populations.
    // `totalCapturedIntegrationSecs` and the per-filter table count ACCEPTED
    // light frames; the session rows print each session's own
    // `total_integration_secs`, which counts everything it captured. Both
    // numbers are computed here so the card can name them rather than
    // contradict itself.
    final capturedSecs = rollup.sessions
        .fold<double>(0, (sum, s) => sum + s.sessionIntegrationSecs);
    final acceptedSecs = rollup.totalCapturedIntegrationSecs;
    // Effective imaging only has closed sessions as inputs; with none, the
    // service's `?? 0.0` turns "nothing to measure" into a measured 0%.
    final hasClosedSession = rollup.sessions
        .any((s) => s.endTime != null && s.sessionIntegrationSecs > 0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.target, size: 22, color: colors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Campaign Rollup',
                      style: SkotiqTypography.sectionTitle.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600),
                    ),
                    Text(
                      rollup.targetName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              SkotiqIconButton(
                icon: LucideIcons.x,
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Summary cards.
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _SummaryTile(
                      label: 'Sessions',
                      value: '${rollup.sessionCount}',
                      colors: colors,
                    ),
                    _SummaryTile(
                      label: 'Integration (accepted)',
                      value: _formatHours(acceptedSecs),
                      colors: colors,
                    ),
                    // Only shown when the two disagree, i.e. when frames were
                    // rejected or have not been graded — otherwise it would
                    // repeat the tile beside it.
                    if (capturedSecs - acceptedSecs > 1)
                      _SummaryTile(
                        label: 'Integration (captured)',
                        value: _formatHours(capturedSecs),
                        colors: colors,
                      ),
                    _SummaryTile(
                      label: 'First session',
                      value: _formatDate(rollup.firstSessionAt),
                      colors: colors,
                    ),
                    _SummaryTile(
                      label: 'Last session',
                      value: _formatDate(rollup.lastSessionAt),
                      colors: colors,
                    ),
                    // Named for their population too: these come from each
                    // session's own avg_hfr / avg_seeing columns, which count
                    // every frame the session took, not the accepted subset the
                    // integration tile and the per-filter table describe.
                    _SummaryTile(
                      label: 'Mean HFR (session avg)',
                      value: rollup.meanSessionHfr?.toStringAsFixed(2) ??
                          kReadoutUnknown,
                      colors: colors,
                    ),
                    _SummaryTile(
                      label: 'Mean seeing (session avg)',
                      value: rollup.meanSessionSeeing != null
                          ? '${rollup.meanSessionSeeing!.toStringAsFixed(2)}"'
                          : kReadoutUnknown,
                      colors: colors,
                    ),
                    _SummaryTile(
                      label: 'Effective imaging',
                      value: hasClosedSession
                          ? '${(rollup.meanEffectiveImagingFraction * 100).toStringAsFixed(1)}%'
                          : kReadoutUnknown,
                      colors: colors,
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Overall progress.
                if (totalPct != null) ...[
                  _OverallProgress(
                    pct: totalPct,
                    captured: rollup.totalCapturedIntegrationSecs,
                    goal: rollup.totalGoalIntegrationSecs ?? 0,
                    colors: colors,
                    isComplete: rollup.isComplete,
                  ),
                  const SizedBox(height: 16),
                ],

                _SectionTitle(
                  title: 'Per-filter progress',
                  icon: LucideIcons.layers,
                  colors: colors,
                ),
                if (rollup.filters.isEmpty)
                  Text(
                    capturedSecs > 0
                        // The table counts accepted frames, so "no frames
                        // captured" would be false for a target whose whole
                        // night was rejected in the grader.
                        ? 'No accepted frames yet — '
                            '${_formatHours(capturedSecs)} captured across '
                            '${rollup.sessionCount} '
                            '${rollup.sessionCount == 1 ? 'session' : 'sessions'}'
                            ' was rejected or has not been graded.'
                        : 'No frames captured for this target yet.',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textMuted),
                  )
                else
                  for (final f in rollup.filters)
                    _FilterRow(filter: f, colors: colors),

                const SizedBox(height: 16),
                _SectionTitle(
                  title: 'Sessions',
                  icon: LucideIcons.history,
                  colors: colors,
                ),
                if (rollup.sessions.isEmpty)
                  Text(
                    'No sessions recorded for this target.',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textMuted),
                  )
                else
                  for (final s in rollup.sessions)
                    _SessionRow(
                      session: s,
                      colors: colors,
                      onOpenReport: () =>
                          SessionReportDialog.show(context, s.sessionId),
                      formatDateTime: _formatDateTime,
                    ),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Close',
                  style: SkotiqTypography.body
                      .copyWith(color: colors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  final SkotiqColors colors;

  const _SectionTitle({
    required this.title,
    required this.icon,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: colors.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
                letterSpacing: 0.3,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const _SummaryTile({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 140),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style:
                    SkotiqTypography.caption.copyWith(color: colors.textMuted)),
            const SizedBox(height: 4),
            Text(
              value,
              style: SkotiqTypography.readoutSm.copyWith(
                  color: colors.textPrimary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverallProgress extends StatelessWidget {
  final double pct;
  final double captured;
  final double goal;
  final bool isComplete;
  final SkotiqColors colors;

  const _OverallProgress({
    required this.pct,
    required this.captured,
    required this.goal,
    required this.isComplete,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final remaining = goal - captured;
    final remainingHours = remaining > 0 ? remaining / 3600.0 : 0.0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Overall',
                style: SkotiqTypography.bodyStrong.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${(pct * 100).toStringAsFixed(1)}%',
                style: SkotiqTypography.bodySm.copyWith(
                    color: isComplete ? colors.success : colors.textPrimary,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 10,
              backgroundColor: colors.surface,
              valueColor: AlwaysStoppedAnimation<Color>(
                isComplete ? colors.success : colors.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            // "Accepted", because `captured` is CampaignRollup's accepted-only
            // total. Saying "Captured" here put the card back where it started:
            // the session rows below now use that same word for every frame the
            // session took, so one card would read "Captured 0.0h" over
            // "0.17h captured".
            'Accepted ${(captured / 3600.0).toStringAsFixed(1)}h of ${(goal / 3600.0).toStringAsFixed(1)}h goal | Remaining: ${remainingHours.toStringAsFixed(1)}h',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final CampaignFilterRollup filter;
  final SkotiqColors colors;

  const _FilterRow({required this.filter, required this.colors});

  @override
  Widget build(BuildContext context) {
    final pct = filter.percentComplete;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                filter.filter,
                style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textPrimary, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              // CampaignFilterRollup.capturedFrames counts ACCEPTED light
              // frames only, so both branches have to say so — the empty state
              // beside them already does, and the session rows use "captured"
              // for the unfiltered total.
              if (filter.hasGoal)
                Flexible(
                  child: Text(
                    '${filter.capturedFrames}/${filter.goalFrames} frames accepted',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                  ),
                )
              else
                Flexible(
                  child: Text(
                    '${filter.capturedFrames} frames accepted (no goal)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                  ),
                ),
              const Spacer(),
              Text(
                '${(filter.capturedIntegrationSecs / 3600.0).toStringAsFixed(1)}h',
                style: SkotiqTypography.bodyStrong.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
          if (pct != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 6,
                backgroundColor: colors.well,
                valueColor: AlwaysStoppedAnimation<Color>(
                  pct >= 1.0 ? colors.success : colors.primary,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(pct * 100).toStringAsFixed(0)}% complete | ${filter.remainingFrames} frames remaining',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  final CampaignSessionRef session;
  final SkotiqColors colors;
  final VoidCallback onOpenReport;
  final String Function(DateTime) formatDateTime;

  const _SessionRow({
    required this.session,
    required this.colors,
    required this.onOpenReport,
    required this.formatDateTime,
  });

  Color _statusColor() {
    switch (session.status.toLowerCase()) {
      case 'completed':
        return colors.success;
      case 'active':
        return colors.info;
      case 'aborted':
      case 'stopped':
        return colors.warning;
      case 'error':
      case 'failed':
        return colors.error;
      default:
        return colors.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final durationSecs = session.wallClockDuration.inSeconds;
    final durationLabel = durationSecs > 0
        ? '${(durationSecs / 3600.0).toStringAsFixed(2)}h wall'
        : kReadoutUnknown;
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
          button: true,
          enabled: true,
          child: InkWell(
            onTap: onOpenReport,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _statusColor(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.sessionName ?? 'Session ${session.sessionId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SkotiqTypography.labelStrong.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          // "captured", not "integration": this is the session's
                          // own total across every frame it took, while the header
                          // tile and the per-filter table above count only frames
                          // that survived grading.
                          '${formatDateTime(session.startTime)} | $durationLabel | ${(session.sessionIntegrationSecs / 3600.0).toStringAsFixed(2)}h captured',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  if (session.avgHfr != null)
                    _Chip(
                      label: 'HFR',
                      value: session.avgHfr!.toStringAsFixed(2),
                      colors: colors,
                    ),
                  const SizedBox(width: 6),
                  if (session.avgGuidingRms != null)
                    _Chip(
                      label: 'RMS',
                      value: session.avgGuidingRms!.toStringAsFixed(2),
                      colors: colors,
                    ),
                  const SizedBox(width: 6),
                  Icon(LucideIcons.chevronRight,
                      size: 16, color: colors.textMuted),
                ],
              ),
            ),
          )),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const _Chip({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
          Text(
            value,
            style: SkotiqTypography.labelStrongSm.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

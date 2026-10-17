/// Frame-Failure Forensics: Run Dashboard panel.
///
/// Opt-in panel that lists recent rejections grouped by `LikelyCause`.
/// Color-coded rows; tapping a row opens the [FrameDetailDialog] with
/// the full evidence breakdown + image preview.
///
/// The panel listens to two sources:
///
/// * [forensicsRecordsForSessionProvider] for the backfill (records
///   already persisted from earlier in the session).
/// * [forensicsStreamProvider] for live updates as new rejections
///   arrive — the panel folds new records into the backfilled list so
///   the user sees rejections in real time.
///
/// Hidden when no records exist yet — keeps an idle dashboard clean.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'frame_detail_dialog.dart';

/// Color assignments per [LikelyCause]. The Forensics panel uses these
/// for the row indicator bars; the post-session report uses them for
/// the cause-distribution stacked bar.
Color forensicsCauseColor(LikelyCause cause, SkotiqColors colors) {
  switch (cause) {
    case LikelyCause.cloudPassage:
      return colors.textMuted;
    case LikelyCause.seeingSpike:
      return colors.warning;
    case LikelyCause.guidingFailure:
      return colors.error;
    case LikelyCause.windGust:
      return colors.accent;
    case LikelyCause.satellitePass:
      return colors.info;
    case LikelyCause.hotPixelOrCosmic:
      return colors.warning;
    case LikelyCause.focusDrift:
      return colors.error;
    case LikelyCause.unknown:
      return colors.textSecondary;
  }
}

class RunDashboardForensicsPanel extends ConsumerWidget {
  /// Active session id (drives the backfill provider). When `null` the
  /// panel only shows live events.
  final String? sessionId;

  const RunDashboardForensicsPanel({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final backfillAsync =
        ref.watch(forensicsRecordsForSessionProvider(sessionId));
    final liveAsync = ref.watch(forensicsStreamProvider);

    return backfillAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, st) => _ErrorBanner(message: e.toString(), colors: colors),
      data: (backfilled) {
        // Merge live event (if any) on top of the backfilled list,
        // de-duplicating by id.
        final merged = <String, FrameForensicsRecord>{
          for (final r in backfilled) r.id: r,
        };
        liveAsync.whenData((rec) {
          if (sessionId == null || rec.sessionId == sessionId) {
            merged[rec.id] = rec;
          }
        });
        final records = merged.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (records.isEmpty) {
          return const SizedBox.shrink();
        }
        final summary = ForensicsService.summarize(records);
        return _ForensicsPanelBody(
          records: records,
          summary: summary,
          colors: colors,
        );
      },
    );
  }
}

class _ForensicsPanelBody extends StatelessWidget {
  final List<FrameForensicsRecord> records;
  final ForensicSummary summary;
  final SkotiqColors colors;

  const _ForensicsPanelBody({
    required this.records,
    required this.summary,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(LucideIcons.search, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'WHY DID THIS FRAME FAIL?',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colors.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                '${summary.total} rejection${summary.total == 1 ? '' : 's'}',
                style: SkotiqTypography.withTabular(
                  SkotiqTypography.labelQuiet.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          // Cause distribution row: tiny stacked bar with counts.
          _CauseDistributionBar(summary: summary, colors: colors),
          const SizedBox(height: SkotiqTokens.spaceMd),
          // Up to 8 most recent rejections — older rejects are
          // surfaced via the History tab's post-session report.
          ...records
              .take(8)
              .map((r) => _ForensicsRow(record: r, colors: colors)),
        ],
      ),
    );
  }
}

class _CauseDistributionBar extends StatelessWidget {
  final ForensicSummary summary;
  final SkotiqColors colors;

  const _CauseDistributionBar({required this.summary, required this.colors});

  @override
  Widget build(BuildContext context) {
    if (summary.isEmpty) return const SizedBox.shrink();
    final entries = summary.rankedCauses;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: entries.map((e) {
            final flex = (e.value * 100).clamp(1, 1000);
            return Expanded(
              flex: flex,
              child: Container(
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: forensicsCauseColor(e.key, colors),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusXs),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Wrap(
          spacing: SkotiqTokens.spaceMd,
          runSpacing: 4,
          children: entries.map((e) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: forensicsCauseColor(e.key, colors),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline2),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${e.key.humanLabel} (${e.value})',
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.labelQuiet.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _ForensicsRow extends StatelessWidget {
  final FrameForensicsRecord record;
  final SkotiqColors colors;

  const _ForensicsRow({required this.record, required this.colors});

  @override
  Widget build(BuildContext context) {
    final causeColor = forensicsCauseColor(record.likelyCause, colors);
    return InkWell(
      onTap: () {
        showDialog<void>(
          context: context,
          builder: (_) => FrameDetailDialog(record: record),
        );
      },
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceSm,
          vertical: SkotiqTokens.spaceSm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 3,
              height: 32,
              margin: const EdgeInsets.only(right: SkotiqTokens.spaceMd),
              decoration: BoxDecoration(
                color: causeColor,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline2),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        record.likelyCause.humanLabel,
                        style:
                            SkotiqTypography.h6.copyWith(color: causeColor),
                      ),
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      Text(
                        'Frame ${record.frameIndex}/${record.totalFrames}',
                        style: SkotiqTypography.withTabular(
                          SkotiqTypography.labelQuiet.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatTime(record.createdAt),
                        style: SkotiqTypography.withTabular(
                          SkotiqTypography.labelQuiet.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    record.reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 14, color: colors.textMuted),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final SkotiqColors colors;

  const _ErrorBanner({required this.message, required this.colors});

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              'Forensics unavailable: $message',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

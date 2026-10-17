// TargetScheduler Run Dashboard panel.
//
// This panel consumes the typed `SequencerEvent.schedulerDecision` variant
// produced by the bridge's `typed_sequencer_event_from_progress_detail`
// dispatch. Every field (picked target, score, full score table) survives the
// FRB boundary as typed data; nothing here parses a detail string.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The typed `SkotiqEvent` union collides by name with the wire/JSON event
// model the barrel above keeps canonical, so it comes from the core's dedicated
// typed-event seam under the `ns_events` prefix. The non-colliding members this
// panel needs (`EventPayload_Sequencer`, `SchedulerScoreEntry`) are reachable
// unprefixed straight off the barrel.
import 'package:skotiq_core/skotiq_core_events.dart' as ns_events;
import 'package:skotiq_ui/skotiq_ui.dart';

/// One scheduler decision row as surfaced to the panel. Every
/// field is read straight off the typed
/// `SequencerEvent.schedulerDecision` variant; no string parsing involved.
class SchedulerDecisionView {
  final DateTime time;

  /// 1-based decision counter for this scheduler instance.
  final int decisionCounter;

  /// `null` when no target cleared `min_score_to_run`.
  final String? pickedTargetId;
  final String? pickedTargetName;

  /// 0..=100. `null` when nothing was picked.
  final double? pickedScore;

  /// Flat score table (runnable first, then by descending total).
  final List<SchedulerScoreEntry> scores;

  const SchedulerDecisionView({
    required this.time,
    required this.decisionCounter,
    required this.pickedTargetId,
    required this.pickedTargetName,
    required this.pickedScore,
    required this.scores,
  });

  bool get picked => pickedTargetId != null;

  /// Single source of truth for the display string the panel renders
  /// and the trigger feed surfaces. Mirrors the Rust
  /// `ProgressDetail::Scheduler::detail_text()` format so the user
  /// sees identical wording across surfaces.
  String get displayDetail {
    final n = scores.length;
    final p = pickedTargetName;
    final s = pickedScore;
    if (p != null && s != null) {
      return 'decision $decisionCounter: picked $p '
          '(${s.toStringAsFixed(0)}/100, $n candidates)';
    }
    return 'decision $decisionCounter: no runnable target ($n candidates)';
  }

  /// Short title for compact surfaces (the trigger feed uses this).
  String get displayTitle =>
      pickedTargetName == null ? 'Scheduler: no pick' : 'Scheduler: pick';
}

/// Last-N scheduler decisions surfaced from the bridge event history.
///
/// `Provider.family` keyed by int so the panel can request a custom history
/// depth (default 5 below). The family value is the cap.
final recentSchedulerDecisionsProvider =
    Provider.family<List<SchedulerDecisionView>, int>((ref, limit) {
  final history = ref.watch(eventHistoryProvider);
  final decisions = <SchedulerDecisionView>[];
  for (final event in history) {
    final decision = _maybeSchedulerDecision(event);
    if (decision != null) {
      decisions.add(decision);
      if (decisions.length >= limit) break;
    }
  }
  return decisions;
});

SchedulerDecisionView? _maybeSchedulerDecision(
    ns_events.SkotiqEvent event) {
  // The typed SchedulerDecision variant is the canonical
  // source. Pattern-match through EventPayload → SequencerEvent →
  // SchedulerDecision; ignore everything else.
  final payload = event.payload;
  if (payload is! EventPayload_Sequencer) return null;
  final sequencer = payload.field0;
  // Match on the concrete variant class re-exported through the core seam.
  // (The freezed `whenOrNull` pattern helpers live in an extension that the
  // seam does not re-export, so we destructure the variant directly.)
  if (sequencer is! SequencerEvent_SchedulerDecision) return null;
  final ts = DateTime.fromMillisecondsSinceEpoch(event.timestamp.toInt());
  return SchedulerDecisionView(
    time: ts,
    decisionCounter: sequencer.decisionCounter,
    pickedTargetId: sequencer.pickedTargetId,
    pickedTargetName: sequencer.pickedTargetName,
    pickedScore: sequencer.pickedScore,
    scores: sequencer.scores,
  );
}

/// Opt-in Run Dashboard panel showing the latest TargetScheduler decisions.
class RunDashboardSchedulerPanel extends ConsumerWidget {
  final int limit;
  const RunDashboardSchedulerPanel({super.key, this.limit = 5});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final decisions = ref.watch(recentSchedulerDecisionsProvider(limit));

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.calendarClock, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Flexible(
                child: Text(
                  'UNATTENDED AUTOPILOT',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: colors.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          if (decisions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: SkotiqTokens.spaceMd,
              ),
              child: Text(
                'No scheduler decisions yet. The panel populates as soon as '
                'a TargetScheduler node makes its first pick.',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textMuted),
              ),
            )
          else
            for (var i = 0; i < decisions.length; i++) ...[
              _DecisionRow(colors: colors, decision: decisions[i]),
              if (i < decisions.length - 1)
                Divider(
                  height: SkotiqTokens.spaceSm * 2,
                  color: colors.border,
                ),
            ],
        ],
      ),
    );
  }
}

class _DecisionRow extends StatelessWidget {
  final SkotiqColors colors;
  final SchedulerDecisionView decision;

  const _DecisionRow({required this.colors, required this.decision});

  @override
  Widget build(BuildContext context) {
    final accent = decision.picked ? colors.success : colors.warning;
    final icon =
        decision.picked ? LucideIcons.checkCircle2 : LucideIcons.alertTriangle;
    // Show the top three rows of the typed score table so the
    // user can see ranked candidates at a glance. The full list is in
    // `decision.scores`; this is a summary surface.
    final topScores = decision.scores.take(3).toList(growable: false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 13, color: accent),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                decision.displayDetail,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _formatRelative(decision.time),
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    color: colors.textMuted),
              ),
              if (topScores.isNotEmpty) ...[
                const SizedBox(height: SkotiqTokens.spaceXs),
                for (final s in topScores)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Container(
                          width: 4,
                          height: 4,
                          margin: const EdgeInsets.only(
                              right: SkotiqTokens.spaceSm),
                          decoration: BoxDecoration(
                            color:
                                s.runnable ? colors.success : colors.textMuted,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            s.runnable
                                ? '${s.targetName} — ${s.totalScore.toStringAsFixed(0)}'
                                : '${s.targetName} — ${s.reason ?? "skipped"}',
                            style: SkotiqTypography.withTabular(
                              SkotiqTypography.captionSm.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// "12s ago" / "3m ago" / "yesterday". Same formatting style the trigger
  /// feed uses; keeping a local copy avoids reaching across panel files.
  String _formatRelative(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

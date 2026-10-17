// The authoritative "what the autopilot will run tonight" banner. This is a
// READ-ONLY preview of the live SchedulerEngine's decision: it renders the
// exact target the dynamic scheduler would slew to right now (same scorer,
// same hard gates, same hysteresis), so the human's headline pick IS the
// rig's pick. It does NOT dispatch, park, or mutate engine state.
//
// It sits on the SCHEDULE tab, above the queue it is a preview of (06 §Plan
// moves it off Tonight). One `SkotiqBanner`, never the bordered amber hero
// card it used to be.
part of '../planner_screen.dart';

class _AutopilotPreviewBanner extends ConsumerWidget {
  const _AutopilotPreviewBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final previewAsync = ref.watch(schedulerPreviewDecisionProvider);

    return previewAsync.when(
      // While the first preview computes, render nothing rather than a
      // flash of skeleton — the queue below already fills the view.
      loading: () => const SizedBox.shrink(),
      // A preview failure must be loud, not silently hidden: surface it as the
      // same banner with a retry rather than pretending the autopilot has no
      // opinion (a silent fallback would hide a real scoring/loader bug).
      error: (error, _) => _padded(
        SkotiqBanner(
          title: 'Autopilot preview unavailable',
          message: 'Recompute the live scheduler pick to see it again.',
          tone: BannerTone.error,
          action: SkotiqButton(
            label: 'Retry',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => ref.invalidate(schedulerPreviewDecisionProvider),
          ),
        ),
      ),
      data: (decision) => _padded(_banner(context, decision)),
    );
  }

  Widget _padded(Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(
          SkotiqTokens.space2xl,
          SkotiqTokens.spaceMd,
          SkotiqTokens.space2xl,
          0,
        ),
        child: child,
      );

  Widget _banner(BuildContext context, SchedulerDecision decision) {
    final hasPick = decision.chosenTargetId != null;
    // Distinguish an EMPTY scheduler queue (fresh install / nothing added yet)
    // from "targets are queued but none pass right now". One banner for both
    // put the alarming "Nothing eligible right now" beside a full queue, which
    // reads as a bug. `scoredCandidates` is empty only when the scheduler had
    // zero candidates to evaluate.
    final queueEmpty = !hasPick && decision.scoredCandidates.isEmpty;

    if (hasPick) {
      return SkotiqBanner(
        title: decision.chosenTargetName ?? 'Target ${decision.chosenTargetId}',
        message: 'The autopilot would slew here next, at score '
            '${decision.score.toStringAsFixed(2)}.',
        tone: BannerTone.info,
        icon: LucideIcons.radar,
      );
    }

    // ONE banner per problem (05 §11). An empty queue is already stated by the
    // queue's own EmptyState directly below, which diagnoses WHY it is empty
    // (empty catalog / empty active project / no integration goals) and carries
    // the action. Saying it twice, once here in a warning banner and once
    // there, is the duplication the sheet forbids — so this preview stays quiet
    // and speaks only when it has something the queue does not.
    if (queueEmpty) return const SizedBox.shrink();

    return const SkotiqBanner(
      title: 'Nothing eligible right now',
      message: 'The queue has targets, but none pass right now — still below '
          'the horizon, or their filters are not in the active wheel.',
      tone: BannerTone.warning,
      icon: LucideIcons.radar,
    );
  }
}

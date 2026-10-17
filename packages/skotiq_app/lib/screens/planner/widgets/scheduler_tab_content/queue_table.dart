part of '../scheduler_tab_content.dart';

class _QueueTable extends ConsumerWidget {
  final SchedulerDecision? decision;
  final int? currentTargetId;
  final void Function(int targetId) onRowTap;

  const _QueueTable({
    required this.decision,
    required this.currentTargetId,
    required this.onRowTap,
  });

  Future<void> _confirmDeleteRow(
    BuildContext context,
    WidgetRef ref,
    int targetId,
    String targetName,
  ) async {
    final authority = ref.read(backendProvider);
    final goalsSvc = ref.read(integrationGoalServiceProvider);
    final constraintsSvc = ref.read(targetConstraintServiceProvider);
    final queueSvc = ref.read(schedulerQueueServiceProvider);
    final colors = SkotiqColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text(
            'Remove from scheduler?',
            style: SkotiqTypography.body.copyWith(color: colors.textPrimary),
          ),
          content: Text(
            'Remove $targetName from the scheduler? The autopilot will not '
            'pick it again; its integration goals and constraints are '
            'deleted, and the target itself stays in your catalog.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dCtx).pop(false),
            ),
            SkotiqButton(
              label: 'Remove',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dCtx).pop(true),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    if (!identical(ref.read(backendProvider), authority)) {
      _showAuthorityChanged(context);
      return;
    }
    // Take it OUT OF THE QUEUE, not merely off its goals: a goal-less target is
    // still an eligible free-form candidate, so deleting only the goal rows
    // below lets the autopilot re-pick the target the operator just removed.
    await queueSvc.remove(targetId);
    await goalsSvc.deleteForTarget(targetId);
    await constraintsSvc.deleteForTarget(targetId);
    if (!context.mounted || !identical(ref.read(backendProvider), authority)) {
      return;
    }
    ref.invalidate(allIntegrationGoalsProvider);
    ref.invalidate(integrationGoalProgressProvider(targetId));
    // Surface the change immediately even though the auto-reeval listeners
    // will also fire — `evaluateNow` waits, the listeners don't.
    await _reevaluate(
      ref,
      authority: authority,
      reason: 'row removed from scheduler',
    );
  }

  Future<void> _confirmClearAll(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final authority = ref.read(backendProvider);
    final goalsSvc = ref.read(integrationGoalServiceProvider);
    final constraintsSvc = ref.read(targetConstraintServiceProvider);
    final queueSvc = ref.read(schedulerQueueServiceProvider);
    final colors = SkotiqColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text(
            'Clear scheduler queue?',
            style: SkotiqTypography.body.copyWith(color: colors.textPrimary),
          ),
          content: Text(
            'Clear all targets from the scheduler? The autopilot will have '
            'nothing left to pick; integration goals and constraints are '
            'deleted, and the targets themselves stay in your catalog.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dCtx).pop(false),
            ),
            SkotiqButton(
              label: 'Clear',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(dCtx).pop(true),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    if (!identical(ref.read(backendProvider), authority)) {
      _showAuthorityChanged(context);
      return;
    }
    await queueSvc.removeAll();
    await goalsSvc.deleteAll();
    await constraintsSvc.deleteAll();
    if (!context.mounted || !identical(ref.read(backendProvider), authority)) {
      return;
    }
    ref.invalidate(allIntegrationGoalsProvider);
    await _reevaluate(
      ref,
      authority: authority,
      reason: 'scheduler queue cleared',
    );
  }

  void _showAuthorityChanged(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'The imaging host changed. Scheduler cleanup was cancelled.',
        ),
      ),
    );
  }

  Future<void> _reevaluate(
    WidgetRef ref, {
    required String reason,
    SkotiqBackend? authority,
  }) async {
    final backend = authority ?? ref.read(backendProvider);
    if (backend is NetworkBackend) {
      await backend.controlScheduler('evaluate');
      ref.invalidate(schedulerRemoteSnapshotProvider);
      ref.invalidate(schedulerPreviewDecisionProvider);
      return;
    }
    await ref.read(schedulerEngineProvider).evaluateNow(reason: reason);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final goalsAsync = ref.watch(allIntegrationGoalsProvider);
    final hasRows = decision != null && decision!.scoredCandidates.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
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
              Icon(LucideIcons.listOrdered,
                  size: SkotiqTokens.iconMd, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Scheduler queue',
                style: SkotiqTypography.sectionTitle
                    .copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              if (decision != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
                    child: Text(
                      'Last evaluation ${_formatTime(decision!.evaluatedAt)}',
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                  ),
                ),
              if (hasRows)
                SkotiqButton(
                  key: const ValueKey('scheduler-clear-all'),
                  label: 'Clear all',
                  icon: LucideIcons.trash2,
                  size: ButtonSize.small,
                  variant: ButtonVariant.ghost,
                  onPressed: () => _confirmClearAll(context, ref),
                ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _ColumnHeaders(colors: colors),
          const Divider(height: 1),
          const SizedBox(height: SkotiqTokens.spaceSm),
          if (decision == null)
            const _NoTargetsEmptyState(awaitingFirstEval: true)
          else if (decision!.scoredCandidates.isEmpty)
            const _NoTargetsEmptyState(awaitingFirstEval: false)
          else
            goalsAsync.when(
              loading: () => Padding(
                padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
                child: CircularProgressIndicator(color: colors.primary),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
                child: Text(
                  'Failed to load integration goals: $e',
                  style: SkotiqTypography.caption.copyWith(color: colors.error),
                ),
              ),
              data: (goals) {
                final goalsByTarget = <int, List<IntegrationGoal>>{};
                for (final g in goals) {
                  goalsByTarget.putIfAbsent(g.targetId, () => []).add(g);
                }
                return Column(
                  children: [
                    for (var i = 0; i < decision!.scoredCandidates.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _QueueRow(
                          score: decision!.scoredCandidates[i],
                          isWinner: i == 0 &&
                              !decision!
                                  .scoredCandidates[i].hardConstraintFailed,
                          isCurrent: decision!.scoredCandidates[i].targetId ==
                              currentTargetId,
                          goalsForTarget: goalsByTarget[
                                  decision!.scoredCandidates[i].targetId] ??
                              const <IntegrationGoal>[],
                          onTap: () =>
                              onRowTap(decision!.scoredCandidates[i].targetId),
                          onDelete: () => _confirmDeleteRow(
                            context,
                            ref,
                            decision!.scoredCandidates[i].targetId,
                            decision!.scoredCandidates[i].targetName,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

class _ColumnHeaders extends StatelessWidget {
  final SkotiqColors colors;
  const _ColumnHeaders({required this.colors});

  @override
  Widget build(BuildContext context) {
    TextStyle h() => SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceLg),
      child: Row(
        children: [
          SizedBox(width: 38, child: Text('', style: h())),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(flex: 4, child: Text('TARGET', style: h())),
          const SizedBox(width: SkotiqTokens.spaceMd),
          SizedBox(
              width: 78,
              child: Text('SCORE', textAlign: TextAlign.right, style: h())),
          const SizedBox(width: SkotiqTokens.spaceMd),
          SizedBox(width: 130, child: Text('STATUS', style: h())),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(flex: 4, child: Text('GOALS', style: h())),
        ],
      ),
    );
  }
}

class _QueueRow extends ConsumerWidget {
  final TargetScore score;
  final bool isWinner;
  final bool isCurrent;
  final List<IntegrationGoal> goalsForTarget;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _QueueRow({
    required this.score,
    required this.isWinner,
    required this.isCurrent,
    required this.goalsForTarget,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progressAsync =
        ref.watch(integrationGoalProgressProvider(score.targetId));
    return progressAsync.when(
      loading: () => TargetScoreRow(
        score: score,
        progress: const [],
        isCurrent: isCurrent,
        isWinner: isWinner,
        onTap: onTap,
        onDelete: onDelete,
      ),
      error: (_, __) => TargetScoreRow(
        score: score,
        progress: const [],
        isCurrent: isCurrent,
        isWinner: isWinner,
        onTap: onTap,
        onDelete: onDelete,
      ),
      data: (progress) => TargetScoreRow(
        score: score,
        progress: progress,
        isCurrent: isCurrent,
        isWinner: isWinner,
        onTap: onTap,
        onDelete: onDelete,
      ),
    );
  }
}

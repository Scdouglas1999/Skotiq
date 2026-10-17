part of '../scheduler_tab_content.dart';

/// Why the queue came back empty.
///
/// The scheduler's candidate query is project-scoped (an INNER JOIN against
/// `project_targets` whenever a project is active), so an empty queue has
/// several genuinely different causes and only one of them is "you have not
/// added targets yet". Telling every operator to go add catalog targets and
/// integration goals sends the ones who already did that to redo work they
/// have done, and hides the real cause — an active project with no members.
enum _EmptyQueueCause {
  /// The engine has produced no decision yet (Start / Re-evaluate not pressed).
  awaitingFirstEval,

  /// A project is active and has no member targets, so the project-scoped
  /// candidate query can never return a row.
  activeProjectEmpty,

  /// The target catalog itself is empty.
  catalogEmpty,

  /// Targets exist in scope but none of them carries an integration goal.
  noIntegrationGoals,

  /// Everything above looks populated (or is still loading). Say only what is
  /// actually known rather than naming a cause we have not established.
  unknown,
}

class _NoTargetsEmptyState extends ConsumerWidget {
  /// True when the scheduler has not yet produced any decision (Start
  /// has not been pressed); false when a decision exists but the scored
  /// list is empty (no candidates in the database).
  final bool awaitingFirstEval;

  const _NoTargetsEmptyState({required this.awaitingFirstEval});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The same three inputs the candidate loader reads, so the diagnosis names
    // the condition that actually produced the empty queue instead of guessing.
    final activeProjectId = ref.watch(activeProjectIdProvider);
    final activeProject = ref.watch(activeProjectProgressProvider).valueOrNull;
    final catalogCount = ref.watch(allDbTargetsProvider).valueOrNull?.length;
    final goals = ref.watch(integrationGoalsStreamProvider).valueOrNull;

    final cause = _diagnose(
      activeProjectId: activeProjectId,
      activeProject: activeProject,
      catalogCount: catalogCount,
      goals: goals,
    );
    final projectName = activeProject?.project.name ?? 'the active project';

    // One sentence per cause (05 §12) — the long explanation the old card
    // carried behind a "Learn more" expander is exactly the screen-explaining
    // prose 07 "What NOT to do" forbids; the help popover owns that now.
    final String headline;
    final String body;
    switch (cause) {
      case _EmptyQueueCause.awaitingFirstEval:
        headline = 'No decision yet';
        body = 'Press Start in the autopilot panel, or re-evaluate, to score '
            'your targets.';
      case _EmptyQueueCause.activeProjectEmpty:
        headline = 'Project "$projectName" has no targets';
        body = 'The scheduler only considers targets in the active project, '
            'and this one is empty.';
      case _EmptyQueueCause.catalogEmpty:
        headline = 'No targets in your catalog';
        body = 'Add a target, then set how many frames you want in each '
            'filter.';
      case _EmptyQueueCause.noIntegrationGoals:
        headline = 'No integration goals set';
        body = 'Your targets do not say how much data they still need. Open '
            'one and set its frame counts.';
      case _EmptyQueueCause.unknown:
        headline = 'No targets to schedule';
        body = 'The last evaluation produced no candidates. Check that the '
            'targets in scope still need data.';
    }

    // ONE button (05 §12): for an empty active project the one-press fix is
    // dropping the project scope; every other cause is resolved in Projects.
    final Widget action = cause == _EmptyQueueCause.activeProjectEmpty
        ? SkotiqButton(
            key: const ValueKey('scheduler-clear-active-project'),
            label: 'Schedule whole catalog',
            icon: LucideIcons.globe,
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: () => unawaited(
              ref.read(activeProjectIdProvider.notifier).setActiveProject(null),
            ),
          )
        : SkotiqButton(
            label: 'Open target catalog',
            icon: LucideIcons.listOrdered,
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            // The add-target / integration-goals surface is the Projects tab,
            // not the default (Recommendation) landing page that a bare
            // `/planner` resolves to.
            onPressed: () => context.go('/planner?tab=projects'),
          );

    return EmptyState.compact(
      icon: LucideIcons.target,
      title: headline,
      body: body,
      action: action,
    );
  }

  _EmptyQueueCause _diagnose({
    required int? activeProjectId,
    required CampaignProgress? activeProject,
    required int? catalogCount,
    required List<IntegrationGoal>? goals,
  }) {
    if (awaitingFirstEval) return _EmptyQueueCause.awaitingFirstEval;

    // Project scope is checked first: it is the only cause that can hide a
    // fully-populated catalog.
    if (activeProjectId != null &&
        activeProject != null &&
        activeProject.project.id == activeProjectId &&
        activeProject.totalTargets == 0) {
      return _EmptyQueueCause.activeProjectEmpty;
    }
    if (catalogCount != null && catalogCount == 0) {
      return _EmptyQueueCause.catalogEmpty;
    }
    if (goals != null) {
      // Goals only count when they belong to a target the scheduler can see,
      // so a goal on an out-of-project target does not mask the real cause.
      final inScope = activeProjectId == null || activeProject == null
          ? goals
          : goals.where((g) {
              return activeProject.targets.any((t) => t.targetId == g.targetId);
            });
      if (inScope.isEmpty) return _EmptyQueueCause.noIntegrationGoals;
    }
    return _EmptyQueueCause.unknown;
  }
}

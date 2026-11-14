import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/snackbar_helper.dart';
import '../../planner/editors/integration_goals_editor.dart';
import 'analytics_empty_state.dart';
import 'campaign_rollup_dialog.dart';
import '../../../router/app_routes.dart';
import '../../../router/planner_route.dart';

part 'project_tracking_panel_parts/_headers.dart';
part 'project_tracking_panel_parts/_project_card.dart';

enum ProjectSortMode {
  completion,
  totalTime,
  lastImaged,
  name,
}

/// Number of "untracked" library targets eligible for the opt-in cleanup.
/// Re-evaluates whenever the targets or sessions data changes so the button
/// count stays live. On a remote host the same session-aware predicate runs
/// host-side over `/api/analytics/untracked-targets/count`.
///
/// "Untracked" is defined in [TargetsDao.deleteUntrackedTargets]: no integration
/// goal, not a favorite, no captured subs, no integration time, and not
/// referenced by any imaging session.
final untrackedTargetsCountProvider = FutureProvider<int?>((ref) async {
  ref.watch(allDbTargetsProvider);
  ref.watch(allSessionsProvider);
  return ref.watch(targetLibraryProvider).countUntrackedTargets();
});

/// Full-featured project tracking panel for the analytics screen.
///
/// Displays multi-night target progress with:
/// - Summary stats header (total targets, total integration, sessions this month)
/// - Sort options (completion %, total time, last imaged, name)
/// - Per-target cards with filter breakdown, progress bars, and goal editing
class ProjectTrackingPanel extends ConsumerStatefulWidget {
  const ProjectTrackingPanel({super.key});

  @override
  ConsumerState<ProjectTrackingPanel> createState() =>
      _ProjectTrackingPanelState();
}

class _ProjectTrackingPanelState extends ConsumerState<ProjectTrackingPanel> {
  ProjectSortMode _sortMode = ProjectSortMode.completion;

  List<ProjectProgress> _sortProjects(List<ProjectProgress> projects) {
    final sorted = List<ProjectProgress>.from(projects);
    switch (_sortMode) {
      case ProjectSortMode.completion:
        sorted.sort((a, b) {
          // Tracked projects first, then by completion ascending (least complete first)
          final aPriority = a.isTracked ? 0 : 1;
          final bPriority = b.isTracked ? 0 : 1;
          if (aPriority != bPriority) return aPriority.compareTo(bPriority);
          if (a.isTracked && b.isTracked) {
            return a.completionFraction.compareTo(b.completionFraction);
          }
          return b.integratedSecs.compareTo(a.integratedSecs);
        });
      case ProjectSortMode.totalTime:
        sorted.sort((a, b) => b.integratedSecs.compareTo(a.integratedSecs));
      case ProjectSortMode.lastImaged:
        sorted.sort((a, b) {
          final aTime = a.lastImagedAt?.millisecondsSinceEpoch ?? 0;
          final bTime = b.lastImagedAt?.millisecondsSinceEpoch ?? 0;
          return bTime.compareTo(aTime);
        });
      case ProjectSortMode.name:
        sorted.sort((a, b) =>
            a.target.name.toLowerCase().compareTo(b.target.name.toLowerCase()));
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final progressAsync = ref.watch(projectProgressListProvider);

    return progressAsync.when(
      data: (projects) {
        if (projects.isEmpty) {
          // Two screens are called "Projects", so they must not tell the
          // operator opposite things about how a project comes into being.
          // Plan Tonight → Projects owns the "New Project" button; there is
          // exactly one creation path, so this names it and goes there.
          return AnalyticsEmptyState(
            icon: LucideIcons.target,
            title: 'No projects yet',
            body: 'Create a project in Plan Tonight → Projects, then the '
                'frames you capture for its targets accrue here.',
            actionLabel: 'New project',
            onAction: () =>
                context.go(AppRoutes.planner(tab: PlannerTab.projects)),
          );
        }

        final sorted = _sortProjects(projects);

        return Column(
          children: [
            const _CleanupHeaderRow(),
            _SummaryStatsHeader(projects: projects, colors: colors),
            const SizedBox(height: 12),
            _SortBar(
              currentSort: _sortMode,
              onSortChanged: (mode) => setState(() => _sortMode = mode),
              colors: colors,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: sorted.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  return _EnhancedProjectCard(progress: sorted[index]);
                },
              ),
            ),
          ],
        );
      },
      // Shimmer card placeholders so the panel keeps its real geometry.
      loading: () => _ProjectsLoadingSkeleton(colors: colors),
      error: (error, stackTrace) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Error loading projects: ${userFacingError(error)}',
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.body.copyWith(color: colors.error),
          ),
        ),
      ),
    );
  }
}

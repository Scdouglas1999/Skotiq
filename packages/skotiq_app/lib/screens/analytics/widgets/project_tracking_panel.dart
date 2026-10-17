import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/snackbar_helper.dart';
import 'analytics_empty_state.dart';
import 'campaign_rollup_dialog.dart';

part 'project_tracking_panel_parts/_headers.dart';
part 'project_tracking_panel_parts/_project_card.dart';

// Sort mode

enum ProjectSortMode {
  completion,
  totalTime,
  lastImaged,
  name,
}

// Per-filter breakdown provider

/// Computes per-target, per-filter integration time from captured images.
///
/// Returns a map of target ID to (filter name -> total seconds).
final perFilterIntegrationProvider =
    Provider<AsyncValue<Map<int, Map<String, double>>>>((ref) {
  final imagesAsync = ref.watch(allDbImagesProvider);

  if (imagesAsync.hasError) {
    return AsyncValue.error(
      imagesAsync.error!,
      imagesAsync.stackTrace ?? StackTrace.current,
    );
  }
  if (imagesAsync.isLoading) {
    return const AsyncValue.loading();
  }

  final images = imagesAsync.value ?? const <DbCapturedImage>[];
  final result = <int, Map<String, double>>{};

  for (final image in images) {
    final targetId = image.targetId;
    if (targetId == null) continue;
    if (image.frameType != 'light') continue;
    if (!image.isAccepted) continue;

    final filterName = image.filter ?? 'Unfiltered';
    final targetMap = result.putIfAbsent(targetId, () => <String, double>{});
    targetMap[filterName] =
        (targetMap[filterName] ?? 0.0) + image.exposureDuration;
  }

  return AsyncValue.data(result);
});

// Untracked-targets cleanup count

/// Number of "untracked" library targets eligible for the opt-in cleanup.
/// Re-evaluates whenever the targets or sessions data changes so the button
/// count stays live. On a remote host the same session-aware predicate runs
/// host-side over `/api/analytics/untracked-targets/count`.
///
/// "Untracked" is defined in [TargetsDao.deleteUntrackedTargets]: no integration
/// goal, not a favorite, no captured subs, no integration time, and not
/// referenced by any imaging session.
final untrackedTargetsCountProvider = FutureProvider<int?>((ref) async {
  final backend = ref.watch(backendProvider);
  // Recompute when the underlying data changes.
  ref.watch(allDbTargetsProvider);
  ref.watch(allSessionsProvider);
  if (backend is NetworkBackend) {
    return backend.countUntrackedTargets();
  }
  return ref.read(targetsDaoProvider).countUntrackedTargets();
});

// Project tracking panel

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
          final aTime = a.lastSessionAt?.millisecondsSinceEpoch ?? 0;
          final bTime = b.lastSessionAt?.millisecondsSinceEpoch ?? 0;
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
    final filterDataAsync = ref.watch(perFilterIntegrationProvider);

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
            onAction: () => context.go('/planner?tab=projects'),
          );
        }

        final sorted = _sortProjects(projects);
        final filterData =
            filterDataAsync.valueOrNull ?? <int, Map<String, double>>{};

        return Column(
          children: [
            // Header actions: opt-in cleanup of phantom/untracked targets.
            const _CleanupHeaderRow(),
            // Summary stats header
            _SummaryStatsHeader(projects: projects, colors: colors),
            const SizedBox(height: 12),

            // Sort bar
            _SortBar(
              currentSort: _sortMode,
              onSortChanged: (mode) => setState(() => _sortMode = mode),
              colors: colors,
            ),
            const SizedBox(height: 12),

            // Project list
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: sorted.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final progress = sorted[index];
                  final targetFilterData =
                      filterData[progress.target.id] ?? <String, double>{};
                  return _EnhancedProjectCard(
                    progress: progress,
                    filterBreakdown: targetFilterData,
                  );
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
            'Error loading projects: $error',
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

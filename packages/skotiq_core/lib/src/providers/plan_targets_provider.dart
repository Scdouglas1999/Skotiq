import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/planning/project.dart';
import '../services/project_tracking_service.dart';
import 'planning_provider.dart' show projectListProvider;
import 'planning/project_service_provider.dart';
import 'project_tracking_provider.dart';
import 'scheduler/scheduler_queue_service_provider.dart';

/// One of the owner's targets as Plan > Targets lists it: what has been
/// integrated, the goal if one is set, the groups it belongs to and whether
/// the autopilot may pick it.
class PlanTarget {
  const PlanTarget({
    required this.progress,
    required this.groups,
    required this.inAutopilot,
  });

  /// Integration, goal, nights and per-filter totals, from the accepted light
  /// frames: the figure the Darkroom and Analytics show.
  final ProjectProgress progress;

  /// The groups this target is a member of, in the order groups are listed.
  final List<Project> groups;

  /// False when the owner took the target off the autopilot's list.
  final bool inAutopilot;

  int get id => progress.target.id;
  String get name => progress.target.name;
  double get integratedSecs => progress.integratedSecs;

  bool inGroup(int groupId) => groups.any((g) => g.id == groupId);
}

/// Which targets each group holds, by group id.
final groupMembersProvider = FutureProvider<Map<int, Set<int>>>((ref) async {
  final groups = await ref.watch(projectListProvider.future);
  final service = ref.watch(projectServiceProvider);
  return {
    for (final group in groups)
      if (group.id != null)
        group.id!: (await service.targetIdsForProject(group.id!)).toSet(),
  };
});

/// The targets the owner took off the autopilot's list.
final autopilotRemovedTargetIdsProvider = FutureProvider<Set<int>>(
  (ref) => ref.watch(schedulerQueueServiceProvider).removedTargetIds(),
);

/// Every saved target with its progress, groups and autopilot state.
final planTargetsProvider = Provider<AsyncValue<List<PlanTarget>>>((ref) {
  final progress = ref.watch(projectProgressListProvider);
  final groups = ref.watch(projectListProvider);
  final members = ref.watch(groupMembersProvider);
  final removed = ref.watch(autopilotRemovedTargetIdsProvider);

  for (final AsyncValue<Object?> source in [progress, groups]) {
    if (source.hasError) {
      return AsyncValue.error(
        source.error!,
        source.stackTrace ?? StackTrace.current,
      );
    }
  }
  final rows = progress.valueOrNull;
  final groupList = groups.valueOrNull;
  if (rows == null || groupList == null) return const AsyncValue.loading();

  // Membership and the removed list refine the rows; a failure to read either
  // leaves the targets listed without them.
  final memberMap = members.valueOrNull ?? const <int, Set<int>>{};
  final removedIds = removed.valueOrNull ?? const <int>{};
  return AsyncValue.data([
    for (final row in rows)
      PlanTarget(
        progress: row,
        groups: [
          for (final group in groupList)
            if (memberMap[group.id]?.contains(row.target.id) ?? false) group,
        ],
        inAutopilot: !removedIds.contains(row.target.id),
      ),
  ]);
});

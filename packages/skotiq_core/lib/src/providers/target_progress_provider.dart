import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../models/scheduler/target_progress.dart';
import '../services/scheduler/integration_goal_service.dart';
import '../services/scheduler/target_progress_service.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

/// Service-level access. Stateless, so a plain `Provider` suffices.
final targetProgressServiceProvider = Provider<TargetProgressService>((ref) {
  return TargetProgressService(
    database: ref.watch(databaseProvider),
    goalService: ref.watch(integrationGoalServiceProvider),
  );
});

/// Per-target progress, keyed by target id.
///
/// `autoDispose` so progress for a target stops recomputing when no widget
/// is observing it. Re-runs whenever `allDbImagesProvider` (captured
/// frames) or `allDbTargetsProvider` (target row metadata, e.g. rename)
/// emits — both are streams of the underlying tables, so this provider
/// stays consistent with what's actually on disk without us having to
/// invalidate by hand.
final targetProgressProvider = FutureProvider.autoDispose
    .family<TargetProgress?, int>((ref, targetId) async {
      // Drive re-evaluation off the underlying drift streams. We discard the
      // values — they only exist to subscribe the provider to schema-bearing
      // changes; the heavy aggregation work happens in the service.
      final images = await ref.watch(allDbImagesProvider.future);
      final targets = await ref.watch(allDbTargetsProvider.future);
      final useHostImages = ref.watch(backendProvider) is NetworkBackend;

      for (final target in targets) {
        if (target.id == targetId) {
          final service = ref.watch(targetProgressServiceProvider);
          return service.forTarget(
            targetId: targetId,
            targetName: target.name,
            capturedImages: useHostImages ? images : null,
          );
        }
      }
      return null;
    });

/// Progress for every target with at least one row in the targets table.
///
/// Returns a `Map<targetId, TargetProgress>` so the consuming UI can do
/// O(1) lookups without re-iterating the full list. Re-evaluated whenever
/// targets or captured-images change.
final allTargetProgressProvider =
    FutureProvider.autoDispose<Map<int, TargetProgress>>((ref) async {
      final images = await ref.watch(allDbImagesProvider.future);
      final targets = await ref.watch(allDbTargetsProvider.future);
      final useHostImages = ref.watch(backendProvider) is NetworkBackend;

      final service = ref.watch(targetProgressServiceProvider);
      return service.forTargets(
        targets.map((t) => (id: t.id, name: t.name)).toList(),
        capturedImages: useHostImages ? images : null,
      );
    });

/// Invalidates target-progress readers after host catalog or capture changes.
void invalidateTargetProgressReaders(Ref ref) {
  ref.invalidate(allTargetProgressProvider);
  ref.invalidate(targetProgressProvider);
}

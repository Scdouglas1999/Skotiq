part of '../scheduler_provider.dart';

/// Keeping status, decision, configuration, and admission in one response
/// prevents a remote client from making a local safety decision.
class SchedulerRemoteSnapshot {
  final SchedulerStatus status;
  final SchedulerDecision decision;
  final SchedulerConfig config;
  final SchedulerStartReadiness readiness;

  const SchedulerRemoteSnapshot({
    required this.status,
    required this.decision,
    required this.config,
    required this.readiness,
  });

  factory SchedulerRemoteSnapshot.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final decision = json['decision'];
    final config = json['config'];
    if (status is! Map || decision is! Map || config is! Map) {
      throw const FormatException(
        'Malformed scheduler state from imaging host',
      );
    }
    return SchedulerRemoteSnapshot(
      status: SchedulerStatus.fromJson(status.cast<String, dynamic>()),
      decision: SchedulerDecision.fromJson(decision.cast<String, dynamic>()),
      config: SchedulerConfig.fromStorageJson(config.cast<String, dynamic>()),
      readiness: SchedulerStartReadiness.fromStorageJson(json['readiness']),
    );
  }
}

final schedulerRemoteSnapshotProvider =
    FutureProvider.autoDispose<SchedulerRemoteSnapshot>((ref) async {
      final backend = ref.watch(backendProvider);
      if (backend is! NetworkBackend) {
        throw StateError('Remote scheduler state requires a network backend');
      }
      return SchedulerRemoteSnapshot.fromJson(
        await backend.getSchedulerState(),
      );
    });

/// Quick-access provider for the list of all integration goals (refreshes
/// when the operator edits them).
final allIntegrationGoalsProvider = FutureProvider<List<IntegrationGoal>>((
  ref,
) async {
  return ref.watch(integrationGoalServiceProvider).listAll();
});

/// Per-target progress provider used by the Scheduler screen rows.
final integrationGoalProgressProvider =
    FutureProvider.family<List<IntegrationGoalProgress>, int>((
      ref,
      targetId,
    ) async {
      return ref
          .watch(integrationGoalServiceProvider)
          .progressForTarget(targetId);
    });

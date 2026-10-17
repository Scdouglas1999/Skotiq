import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../models/backend/event_types.dart' as core;
import '../models/depthlock/depthlock_models.dart';
import 'backend_provider.dart';

/// The DepthLock slice of the active backend.
///
/// Declared here rather than beside the other role providers so a widget or
/// unit test can override this one slice with a fake instead of standing up a
/// whole [SkotiqBackend]; every reader below goes through it.
final depthLockBackendProvider = Provider<DepthLockBackend>((ref) {
  return ref.watch(backendProvider);
});

/// The backend event stream the goal list refreshes on.
///
/// Separate from [depthLockBackendProvider] because the events are a
/// cross-cutting concern ([DiagnosticsBackend]) rather than part of the
/// DepthLock role, and because a test that only exercises the actions should
/// not have to invent an event stream.
final depthLockEventStreamProvider = Provider<Stream<core.SkotiqEvent>>((
  ref,
) {
  return ref.watch(backendProvider).eventStream;
});

/// Whether [event] is one of the DepthLock family.
///
/// The native side emits these as typed `DepthLockEvent` variants under
/// `EventPayload::DepthLock`; the FFI and WebSocket mappers collapse the union
/// to this envelope's `eventType` string. The prefix is matched rather than a
/// fixed set of names so a variant added later still refreshes the list, and
/// case-insensitively because the mapper's generic arm derives the name from
/// the union's own `depthLock` spelling while a named arm would write
/// `DepthLockGoalUpdated`.
bool isDepthLockEvent(core.SkotiqEvent event) =>
    event.eventType.toLowerCase().startsWith('depthlock');

/// Every persistent DepthLock goal the host holds, newest revision first.
///
/// The list is the single source the imaging panel, the goal editor and the
/// Smart Exposure binding selector all read, so a revision bump made anywhere
/// is visible everywhere on the next refresh. Mutations go through the
/// notifier's actions below, which refresh the list once the host has
/// committed.
final depthLockGoalsProvider =
    AsyncNotifierProvider<DepthLockGoalsNotifier, List<DepthLockGoal>>(
      DepthLockGoalsNotifier.new,
    );

/// Analysis-queue health and whether the goal store is available at all.
///
/// A DepthLock goal cannot be created against a host whose settings storage
/// never initialised, and the panel has to say so rather than failing at the
/// create call.
final depthLockStatusProvider = FutureProvider<DepthLockStatus>((ref) async {
  return ref.watch(depthLockBackendProvider).depthLockStatus();
});

/// Goals defined for [filterName], for the Smart Exposure per-filter binding
/// selector. Comparison is case-insensitive because a filter's name reaches a
/// goal through a FITS header and a sequence through the profile's wheel.
final depthLockGoalsForFilterProvider =
    Provider.family<List<DepthLockGoal>, String>((ref, filterName) {
      final goals = ref.watch(depthLockGoalsProvider).valueOrNull;
      if (goals == null) return const <DepthLockGoal>[];
      final wanted = filterName.trim().toLowerCase();
      return goals
          .where(
            (goal) => goal.definition.filterName.trim().toLowerCase() == wanted,
          )
          .toList(growable: false);
    });

/// Goals anchored on [targetId], for the overlays the imaging preview draws
/// over the frame the operator is looking at.
final depthLockGoalsForTargetProvider =
    Provider.family<List<DepthLockGoal>, String>((ref, targetId) {
      final goals = ref.watch(depthLockGoalsProvider).valueOrNull;
      if (goals == null) return const <DepthLockGoal>[];
      return goals
          .where((goal) => goal.definition.targetId == targetId)
          .toList(growable: false);
    });

/// Holds the goal list and performs the mutations against the backend.
///
/// Errors are rethrown exactly as the backend raised them: a DepthLock refusal
/// is the native engine explaining a geometry or a stale revision to the
/// operator, and rewording it here would lose the only explanation there is.
class DepthLockGoalsNotifier extends AsyncNotifier<List<DepthLockGoal>> {
  StreamSubscription<core.SkotiqEvent>? _events;

  @override
  Future<List<DepthLockGoal>> build() async {
    final backend = ref.watch(depthLockBackendProvider);
    _listenForChanges();
    return backend.listDepthLockGoals();
  }

  /// Re-read the goal list, leaving the current value visible while the read
  /// is in flight so the panel does not blank out on every arriving frame.
  Future<void> refresh() async {
    final backend = ref.read(depthLockBackendProvider);
    state = await AsyncValue.guard(() => backend.listDepthLockGoals());
  }

  Future<DepthLockGoal> createGoal(
    DepthLockGoalDefinition definition, {
    String? goalId,
  }) async {
    final backend = ref.read(depthLockBackendProvider);
    final goal = await backend.createDepthLockGoal(definition, goalId: goalId);
    await refresh();
    return goal;
  }

  /// Replace a goal's definition. The host archives the previous revision and
  /// starts evidence over — the caller is responsible for having said so.
  Future<DepthLockGoal> reviseGoal({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  }) async {
    final backend = ref.read(depthLockBackendProvider);
    final goal = await backend.reviseDepthLockGoal(
      goalId: goalId,
      expectedRevision: expectedRevision,
      definition: definition,
    );
    await refresh();
    return goal;
  }

  /// Turn ingestion and automatic completion on or off. Neither is part of the
  /// definition, so this keeps the revision and its evidence.
  Future<DepthLockGoal> setPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) async {
    final backend = ref.read(depthLockBackendProvider);
    final goal = await backend.setDepthLockGoalPreferences(
      goalId: goalId,
      expectedRevision: expectedRevision,
      enabled: enabled,
      automaticCompletion: automaticCompletion,
    );
    await refresh();
    return goal;
  }

  Future<void> removeGoal({
    required String goalId,
    required int expectedRevision,
  }) async {
    final backend = ref.read(depthLockBackendProvider);
    await backend.removeDepthLockGoal(
      goalId: goalId,
      expectedRevision: expectedRevision,
    );
    await refresh();
  }

  /// Re-evaluate a goal over the evidence it already holds. Replaying the same
  /// evidence cannot advance confirmation; it only recomputes the report.
  Future<DepthLockGoal> replayGoal(String goalId) async {
    final backend = ref.read(depthLockBackendProvider);
    final goal = await backend.replayDepthLockGoal(goalId);
    await refresh();
    return goal;
  }

  /// Offer one saved light to one goal. The outcome is returned rather than
  /// surfaced as an error: `duplicate` and `preSelection` are ordinary answers
  /// for a file the operator picked by hand.
  Future<DepthLockIngestOutcome> ingestFrame({
    required String goalId,
    required String path,
  }) async {
    final backend = ref.read(depthLockBackendProvider);
    final outcome = await backend.ingestDepthLockFrame(
      goalId: goalId,
      path: path,
    );
    await refresh();
    return outcome;
  }

  /// Refresh whenever the host reports a DepthLock change.
  ///
  /// Evidence arrives one exposure at a time across a whole night, so the
  /// panel would otherwise be stale for as long as nobody reopened it. The
  /// subscription is rebuilt with the notifier because [build] re-runs on a
  /// backend swap, and a stream from the previous backend would keep feeding a
  /// list read from a host that is no longer connected.
  void _listenForChanges() {
    _events?.cancel();
    _events = ref
        .watch(depthLockEventStreamProvider)
        .where(isDepthLockEvent)
        .listen(
          (_) {
            refresh();
            // The curves are derived from the same evidence, so a change that
            // moves a goal moves its chart. They are invalidated rather than
            // refetched: only the goal the operator has open is being watched,
            // and that one re-reads itself on the next build.
            ref.invalidate(depthLockGoalCurveProvider);
          },
          onError: (Object error) {
            developer.log(
              'DepthLock event stream error: $error',
              name: 'DepthLockProvider',
              level: 900,
            );
          },
        );
    ref.onDispose(() {
      _events?.cancel();
      _events = null;
    });
  }
}

/// One goal's score history plus the noise model's projection beyond it.
///
/// Separate from the goal list because it is display-only and larger: the list
/// is read on every panel build, while a curve is fetched when one goal is
/// opened. Invalidated by [DepthLockGoalsNotifier] on any DepthLock event, so
/// an arriving exposure redraws the chart rather than leaving yesterday's
/// projection on screen.
final depthLockGoalCurveProvider =
    FutureProvider.family<List<DepthLockCurvePoint>, String>((
      ref,
      goalId,
    ) async {
      return ref.watch(depthLockBackendProvider).depthLockGoalCurve(goalId);
    });

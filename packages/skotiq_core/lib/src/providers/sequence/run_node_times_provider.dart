import 'package:flutter/foundation.dart' show immutable, mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        EventPayload_Sequencer,
        SequencerEvent_NodeCompleted,
        SequencerEvent_NodeStarted,
        SequencerEvent_Started,
        SkotiqEvent;

import '../../models/sequence/sequence_models.dart';
import '../event_provider.dart' show eventHistoryProvider, skotiqEventsProvider;
import 'sequence_progress.dart' show sequenceExecutionStateProvider;

/// When the nodes of the current (or last) run started and finished, as the
/// executor's events recorded them. Instants (UTC).
@immutable
class RunNodeTimes {
  const RunNodeTimes({
    this.started = const <String, DateTime>{},
    this.completed = const <String, DateTime>{},
    this.completedStatus = const <String, String>{},
  });

  /// The latest `NodeStarted` per node.
  final Map<String, DateTime> started;

  /// The latest `NodeCompleted` per node, and its wire status ("success",
  /// "failed", "cancelled", "skipped").
  final Map<String, DateTime> completed;
  final Map<String, String> completedStatus;

  /// When [nodeId] finished successfully, if a run reported it.
  DateTime? succeededAt(String nodeId) =>
      completedStatus[nodeId] == 'success' ? completed[nodeId] : null;

  @override
  bool operator ==(Object other) =>
      other is RunNodeTimes &&
      mapEquals(started, other.started) &&
      mapEquals(completed, other.completed) &&
      mapEquals(completedStatus, other.completedStatus);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(started.entries.map((e) => (e.key, e.value))),
    Object.hashAllUnordered(completed.entries.map((e) => (e.key, e.value))),
    Object.hashAllUnordered(
      completedStatus.entries.map((e) => (e.key, e.value)),
    ),
  );
}

/// The one record of when the run's nodes really started and finished. Tonight's
/// plan and the Sequencer's ETA column both read it, so a node that began at
/// 22:41 says 22:41 on both.
///
/// Folded from the typed event stream the executor publishes, for the whole
/// run: the event history keeps only the latest events, which a night of
/// frames pushes the first targets' starts out of. The history is folded too,
/// once when the record is first read and again when it is filled with
/// events from before this window was listening (a linked client's first
/// connect). Folding an event twice changes nothing.
///
/// A run's `Started` clears the record, so a rerun never shows the previous
/// run's times. Nothing else clears it: a finished run's times are the record
/// of the night.
///
/// `autoDispose`, and held alive from the moment a run is seen: an app that
/// never runs a sequence never keeps it.
final runNodeTimesProvider =
    StateNotifierProvider.autoDispose<RunNodeTimesNotifier, RunNodeTimes>((
      ref,
    ) {
      final notifier = RunNodeTimesNotifier();
      KeepAliveLink? runLink;
      void holdForTheSession() => runLink ??= ref.keepAlive();
      notifier._onRunObserved = holdForTheSession;

      notifier.fold(ref.read(eventHistoryProvider).reversed);
      ref.listen<List<SkotiqEvent>>(eventHistoryProvider, (previous, next) {
        if ((previous == null || previous.isEmpty) && next.isNotEmpty) {
          notifier.fold(next.reversed);
        }
      });
      ref.listen(skotiqEventsProvider, (previous, next) {
        next.whenData((event) => notifier.fold([event]));
      });
      // The execution state covers a run that was already going when this was
      // first read, whose `Started` was delivered long before.
      ref.listen<SequenceExecutionState>(sequenceExecutionStateProvider, (
        previous,
        next,
      ) {
        if (!next.canStart) holdForTheSession();
      }, fireImmediately: true);
      ref.onDispose(() => runLink?.close());
      return notifier;
    });

class RunNodeTimesNotifier extends StateNotifier<RunNodeTimes> {
  RunNodeTimesNotifier() : super(const RunNodeTimes());

  void Function()? _onRunObserved;

  /// Folds [events], oldest first, onto the record.
  void fold(Iterable<SkotiqEvent> events) {
    if (!mounted) return;
    var started = state.started;
    var completed = state.completed;
    var status = state.completedStatus;
    var changed = false;
    for (final event in events) {
      final payload = event.payload;
      if (payload is! EventPayload_Sequencer) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(
        event.timestamp.toInt(),
        isUtc: true,
      );
      switch (payload.field0) {
        case SequencerEvent_Started():
          _onRunObserved?.call();
          started = const <String, DateTime>{};
          completed = const <String, DateTime>{};
          status = const <String, String>{};
          changed = true;
        case SequencerEvent_NodeStarted(:final nodeId):
          _onRunObserved?.call();
          started = {...started, nodeId: at};
          changed = true;
        case SequencerEvent_NodeCompleted(:final nodeId, status: final s):
          completed = {...completed, nodeId: at};
          status = {...status, nodeId: s};
          changed = true;
        default:
          break;
      }
    }
    if (!changed) return;
    final next = RunNodeTimes(
      started: started,
      completed: completed,
      completedStatus: status,
    );
    if (next != state) state = next;
  }
}

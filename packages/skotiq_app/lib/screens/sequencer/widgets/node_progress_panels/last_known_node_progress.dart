part of '../node_progress_panels.dart';

/// The last live progress a node reported this session, kept after the run
/// moves on.
///
/// `_NodeItem` carries the same five slots as private fields
/// (`_lastKnownStatus` … `_lastKnownRunFilter`) so the tree's inline panel can
/// outlive the per-node progress maps being cleared on the success path —
/// without them the card fell back to "0 / 4 frames" directly above the four
/// thumbnails it had just captured. The inspector's Activity tab needs the
/// identical memory, so the rule lives here once instead of being cloned into
/// a second widget: a null field in [SequenceProgress] never erases the last
/// non-null value this node was seen with.
class NodeActivitySnapshot {
  final NodeStatus? status;
  final double? percent;
  final String? detail;
  final InstructionProgressDetail? structuredDetail;

  /// The filter the run was imaging through when this node last reported —
  /// remembered per node because the run-level `currentFilter` clears with the
  /// rest of the progress maps.
  final String? runFilter;

  const NodeActivitySnapshot({
    this.status,
    this.percent,
    this.detail,
    this.structuredDetail,
    this.runFilter,
  });

  /// Fold one progress update in. `null` arguments leave the remembered value
  /// alone — that asymmetry is the entire point of the snapshot.
  NodeActivitySnapshot fold({
    NodeStatus? status,
    double? percent,
    String? detail,
    InstructionProgressDetail? structuredDetail,
    String? runFilter,
  }) {
    return NodeActivitySnapshot(
      status: status ?? this.status,
      percent: percent ?? this.percent,
      detail: detail ?? this.detail,
      structuredDetail: structuredDetail ?? this.structuredDetail,
      runFilter: runFilter ?? this.runFilter,
    );
  }

  // Value equality lets `provider.select((m) => m[nodeId])` dedupe rebuilds:
  // a progress tick that rewrites an identical snapshot must not rebuild the
  // tab.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NodeActivitySnapshot &&
          other.status == status &&
          other.percent == percent &&
          other.detail == detail &&
          other.structuredDetail == structuredDetail &&
          other.runFilter == runFilter;

  @override
  int get hashCode =>
      Object.hash(status, percent, detail, structuredDetail, runFilter);
}

/// Per-node session memory of run progress, keyed by node id.
///
/// Written ONLY by folding [sequenceProgressProvider] deltas: every key the
/// progress maps touch is folded in, and a node whose status transitions INTO
/// `running` first drops its previous snapshot — a fresh pass over the node is
/// no longer the previous run's story (mirrors `_NodeItem.didUpdateWidget`'s
/// `_forgetLiveProgress`). `SequenceProgressNotifier.reset()` empties the maps
/// without touching this state, which is exactly what lets a finished node's
/// last readings survive for the rest of the session.
///
/// One bound on that survival: a NEW run clears the whole map. `reset()`
/// also empties the progress maps, so it is invisible inside `_fold` — the
/// signal that separates "run ended, keep the memory" from "run #2 is
/// starting, run #1's frames are no longer this node's story" is the
/// execution-state transition into `running` from a state the enum itself
/// marks as start-admissible (`canStart`: idle / completed / failed). Resume
/// arrives via `paused`/`recovering` and deliberately does not clear.
///
/// The tree keeps its private copy in `_NodeItem` until the density-mode
/// workstream removes the inline panels; this provider is the shared slot the
/// inspector (and eventually the tree) reads.
final lastKnownNodeActivityProvider = StateNotifierProvider<
    LastKnownNodeActivityNotifier, Map<String, NodeActivitySnapshot>>(
  (ref) => LastKnownNodeActivityNotifier(ref),
);

class LastKnownNodeActivityNotifier
    extends StateNotifier<Map<String, NodeActivitySnapshot>> {
  LastKnownNodeActivityNotifier(Ref ref) : super(const {}) {
    _fold(ref.read(sequenceProgressProvider));
    ref.listen(sequenceProgressProvider, (_, next) => _fold(next));
    ref.listen(sequenceExecutionStateProvider, (prev, next) {
      final started =
          next == SequenceExecutionState.running && (prev?.canStart ?? false);
      if (started && state.isNotEmpty) state = const {};
    });
  }

  void _fold(SequenceProgress progress) {
    final ids = <String>{
      ...progress.nodeStatuses.keys,
      ...progress.nodeProgressPercent.keys,
      ...progress.nodeProgressDetail.keys,
      ...progress.nodeProgressStructuredDetail.keys,
    };
    if (ids.isEmpty) return;

    final next = Map<String, NodeActivitySnapshot>.of(state);
    for (final id in ids) {
      var snapshot = next[id] ?? const NodeActivitySnapshot();
      final status = progress.nodeStatuses[id];
      if (status == NodeStatus.running && snapshot.status != status) {
        // Fresh pass: last run's frames are no longer this node's
        // story, so the snapshot restarts from the running marker alone.
        snapshot = const NodeActivitySnapshot(status: NodeStatus.running);
      }
      next[id] = snapshot.fold(
        status: status,
        percent: progress.nodeProgressPercent[id],
        detail: progress.nodeProgressDetail[id],
        structuredDetail: progress.nodeProgressStructuredDetail[id],
        runFilter: progress.currentFilter,
      );
    }
    state = next;
  }
}

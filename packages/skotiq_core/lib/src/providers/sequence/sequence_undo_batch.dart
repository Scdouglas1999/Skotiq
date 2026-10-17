import '../../models/sequence/sequence_models.dart';

/// Mixin that adds coalesced undo entries to [CurrentSequenceNotifier].
///
/// Multiple `_saveUndo()` calls inside a `withUndoBatch` block collapse into
/// a single snapshot (taken at batch-start), so multi-node operations like
/// snippet insertion only push one undo entry instead of N.
///
/// Implementations must:
///   * expose the undo/redo stacks as `undoStack` / `redoStack` getters
///     (returning mutable lists);
///   * expose the current sequence state via the `currentState` getter
///     (the notifier's `state`).
mixin UndoBatchMixin {
  /// Maximum size of the undo stack. Older entries are discarded FIFO once
  /// this is exceeded.
  static const int maxUndoDepth = 50;

  /// Soft cap on the total number of retained nodes across the whole undo
  /// stack. After the depth cap is applied we keep trimming the oldest
  /// entries while the summed `nodes.length` of all retained snapshots
  /// exceeds this budget. This bounds memory for users editing very large
  /// sequences (hundreds of nodes) where 50 full snapshots could otherwise
  /// retain tens of thousands of node references — without hurting the
  /// common small-sequence case, which never approaches the budget.
  static const int maxUndoRetainedNodes = 5000;

  int _batchDepth = 0;
  bool _batchSnapshotTaken = false;

  List<Sequence> get undoStack;
  List<Sequence> get redoStack;

  /// The current sequence state. Null when there is no active sequence —
  /// in that case no undo entry is pushed.
  Sequence? get currentState;

  /// Push an undo entry for the current state.
  ///
  /// Inside a `withUndoBatch` block, only the first call within the
  /// outermost batch actually pushes (later calls within the same batch
  /// are no-ops); outside any batch, every call pushes.
  void saveUndo() {
    final snapshot = currentState;
    if (snapshot == null) return;

    if (_batchDepth > 0) {
      if (_batchSnapshotTaken) return;
      _batchSnapshotTaken = true;
    }

    undoStack.add(snapshot);
    redoStack.clear();
    if (undoStack.length > maxUndoDepth) {
      undoStack.removeAt(0);
    }

    // Node-count budget: trim oldest entries while the retained snapshots
    // collectively hold more than [maxUndoRetainedNodes] nodes. Always keep
    // at least one entry so a single huge sequence is still undoable once.
    var retained = undoStack.fold<int>(0, (sum, s) => sum + s.nodes.length);
    while (undoStack.length > 1 && retained > maxUndoRetainedNodes) {
      retained -= undoStack.first.nodes.length;
      undoStack.removeAt(0);
    }
  }

  /// Run [action] with undo batching enabled. All `saveUndo()` calls inside
  /// [action] (including transitively through any helpers it calls) coalesce
  /// into a single undo entry. Nested batches are supported; only the
  /// outermost batch actually takes a snapshot.
  ///
  /// Returns whatever [action] returns. If [action] throws, the batch is
  /// still finalized so subsequent edits behave normally.
  T withUndoBatch<T>(T Function() action) {
    _batchDepth++;
    final isOutermost = _batchDepth == 1;
    if (isOutermost) {
      _batchSnapshotTaken = false;
    }
    try {
      return action();
    } finally {
      _batchDepth--;
      if (_batchDepth == 0) {
        _batchSnapshotTaken = false;
      }
    }
  }
}

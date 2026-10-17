import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../models/imaging/imaging_models.dart';
import '../../models/sequence/active_plan_owner.dart';
import '../../models/sequence/sequence_models.dart';
import '../../models/sequence/template_snippet.dart';
import '../../services/sequence_file_service.dart';
import '../sequence_provider.dart' show sequenceExecutionStateProvider;
import 'sequence_editor_exceptions.dart';
import 'target_catalog_coordinate_sync.dart';
import 'sequence_undo_batch.dart';
import 'sequence_validation.dart' show isContainerNode;

export 'sequence_editor_exceptions.dart';

part 'sequence_editor/snippet_editing.dart';
part 'sequence_editor/tree_editing.dart';

/// Reactive view of who owns the currently-loaded plan (manual vs an automated
/// planner). Written by [CurrentSequenceNotifier]; watched by UI banners and by
/// the master/slave editor mirror so a slave can render the host's autopilot
/// ownership instead of a stale manual canvas.
///
/// Declared here (alongside the notifier) so the notifier can update it through
/// its owning [Ref] without a circular import. Defaults to
/// [ActivePlanOwner.manual].
final activePlanOwnerProvider = StateProvider<ActivePlanOwner>(
  (ref) => ActivePlanOwner.manual,
);

/// Provider exposing whether the current sequence can be edited.
///
/// Returns `false` while the sequence is Running / Paused / Stopping — those
/// are the phases where the executor owns the tree. Returns `true` for Idle,
/// Completed, and Failed.
///
/// UI should `watch` this provider to gray out edit affordances. The notifier
/// itself enforces the gate by throwing [SequenceLockedException] from
/// mutating methods, so this provider is for UX, not security.
final canEditSequenceProvider = Provider<bool>((ref) {
  final state = ref.watch(sequenceExecutionStateProvider);
  return _isEditable(state);
});

bool _isEditable(SequenceExecutionState state) {
  switch (state) {
    case SequenceExecutionState.idle:
    case SequenceExecutionState.completed:
    case SequenceExecutionState.failed:
      return true;
    case SequenceExecutionState.running:
    case SequenceExecutionState.paused:
    case SequenceExecutionState.stopping:
    // Recovery Mode — recovery is an in-flight execution state.
    // Editing the sequence mid-recovery would split the user's mental
    // model between "the executor is still running" and "I'm about to
    // change what it does", so we lock the editor here just like during
    // running/paused. The Run Dashboard banner is the right place for
    // operator action during recovery.
    case SequenceExecutionState.recovering:
      return false;
    // A failed stop (hardware possibly still imaging) or a pending persistence
    // cleanup (dangling session) both keep the executor in charge of the run
    // lifecycle, so the tree stays locked until the stop / cleanup completes.
    case SequenceExecutionState.stopFailed:
    case SequenceExecutionState.cleanupFailed:
    // Finalizing — the run has ended and durable cleanup is in flight. The
    // executor still owns the run lifecycle, so keep the tree locked until it
    // settles.
    case SequenceExecutionState.finalizing:
      return false;
  }
}

/// Editor StateNotifier for the sequence currently being authored.
///
/// Holds undo/redo stacks plus tree-mutation helpers. The notifier itself is
/// stateful but owns no streams or timers, so it does not require a dispose
/// override — Riverpod tears down the underlying state when the provider is
/// disposed.
///
/// Construction takes the owning [Ref] so mutating methods can read the
/// `sequenceExecutionStateProvider` and refuse edits while the run is active.
/// Pass `null` only in unit tests that never exercise the execution-state
/// gate; production wiring in `sequence_provider.dart` always passes a Ref.
class CurrentSequenceNotifier extends StateNotifier<Sequence?>
    with UndoBatchMixin {
  CurrentSequenceNotifier({Ref? ref}) : _ref = ref, super(null);

  final Ref? _ref;
  final _undoStack = <Sequence>[];
  final _redoStack = <Sequence>[];

  /// The manual sequence stashed when an automated planner (autopilot / Smart
  /// Night / mosaic) took over the editor slot, plus its dirty flag at the time
  /// of the hand-off. Restored verbatim by [releaseOwnership] when the planner
  /// stops, so starting the autopilot never destroys unsaved manual work.
  Sequence? _stashedManualSequence;
  bool _stashedManualDirty = false;

  /// Who currently owns the loaded plan. The notifier is the source of truth;
  /// it mirrors every change onto [activePlanOwnerProvider] (when a [Ref] is
  /// present) so the value is reactively observable by UI and the slave mirror.
  ActivePlanOwner _owner = ActivePlanOwner.manual;

  /// Who currently owns the loaded plan (manual operator vs an automated
  /// planner). Defaults to [ActivePlanOwner.manual].
  ActivePlanOwner get activeOwner => _owner;

  void _setOwner(ActivePlanOwner owner) {
    _owner = owner;
    final ref = _ref;
    if (ref == null) return;
    // Mirror onto the global owner provider. This is reached during container
    // teardown via SchedulerEngine.dispose() -> releaseSequenceOwnership(); if
    // activePlanOwnerProvider was disposed first, ref.read throws. The local
    // `_owner` above is the source of truth and is already set, so swallow the
    // reactive-mirror failure rather than let it escape disposal as an
    // unhandled async error (and leak engine resources behind the throw).
    try {
      // Avoid a redundant rebuild when nothing changed.
      if (ref.read(activePlanOwnerProvider) != owner) {
        ref.read(activePlanOwnerProvider.notifier).state = owner;
      }
    } catch (_) {
      // Provider already torn down — the local _owner remains authoritative.
    }
  }

  Sequence? get _currentSequence => state;
  set _currentSequence(Sequence? value) => state = value;

  /// True when the in-editor sequence has been mutated since the last
  /// load / create / explicit [markSaved] call. Used by [createSequence]
  /// and [loadSequence] to refuse to clobber unsaved work, and exposed
  /// publicly via [isDirty] so the UI can show a "*" on the title bar.
  ///
  bool _dirty = false;

  /// Whether the in-editor sequence has unsaved changes since the last
  /// save (or since it was loaded fresh). UI may surface this via title-
  /// bar indicators or by gating destructive nav actions.
  bool get isDirty => _dirty;

  /// Mark the in-editor sequence as saved. Called by:
  ///   * [SequenceRepository] write paths (manual Save button, OK in
  ///     property dialogs that persist directly).
  ///   * [AutoSaveService] after a successful auto-save tick.
  ///   * [SequenceFileService.exportSequence] after a successful export.
  /// After this returns, [isDirty] is `false` and [createSequence] /
  /// [loadSequence] will not throw [UnsavedChangesException].
  void markSaved() {
    _dirty = false;
  }

  /// Mark an exported snapshot clean only if it is still the exact document
  /// in the editor.
  ///
  /// Native save dialogs can remain open while the user continues editing.
  /// An export that writes the older snapshot must not clear the dirty flag
  /// for those newer edits merely because both snapshots share a sequence id.
  bool markSavedIfCurrent(Sequence expectedSnapshot) {
    if (!identical(state, expectedSnapshot)) return false;
    _dirty = false;
    return true;
  }

  /// Apply a successful remote/host persist without letting an older response
  /// mark newer edits as saved.
  ///
  /// Used by [remoteSequenceEditorSyncProvider] after debounced auto-save so
  /// newly created sequences receive their host `databaseId` and subsequent
  /// edits update the same row. Returns `true` only when [expectedSnapshot] is
  /// still the exact document in the editor and was therefore marked clean.
  ///
  /// If the same new sequence was edited while the request was in flight, its
  /// assigned host id is applied but the dirty flag stays armed so the newer
  /// document is sent next. If another sequence was opened, the stale result
  /// is ignored completely.
  bool applyRemoteSave(int databaseId, {required Sequence expectedSnapshot}) {
    final current = state;
    if (current == null || current.id != expectedSnapshot.id) return false;

    if (identical(current, expectedSnapshot)) {
      state = current.copyWith(databaseId: databaseId);
      _dirty = false;
      return true;
    }

    if (_dirty && current.databaseId == null) {
      state = current.copyWith(databaseId: databaseId);
    }
    return false;
  }

  /// Re-anchor the open editor document after an explicit library save.
  ///
  /// Save dialogs can change the row identity ("Save as new"), name,
  /// description, and whether the row is a template. Leaving the editor on
  /// its pre-save identity makes the next save overwrite the wrong row and
  /// leaves the unsaved-change guard armed even though persistence succeeded.
  /// [expectedSequenceId] prevents a delayed save from rewriting a different
  /// document that was opened while the request was in flight.
  void applyPersistedSave({
    required String expectedSequenceId,
    required int databaseId,
    required String name,
    required String description,
    required bool isTemplate,
  }) {
    final current = state;
    if (current == null || current.id != expectedSequenceId) return;
    state = current.copyWith(
      databaseId: databaseId,
      name: name,
      description: description,
      isTemplate: isTemplate,
      modifiedAt: DateTime.now(),
    );
    _dirty = false;
  }

  @override
  List<Sequence> get undoStack => _undoStack;

  @override
  List<Sequence> get redoStack => _redoStack;

  @override
  Sequence? get currentState => state;

  /// Wrap a multi-step edit so all internal `_saveUndo()` calls collapse into
  /// one undo entry. Exposed publicly so callers performing batched edits
  /// (e.g. drag-drop of a snippet, "apply mosaic plan") can opt in.
  T withUndoGroup<T>(T Function() action) => withUndoBatch(action);

  void _saveUndo() {
    // Every mutation that takes an undo snapshot is by definition a
    // dirtying event. Flip the flag here instead of in every call site so
    // we can't forget — and so the dirty-tracking and undo invariants
    // stay in lockstep.
    _dirty = true;
    saveUndo();
  }

  /// Whether the editor can be mutated right now — the same gate
  /// [_ensureEditable] enforces, for callers that want to SKIP an edit rather
  /// than throw on it (the remote-sync editor mirror). `true` when no [Ref]
  /// is wired (test fixtures without an execution-state provider).
  bool get isEditableNow {
    final ref = _ref;
    if (ref == null) return true;
    return _isEditable(ref.read(sequenceExecutionStateProvider));
  }

  /// Guard mutating operations against being called while the sequence is
  /// running. Throws [SequenceLockedException] when blocked.
  ///
  /// When constructed without a [Ref] (test fixtures), no guard is enforced —
  /// the test is responsible for asserting state directly.
  void _ensureEditable(String operationDescription) {
    final ref = _ref;
    if (ref == null) return;
    final execState = ref.read(sequenceExecutionStateProvider);
    if (!_isEditable(execState)) {
      throw SequenceLockedException(
        attemptedOperation: operationDescription,
        executionState: execState,
      );
    }
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// Roll back the last mutation.
  ///
  /// Gated by [_ensureEditable] — calling `undo()` while a sequence is
  /// Running / Paused / Stopping would rewind Dart-side state while the
  /// native executor keeps marching through the *old* tree, producing the
  /// most pernicious class of split-brain bug imaginable. The notifier
  /// refuses to do that even though the UI also disables Ctrl+Z and the
  /// undo button via [canEditSequenceProvider].
  void undo() {
    _ensureEditable('undo');
    if (_undoStack.isEmpty) return;
    final outgoing = state;
    if (state != null) {
      _redoStack.add(state!);
    }
    state = _undoStack.removeLast();
    // Undoing a re-point is a re-point. The scheduler scores the `targets`
    // table, not the tree, so a snapshot swap has to follow through to the
    // catalog exactly as [CurrentSequenceTreeEditing.updateNode] does.
    _syncTargetsAfterSnapshotSwap(outgoing, state);
  }

  /// Re-apply the last undone mutation. Same reasoning as [undo] — see that
  /// doc.
  void redo() {
    _ensureEditable('redo');
    if (_redoStack.isEmpty) return;
    final outgoing = state;
    if (state != null) {
      _undoStack.add(state!);
    }
    state = _redoStack.removeLast();
    _syncTargetsAfterSnapshotSwap(outgoing, state);
  }

  /// Create a new sequence.
  ///
  /// If the current sequence has unsaved edits ([isDirty]), throws
  /// [UnsavedChangesException] unless [discardUnsaved] is true. UI
  /// callers should catch the exception, prompt "Discard unsaved
  /// changes?", and retry with `discardUnsaved: true` on confirm.
  void createSequence({
    String name = 'New Sequence',
    bool discardUnsaved = false,
  }) {
    _ensureEditable('create sequence');
    _guardUnsavedClobber(
      attemptedOperation: 'create a new sequence',
      discardUnsaved: discardUnsaved,
    );
    _saveUndo();

    final rootId = const Uuid().v4();
    final rootNode = InstructionSetNode(id: rootId, name: 'Sequence');

    state = Sequence.create(
      name: name,
      nodes: {rootId: rootNode},
      rootNodeId: rootId,
    );
    // A brand-new blank sequence has no on-disk counterpart so it is
    // "dirty from birth" — saving will create the row. We still reset
    // the flag here so the prompt doesn't fire on a freshly-created
    // sequence; the next mutation will dirty it again.
    _dirty = false;
    // Same reclaim [loadSequence] performs: building a new plan is a
    // manual-owner action. Without it the slot stays marked "autopilot" for the
    // rest of the session after a single dispatch, and every question that asks
    // WHO owns the plan answers for the scheduler — including the pre-flight
    // warning that exists to say the scheduler is holding the rig, which then
    // stays silent in exactly the two-owner case it is for.
    _reclaimManualOwnership();
  }

  /// Load an existing sequence into the editor.
  ///
  /// If the current sequence has unsaved edits ([isDirty]), throws
  /// [UnsavedChangesException] unless [discardUnsaved] is true. Used by
  /// the import flow, library-open path, and recently-opened menu.
  void loadSequence(Sequence sequence, {bool discardUnsaved = false}) {
    _ensureEditable('open another sequence');
    _guardUnsavedClobber(
      attemptedOperation: 'open another sequence',
      discardUnsaved: discardUnsaved,
    );
    _undoStack.clear();
    _redoStack.clear();
    state = sequence;
    // Loaded from disk → considered clean.
    _dirty = false;
    // A direct load is a manual-owner action (library open, import). If an
    // automated planner had ownership, the operator opening another sequence
    // reclaims the slot; drop any stash so the next release doesn't resurrect
    // a now-irrelevant sequence.
    _reclaimManualOwnership();
  }

  /// Take the editor slot back for the operator.
  ///
  /// Every way the operator puts their OWN plan in the editor — opening one,
  /// creating one, clearing the canvas — has to end with the slot marked
  /// `manual`, because that flag is what the rest of the app asks "whose plan
  /// is this?". The stash goes with it: the sequence an automated planner
  /// displaced is no longer what the operator is working on, so a later release
  /// must not resurrect it over the top of this one.
  void _reclaimManualOwnership() {
    _stashedManualSequence = null;
    _stashedManualDirty = false;
    _setOwner(ActivePlanOwner.manual);
  }

  /// Hand the editor slot to an automated planner ([owner] must be automated:
  /// autopilot / Smart Night / mosaic), preserving the operator's manual work.
  ///
  /// Unlike `loadSequence(..., discardUnsaved: true)` — which silently destroyed
  /// whatever the operator had open — this STASHES the current manual sequence
  /// (and its dirty flag) before loading [sequence], then flips the owner. When
  /// the planner stops, [releaseOwnership] restores the stash so no unsaved
  /// manual work is lost.
  ///
  /// Stashing only happens on the first hand-off (manual -> automated): a
  /// planner re-dispatching while it already owns the slot (e.g. the autopilot
  /// switching targets) replaces the loaded plan without touching the stash, so
  /// the original manual sequence remains the thing restored on stop.
  void takeOwnership(Sequence sequence, ActivePlanOwner owner) {
    assert(
      owner.isAutomated,
      'takeOwnership is for automated planners; use loadSequence for manual',
    );

    if (_owner == ActivePlanOwner.manual) {
      // First hand-off from the operator: preserve the manual canvas so it can
      // be restored when the planner stops. Only stash a non-null sequence —
      // an empty editor has nothing worth restoring.
      _stashedManualSequence = state;
      _stashedManualDirty = _dirty;
    }

    // Bypass the unsaved-clobber guard deliberately: the manual work is safely
    // stashed above, not discarded. Inline the load (rather than calling
    // loadSequence) so we don't reset the stash/owner that loadSequence clears.
    _undoStack.clear();
    _redoStack.clear();
    state = sequence;
    _dirty = false;
    _setOwner(owner);
  }

  /// Restore manual ownership (and the stashed manual sequence) after an
  /// automated planner stops. No-op when the operator already owns the slot.
  ///
  /// Restores the stashed sequence verbatim — including its dirty flag — so the
  /// operator gets their unsaved work back exactly as it was when the planner
  /// took over. When nothing was stashed (the operator started the planner from
  /// an empty editor) the canvas is cleared.
  void releaseOwnership() {
    if (_owner == ActivePlanOwner.manual) return;

    _undoStack.clear();
    _redoStack.clear();
    state = _stashedManualSequence;
    _dirty = _stashedManualDirty;
    _stashedManualSequence = null;
    _stashedManualDirty = false;
    _setOwner(ActivePlanOwner.manual);
  }

  /// Adopt an owner WITHOUT touching the loaded sequence or the stash.
  ///
  /// Used by the master/slave mirror: a slave learns WHO owns the host's plan
  /// from the mirror frame and reflects it onto [activePlanOwnerProvider] so its
  /// UI matches, but the sequence itself arrives through the normal mirror apply
  /// path. The slave never stashes/restores — it follows the host.
  void adoptOwner(ActivePlanOwner owner) => _setOwner(owner);

  /// Load a fresh copy of [source] into the editor, PRESERVING node IDs.
  ///
  /// The copy keeps [Sequence.databaseId], so a later Save updates the same
  /// library row — which is exactly why the node IDs have to survive too. Two
  /// subsystems treat a node's UUID as its durable identity:
  ///
  ///  * [SequenceRepository.saveSequence] upserts incrementally, partitioning
  ///    nodes into update/insert/delete BY ID. Re-keying on open empties the
  ///    update set, turning every save into a full delete-and-reinsert.
  ///  * [SequenceDiffService] matches nodes by ID to produce "modified"
  ///    entries. With fresh IDs the run-history and pre-flight diffs cannot
  ///    report a field change at all — every edit renders as a remove/add pair.
  ///
  /// Sharing node identity with the source row is the intent, not a collision:
  /// the copy points at the SAME row. Producing a genuinely independent
  /// sequence is duplication, which is [SequencesDao.duplicateSequence]'s job
  /// and does mint new UUIDs.
  ///
  /// Nodes are immutable, so rebuilding the map is copy enough — nothing the
  /// editor does afterwards can write through to [source].
  ///
  /// Centralises the copy-on-open dance that the Sequence Library tab performs
  /// inline so other entry points (e.g. Framing's "Add target to an existing
  /// sequence") open library sequences identically. Throws
  /// [UnsavedChangesException] when the editor holds unsaved work unless
  /// [discardUnsaved] is true, and [SequenceLockedException] when a run is
  /// active — same gates as [loadSequence].
  void loadCopyForEditing(Sequence source, {bool discardUnsaved = false}) {
    _ensureEditable('open a sequence for editing');

    final copy = Sequence.create(
      name: source.name,
      description: source.description,
      nodes: Map<String, SequenceNode>.of(source.nodes),
      rootNodeId: source.rootNodeId,
      isTemplate: false,
      databaseId: source.databaseId,
    );

    loadSequence(copy, discardUnsaved: discardUnsaved);
  }

  /// Clear the current sequence
  void clearSequence({bool discardUnsaved = false}) {
    _ensureEditable('clear the sequence');
    _guardUnsavedClobber(
      attemptedOperation: 'clear the sequence',
      discardUnsaved: discardUnsaved,
    );
    _undoStack.clear();
    _redoStack.clear();
    state = null;
    _dirty = false;
    _reclaimManualOwnership();
  }

  void _guardUnsavedClobber({
    required String attemptedOperation,
    required bool discardUnsaved,
  }) {
    if (discardUnsaved) return;
    if (!_dirty) return;
    final current = state;
    if (current == null) return;
    throw UnsavedChangesException(
      attemptedOperation: attemptedOperation,
      currentSequenceName: current.name,
    );
  }

  /// Update sequence name.
  ///
  /// Trims the input and early-returns (without consuming an undo slot) when
  /// the result is empty or unchanged — a no-op rename should not pollute the
  /// undo stack, and an empty name is rejected outright. UI rename surfaces
  /// also pre-validate, but this is the last line of defense.
  void setName(String name) {
    if (state == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == state!.name) return;
    _ensureEditable('rename sequence');
    _saveUndo();
    state = state!.copyWith(name: trimmed, modifiedAt: DateTime.now());
  }

  /// Update sequence description
  void setDescription(String description) {
    if (state == null) return;
    _ensureEditable('edit description');
    _saveUndo();
    state = state!.copyWith(
      description: description,
      modifiedAt: DateTime.now(),
    );
  }
}

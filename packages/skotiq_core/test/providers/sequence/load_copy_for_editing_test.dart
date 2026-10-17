import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/services/sequence_diff_service.dart';

/// Coverage for [CurrentSequenceNotifier.loadCopyForEditing] — the copy-on-open
/// helper used to load a chosen library sequence (Framing's "add target to an
/// existing sequence", and the headless `load-and-start` route) before editing
/// or running it.
///
/// The copy PRESERVES node IDs: it points at the same library row, and both
/// the incremental save partitioning and the sequence diff key off node
/// identity — see `preserves node IDs` below.

ProviderContainer _newContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

CurrentSequenceNotifier _notifier(ProviderContainer c) =>
    c.read(currentSequenceProvider.notifier);

/// A two-node source sequence: root InstructionSet + one TargetHeader child.
Sequence _sourceSequence() {
  const rootId = 'root-original';
  const targetId = 'target-original';
  final root = InstructionSetNode(
    id: rootId,
    name: 'Sequence',
    childIds: const [targetId],
  );
  final target = TargetHeaderNode(
    id: targetId,
    name: 'M31',
    targetName: 'M31',
    raHours: 0.71,
    decDegrees: 41.27,
    parentId: rootId,
  );
  return Sequence.create(
    name: 'My Manual Sequence',
    databaseId: 42,
    nodes: {rootId: root, targetId: target},
    rootNodeId: rootId,
  );
}

void main() {
  group('loadCopyForEditing', () {
    test('preserves node IDs and topology when opening a saved row', () {
      final c = _newContainer();
      final source = _sourceSequence();

      _notifier(c).loadCopyForEditing(source);

      final loaded = c.read(currentSequenceProvider);
      expect(loaded, isNotNull);
      // Original library row reference preserved so Save updates the same row.
      expect(loaded!.databaseId, 42);
      expect(loaded.name, 'My Manual Sequence');

      // Node IDs are the durable identity of a node. Re-keying them here broke
      // two subsystems that key on them:
      //   * SequenceRepository.saveSequence upserts by ID, so an emptied update
      //     set made every save delete and re-insert every node row.
      //   * SequenceDiffService matches by ID, so re-running an UNTOUCHED
      //     sequence reported every node as both removed and added ("+2 -2",
      //     identical labels on both sides) and a real field edit could never
      //     render as "modified".
      expect(
        loaded.nodes.keys,
        containsAll(['root-original', 'target-original']),
      );
      expect(loaded.rootNodeId, 'root-original');
      expect(loaded.nodes, hasLength(2));

      // Topology preserved: the root has one child and it is the target.
      final root = loaded.nodes[loaded.rootNodeId!]!;
      expect(root, isA<InstructionSetNode>());
      expect(root.childIds, hasLength(1));
      final childId = root.childIds.first;
      final child = loaded.nodes[childId]!;
      expect(child, isA<TargetHeaderNode>());
      expect((child as TargetHeaderNode).targetName, 'M31');
      expect(child.parentId, loaded.rootNodeId);
    });

    test('two opens of the same row produce an EMPTY diff', () {
      // The user-visible symptom: the pre-flight card claimed "Sequence has
      // changed since last successful run — 4 changes across 2 added, 2 removed"
      // for a sequence nobody had touched between two runs.
      final first = _newContainer();
      _notifier(first).loadCopyForEditing(_sourceSequence());
      final a = first.read(currentSequenceProvider)!;

      final second = _newContainer();
      _notifier(second).loadCopyForEditing(_sourceSequence());
      final b = second.read(currentSequenceProvider)!;

      final diff = const SequenceDiffService().diff(previous: a, current: b);
      expect(
        diff.isEmpty,
        isTrue,
        reason:
            'nothing changed between the two opens, but the diff reported '
            '${diff.summary} (+${diff.added.length} -${diff.removed.length} '
            '~${diff.modified.length})',
      );
    });

    test('a real edit still shows up as a MODIFIED node, not remove+add', () {
      // With fresh IDs the ID intersection is always empty, so
      // SequenceDiffService's per-field comparison — every node subtype,
      // hundreds of lines of it — never runs.
      final before = _newContainer();
      _notifier(before).loadCopyForEditing(_sourceSequence());
      final a = before.read(currentSequenceProvider)!;

      final after = _newContainer();
      _notifier(after).loadCopyForEditing(_sourceSequence());
      final loaded = after.read(currentSequenceProvider)!;
      final target = loaded.nodes['target-original']! as TargetHeaderNode;
      final b = loaded.copyWith(
        nodes: {
          ...loaded.nodes,
          'target-original': target.copyWith(targetName: 'NGC 891'),
        },
      );

      final diff = const SequenceDiffService().diff(previous: a, current: b);
      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.modified, hasLength(1));
      expect(
        diff.modified.single.changes.map((c) => c.describe()),
        contains('Target name: M31 → NGC 891'),
      );
    });

    test(
      'appending a bare target after a copy-open does not alias originals',
      () {
        final c = _newContainer();
        _notifier(c).loadCopyForEditing(_sourceSequence());

        _notifier(c).addTargetHeader(
          TargetHeaderNode(
            name: 'NGC 891',
            targetName: 'NGC 891',
            raHours: 2.37,
            decDegrees: 42.35,
          ),
        );

        final loaded = c.read(currentSequenceProvider)!;
        final targets = loaded.nodes.values
            .whereType<TargetHeaderNode>()
            .toList();
        expect(
          targets.map((t) => t.targetName),
          containsAll(['M31', 'NGC 891']),
        );
        // The new header is a child of the copied root, not orphaned.
        final root = loaded.nodes[loaded.rootNodeId!]!;
        expect(root.childIds, hasLength(2));
      },
    );

    test('refuses to clobber unsaved edits unless discardUnsaved is true', () {
      final c = _newContainer();
      _notifier(c).createSequence(name: 'work in progress');
      // Dirty the editor.
      _notifier(c).addTargetHeader(
        TargetHeaderNode(
          name: 'dirty',
          targetName: 'dirty',
          raHours: 1.0,
          decDegrees: 1.0,
        ),
      );

      expect(
        () => _notifier(c).loadCopyForEditing(_sourceSequence()),
        throwsA(isA<UnsavedChangesException>()),
      );

      // With discardUnsaved the load proceeds.
      _notifier(c).loadCopyForEditing(_sourceSequence(), discardUnsaved: true);
      expect(c.read(currentSequenceProvider)!.databaseId, 42);
    });

    test('throws SequenceLockedException while a run is active', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      expect(
        () => _notifier(c).loadCopyForEditing(_sourceSequence()),
        throwsA(isA<SequenceLockedException>()),
      );
    });
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/models/sequence/template_snippet.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

/// Coverage for the editor's fail-loud behaviours, so a silent fallback cannot
/// creep back in.

ProviderContainer _newContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

CurrentSequenceNotifier _notifier(ProviderContainer c) =>
    c.read(currentSequenceProvider.notifier);

TargetHeaderNode _target(
  String name, {
  double ra = 1.0,
  double dec = 0.0,
  String? id,
  String? parentId,
}) => TargetHeaderNode(
  id: id,
  name: name,
  targetName: name,
  raHours: ra,
  decDegrees: dec,
  parentId: parentId,
  isEnabled: true,
);

void main() {
  group('canEditSequenceProvider', () {
    test('reports true for idle/completed/failed states', () {
      for (final state in [
        SequenceExecutionState.idle,
        SequenceExecutionState.completed,
        SequenceExecutionState.failed,
      ]) {
        final c = _newContainer();
        c.read(sequenceExecutionStateProvider.notifier).state = state;
        expect(
          c.read(canEditSequenceProvider),
          isTrue,
          reason: 'state=$state should be editable',
        );
      }
    });

    test('reports false for running/paused/stopping', () {
      for (final state in [
        SequenceExecutionState.running,
        SequenceExecutionState.paused,
        SequenceExecutionState.stopping,
      ]) {
        final c = _newContainer();
        c.read(sequenceExecutionStateProvider.notifier).state = state;
        expect(
          c.read(canEditSequenceProvider),
          isFalse,
          reason: 'state=$state should be locked',
        );
      }
    });
  });

  group('SequenceLockedException', () {
    test('loadSequence and clearSequence throw while a run is active', () {
      final c = _newContainer();
      final notifier = _notifier(c)..createSequence(name: 'active plan');
      final replacement = Sequence.create(name: 'replacement');
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

      expect(
        () => notifier.loadSequence(replacement, discardUnsaved: true),
        throwsA(isA<SequenceLockedException>()),
      );
      expect(
        () => notifier.clearSequence(discardUnsaved: true),
        throwsA(isA<SequenceLockedException>()),
      );
      expect(c.read(currentSequenceProvider)?.name, 'active plan');
    });

    test('addNode throws when sequence is running', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      final n = _notifier(c);
      expect(
        () => n.addNode(_target('M31', id: 'm31')),
        throwsA(isA<SequenceLockedException>()),
      );
    });

    test('removeNode throws when sequence is paused', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      _notifier(c).addNode(_target('M31', id: 'm31'));
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.paused;
      expect(
        () => _notifier(c).removeNode('m31'),
        throwsA(isA<SequenceLockedException>()),
      );
    });

    test('reorderTargets throws while running', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      _notifier(c).addTargetHeader(_target('A'));
      _notifier(c).addTargetHeader(_target('B'));
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      expect(
        () => _notifier(c).reorderTargets(0, 1),
        throwsA(isA<SequenceLockedException>()),
      );
    });

    test('thrown exception carries the operation description', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      try {
        _notifier(c).addNode(_target('M31', id: 'm31'));
        fail('expected SequenceLockedException');
      } on SequenceLockedException catch (e) {
        expect(e.attemptedOperation, 'add node');
        expect(e.executionState, SequenceExecutionState.running);
        expect(e.message, contains('Stop the sequence first'));
      }
    });

    test('undo throws when sequence is running', () {
      // Load-bearing gate: an undo mid-run rolls back Dart state while Rust
      // keeps executing the old tree (split-brain). The notifier itself must
      // refuse, even though the UI also gates Ctrl+Z and the undo button via
      // canEditSequenceProvider.
      final c = _newContainer();
      _notifier(c).createSequence();
      _notifier(c).setName('baseline');
      expect(_notifier(c).canUndo, isTrue);
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      expect(
        () => _notifier(c).undo(),
        throwsA(isA<SequenceLockedException>()),
      );
    });

    test('redo throws when sequence is running (trust-patch §B item 1)', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      _notifier(c).setName('one');
      // Undo creates a redo entry.
      _notifier(c).undo();
      expect(_notifier(c).canRedo, isTrue);
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      expect(
        () => _notifier(c).redo(),
        throwsA(isA<SequenceLockedException>()),
      );
    });

    test('undo carries the "undo" operation description', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      _notifier(c).setName('baseline');
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.paused;
      try {
        _notifier(c).undo();
        fail('expected SequenceLockedException');
      } on SequenceLockedException catch (e) {
        expect(e.attemptedOperation, 'undo');
        expect(e.executionState, SequenceExecutionState.paused);
      }
    });

    test('undo/redo permitted again after sequence transitions to idle', () {
      // Verifies the gate releases when the run ends — important so a
      // completed/failed run doesn't leave the editor permanently locked.
      final c = _newContainer();
      _notifier(c).createSequence();
      _notifier(c).setName('one');
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      expect(
        () => _notifier(c).undo(),
        throwsA(isA<SequenceLockedException>()),
      );
      // Run terminates -> editing restored.
      c.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.completed;
      expect(() => _notifier(c).undo(), returnsNormally);
    });
  });

  group('NoActiveSequenceException', () {
    test('addTargetHeader throws when no sequence is loaded', () {
      final c = _newContainer();
      expect(_notifier(c).state, isNull);
      try {
        _notifier(c).addTargetHeader(_target('M31'));
        fail('expected NoActiveSequenceException');
      } on NoActiveSequenceException catch (e) {
        expect(e.attemptedOperation, contains('M31'));
      }
    });

    test('addTargetHeader does not silently create a sequence', () {
      final c = _newContainer();
      try {
        _notifier(c).addTargetHeader(_target('M31'));
      } on NoActiveSequenceException {
        // expected
      }
      // Without the guard this silently creates a "New Sequence".
      expect(c.read(currentSequenceProvider), isNull);
    });
  });

  group('CrossParentReorderException', () {
    test('throws when targets share different parents', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      final sequence = c.read(currentSequenceProvider)!;
      final rootId = sequence.rootNodeId!;

      // Build two sibling containers (Loops) that each hold one target.
      final loopA = LoopNode(id: 'loopA', name: 'A', parentId: rootId);
      final loopB = LoopNode(id: 'loopB', name: 'B', parentId: rootId);
      _notifier(c).addNode(loopA, parentId: rootId);
      _notifier(c).addNode(loopB, parentId: rootId);
      _notifier(c).addNode(_target('A1', id: 'aT'), parentId: 'loopA');
      _notifier(c).addNode(_target('B1', id: 'bT'), parentId: 'loopB');

      // targetHeaders flattens across parents; reorderTargets(1, 0)
      // (downward swap, no Flutter index adjustment) tries to swap the two
      // targets — but they live under different loops, so the editor
      // refuses with CrossParentReorderException.
      expect(
        () => _notifier(c).reorderTargets(1, 0),
        throwsA(isA<CrossParentReorderException>()),
      );
    });

    test('does not throw when targets share the same parent', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      _notifier(c).addTargetHeader(_target('A'));
      _notifier(c).addTargetHeader(_target('B'));
      // Two siblings under root — should succeed.
      expect(() => _notifier(c).reorderTargets(0, 1), returnsNormally);
    });
  });

  group('SnippetDeserializationException', () {
    test('unknown nodeType throws — does NOT silently fall through', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      final snippet = TemplateSnippet(
        id: 'bad',
        name: 'Future Node Snippet',
        description: 'Authored by Skotiq 99',
        category: SnippetCategory.custom,
        iconName: 'box',
        nodeData: const [
          {'nodeType': 'WarpDrive', 'name': 'Warp'},
        ],
        createdAt: DateTime(2026, 1, 1),
      );

      try {
        _notifier(c).insertSnippet(snippet);
        fail('expected SnippetDeserializationException');
      } on SnippetDeserializationException catch (e) {
        expect(e.unknownType, 'WarpDrive');
        expect(e.snippetName, 'Future Node Snippet');
      }
    });

    test('missing nodeType also throws', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      final snippet = TemplateSnippet(
        id: 'noType',
        name: 'Missing Type',
        description: 'malformed',
        category: SnippetCategory.custom,
        iconName: 'box',
        nodeData: const [
          {'name': 'orphan'},
        ],
        createdAt: DateTime(2026, 1, 1),
      );
      expect(
        () => _notifier(c).insertSnippet(snippet),
        throwsA(isA<SnippetDeserializationException>()),
      );
    });
  });

  group('Sequence.countDescendants', () {
    test('returns 0 for leaf', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      final exposure = ExposureNode(
        id: 'e1',
        name: 'L',
        durationSecs: 60,
        count: 5,
      );
      _notifier(c).addNode(exposure);
      final seq = c.read(currentSequenceProvider)!;
      expect(seq.countDescendants('e1'), 0);
    });

    test('counts entire subtree, not just direct children', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      _notifier(c).addNode(_target('M31', id: 't1'));
      _notifier(c).addNode(
        LoopNode(id: 'L', name: 'L'),
        parentId: 't1',
      );
      _notifier(c).addNode(
        ExposureNode(id: 'E', name: 'Exp', durationSecs: 60, count: 1),
        parentId: 'L',
      );
      final seq = c.read(currentSequenceProvider)!;
      // t1 -> L -> E  = 2 descendants
      expect(seq.countDescendants('t1'), 2);
      expect(seq.countDescendants('L'), 1);
      expect(seq.countDescendants('E'), 0);
    });

    test('returns 0 for nonexistent id', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      final seq = c.read(currentSequenceProvider)!;
      expect(seq.countDescendants('does-not-exist'), 0);
    });
  });

  group('Undo batching via withUndoGroup', () {
    test('snippet insert pushes exactly one undo entry, not N', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      // Push a no-op edit to bring the undo stack into a known state so we
      // can detect that exactly ONE additional entry comes from the snippet
      // insertion (not three).
      _notifier(c).setName('baseline');
      expect(
        _notifier(c).canUndo,
        isTrue,
        reason: 'setName saved one undo entry',
      );

      // Build a 3-node snippet (exposure -> exposure -> dither). After
      // insertion, exactly ONE additional undo entry should exist.
      final snippet = TemplateSnippet(
        id: 's1',
        name: 'LRGB Burst',
        description: 'three nodes',
        category: SnippetCategory.custom,
        iconName: 'star',
        nodeData: const [
          {'nodeType': 'Exposure', 'name': 'L', 'durationSecs': 60, 'count': 5},
          {'nodeType': 'Exposure', 'name': 'R', 'durationSecs': 60, 'count': 5},
          {'nodeType': 'Dither', 'name': 'D'},
        ],
        createdAt: DateTime(2026, 1, 1),
      );

      // Track undo depth before/after.
      // Count: undo a couple of times — after one undo we should be back
      // to the pre-insert state (all three nodes gone).
      _notifier(c).insertSnippet(snippet);
      final afterInsert = c.read(currentSequenceProvider)!;
      // 3 children plus root.
      final rootId = afterInsert.rootNodeId!;
      expect(afterInsert.getChildren(rootId).length, 3);

      _notifier(c).undo();
      final afterUndo = c.read(currentSequenceProvider)!;
      expect(
        afterUndo.getChildren(rootId).length,
        0,
        reason:
            'single undo should clear all three snippet nodes if batched correctly',
      );
    });

    test('withUndoGroup coalesces nested edits into one entry', () {
      final c = _newContainer();
      _notifier(c).createSequence();
      final n = _notifier(c);

      n.withUndoGroup(() {
        n.addNode(ExposureNode(id: 'a', durationSecs: 1, count: 1, name: 'a'));
        n.addNode(ExposureNode(id: 'b', durationSecs: 1, count: 1, name: 'b'));
        n.addNode(ExposureNode(id: 'c', durationSecs: 1, count: 1, name: 'c'));
      });

      final before = c.read(currentSequenceProvider)!;
      final rootId = before.rootNodeId!;
      expect(before.getChildren(rootId).length, 3);

      n.undo();
      final after = c.read(currentSequenceProvider)!;
      expect(
        after.getChildren(rootId).length,
        0,
        reason: 'a single undo should clear all three batched nodes',
      );
    });
  });
}

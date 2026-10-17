// Unit tests for the run-length folding MODEL (spec §6, workstream ws3).
// No widget pump: `sequence_fold_model.dart` is pure Dart over
// `skotiq_core`, and `sequence_fold_state.dart` is exercised through a
// bare `ProviderContainer`. Sequence construction follows the same shape as
// `sequence_tree_sibling_nodes_test.dart` — a real `nodes` map with
// `childIds`/`parentId`/`orderIndex` filled in so `Sequence.childrenOf`
// returns the canonical ordering.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequence_fold_model.dart';
import 'package:skotiq_app/screens/sequencer/sequence_fold_state.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree_shortcuts.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// An exposure node the way a filter-wheel run writes it: identical capture
/// spec, differing only by filter. Defaults are chosen so plain
/// `_exp('Ha'), _exp('OIII')` IS a foldable pair — tests override exactly the
/// field they want to break.
ExposureNode _exp(
  String filter, {
  double durationSecs = 300,
  int count = 12,
  int? gain = 120,
  int? offset = 30,
  BinningMode binning = BinningMode.one,
  FrameType frameType = FrameType.light,
  int? ditherEvery = 3,
  bool isEnabled = true,
  String? name,
}) =>
    ExposureNode(
      name: name ?? 'Take Exposures',
      filter: filter,
      durationSecs: durationSecs,
      count: count,
      gain: gain,
      offset: offset,
      binning: binning,
      frameType: frameType,
      ditherEvery: ditherEvery,
      isEnabled: isEnabled,
    );

/// Wrap [children] under a fresh [InstructionSetNode] root (or a caller-
/// supplied one when two sequences must share a parent id), wiring
/// `parentId`/`orderIndex`/`childIds` the way `CurrentSequenceNotifier` does.
Sequence _sequenceOf(List<SequenceNode> children, {SequenceNode? root}) {
  final parent = root ?? InstructionSetNode(name: 'Sequence');
  final nodes = <String, SequenceNode>{
    for (var i = 0; i < children.length; i++)
      children[i].id: children[i].copyWith(parentId: parent.id, orderIndex: i),
    parent.id: parent.copyWith(childIds: [for (final c in children) c.id]),
  };
  return Sequence.create(name: 'T', nodes: nodes, rootNodeId: parent.id);
}

List<TreeEntry> _fold(Sequence sequence) => foldChildren(
      sequence,
      sequence.rootNodeId!,
      unfoldedGroupIds: const <String>{},
    );

FoldGroup _foldedGroup(List<TreeEntry> entries) =>
    (entries.whereType<FoldedEntry>().single).group;

void main() {
  group('foldChildren — filter runs', () {
    test('three matching exposures fold into one group', () {
      final ha = _exp('Ha');
      final oiii = _exp('OIII');
      final sii = _exp('SII');
      final sequence = _sequenceOf([ha, oiii, sii]);

      final entries = _fold(sequence);

      expect(entries, hasLength(1));
      final group = _foldedGroup(entries);
      expect(group.kind, FoldKind.filterRun);
      expect(group.label, 'Ha · OIII · SII');
      expect(group.chipText, '300 s ×12 each');
      expect(group.memberIds, [ha.id, oiii.id, sii.id]);
      expect(group.memberLabels, ['Ha', 'OIII', 'SII']);
      expect(group.parentId, sequence.rootNodeId);
      expect(group.firstIndex, 0);
      expect(group.durationSecs, 300);
      expect(group.count, 12);
      expect(group.gain, 120);
      expect(group.offset, 30);
      expect(group.binning, BinningMode.one);
      expect(group.frameType, FrameType.light);
      expect(group.ditherEvery, 3);
    });

    test('a run of exactly two folds (spec floor is ≥2)', () {
      final sequence = _sequenceOf([_exp('Ha'), _exp('OIII')]);
      expect(_fold(sequence).single, isA<FoldedEntry>());
    });

    test('a single exposure never folds', () {
      final sequence = _sequenceOf([_exp('Ha')]);
      expect(_fold(sequence).single, isA<SingleEntry>());
    });

    test('a gain difference splits the run at the difference', () {
      final ha = _exp('Ha', gain: 120);
      final oiii = _exp('OIII', gain: 120);
      final sii = _exp('SII', gain: 100);
      final sequence = _sequenceOf([ha, oiii, sii]);

      final entries = _fold(sequence);

      expect(entries, hasLength(2));
      final group = (entries[0] as FoldedEntry).group;
      expect(group.memberIds, [ha.id, oiii.id]);
      expect(entries[1], isA<SingleEntry>());
      expect((entries[1] as SingleEntry).node.id, sii.id);
    });

    test('a difference in the middle leaves non-contiguous matches unfolded',
        () {
      final sequence = _sequenceOf([
        _exp('Ha'),
        _exp('OIII', durationSecs: 60),
        _exp('SII'),
      ]);
      expect(_fold(sequence), everyElement(isA<SingleEntry>()));
    });

    test('a disabled member breaks the run', () {
      final sequence = _sequenceOf([
        _exp('Ha'),
        _exp('OIII', isEnabled: false),
        _exp('SII'),
      ]);
      expect(_fold(sequence), everyElement(isA<SingleEntry>()));
    });

    test('an exposure with children never joins a run', () {
      // A folded row has no way to render a subtree, so a non-leaf exposure
      // is not a candidate even when its capture spec matches.
      final delay = DelayNode(seconds: 5);
      final parent = _exp('Ha');
      final other = _exp('OIII');
      final root = InstructionSetNode(name: 'Sequence');
      final nodes = <String, SequenceNode>{
        parent.id: parent.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [delay.id],
        ),
        other.id: other.copyWith(parentId: root.id, orderIndex: 1),
        delay.id: delay.copyWith(parentId: parent.id, orderIndex: 0),
        root.id: root.copyWith(childIds: [parent.id, other.id]),
      };
      final sequence =
          Sequence.create(name: 'T', nodes: nodes, rootNodeId: root.id);

      expect(_fold(sequence), everyElement(isA<SingleEntry>()));
    });

    test('two separate runs fold independently under one parent', () {
      final narrowband = [_exp('Ha'), _exp('OIII')];
      final broadband = [_exp('L'), _exp('R')];
      final spacer = DelayNode(seconds: 30);
      final sequence = _sequenceOf([...narrowband, spacer, ...broadband]);

      final entries = _fold(sequence);

      expect(entries, hasLength(3));
      expect((entries[0] as FoldedEntry).group.label, 'Ha · OIII');
      expect(entries[1], isA<SingleEntry>());
      expect((entries[2] as FoldedEntry).group.label, 'L · R');
      // Positions are child indexes, not entry indexes — wave-2 drag/drop
      // re-injects a moved group at this slot.
      expect((entries[2] as FoldedEntry).group.firstIndex, 3);
    });

    test('members differing only by name/comment still fold', () {
      final sequence = _sequenceOf([
        _exp('Ha', name: 'Hydrogen alpha'),
        _exp('OIII', name: 'Oxygen III'),
      ]);
      expect(_fold(sequence).single, isA<FoldedEntry>());
    });

    test('group id is stable when an unrelated sibling is renamed', () {
      final ha = _exp('Ha');
      final oiii = _exp('OIII');
      final spacer = DelayNode(seconds: 30, name: 'Delay');
      // Both sequences share the root so the group under comparison has the
      // same parentId — only the sibling's name differs.
      final root = InstructionSetNode(name: 'Sequence');
      final before = _sequenceOf([ha, oiii, spacer], root: root);
      final renamed = _sequenceOf([
        ha,
        oiii,
        spacer.copyWith(name: 'Renamed delay'),
      ], root: root);

      final groupBefore = _foldedGroup(_fold(before));
      final groupAfter = _foldedGroup(_fold(renamed));

      expect(groupAfter.id, groupBefore.id);
      // Membership is identical, so the WHOLE group compares equal — this is
      // what lets a Provider.select skip rebuilds on unrelated edits.
      expect(groupAfter, equals(groupBefore));
    });

    test('an unfolded group emits its members as ordinary rows', () {
      final ha = _exp('Ha');
      final oiii = _exp('OIII');
      final sii = _exp('SII');
      final sequence = _sequenceOf([ha, oiii, sii]);
      final groupId = _foldedGroup(_fold(sequence)).id;

      final entries = foldChildren(
        sequence,
        sequence.rootNodeId!,
        unfoldedGroupIds: {groupId},
      );

      expect(entries, hasLength(3));
      expect(entries, everyElement(isA<SingleEntry>()));
      expect(
        entries.map((e) => (e as SingleEntry).node.id),
        [ha.id, oiii.id, sii.id],
      );
    });

    test('a member with only a filterIndex labels itself #N', () {
      final a =
          ExposureNode(filterIndex: 2, durationSecs: 300, count: 12, gain: 120);
      final b =
          ExposureNode(filterIndex: 5, durationSecs: 300, count: 12, gain: 120);
      final sequence = _sequenceOf([a, b]);

      final group = _foldedGroup(_fold(sequence));
      expect(group.memberLabels, ['#3', '#6']);
      expect(group.label, '#3 · #6');
    });
  });

  group('foldChildren — acquire target', () {
    test('the quartet folds, and a shuffled order still folds', () {
      final sequence = _sequenceOf([
        AutofocusNode(),
        SlewNode(),
        StartGuidingNode(),
        CenterNode(),
      ]);

      final group = _foldedGroup(_fold(sequence));
      expect(group.kind, FoldKind.acquireTarget);
      expect(group.label, 'Acquire target');
      // Tree order, not canonical order — the chip says what will run.
      expect(group.chipText, 'AF · slew · guide · center');
      expect(group.memberIds, hasLength(4));
    });

    test('canonical order renders the spec chip', () {
      final sequence = _sequenceOf([
        SlewNode(),
        CenterNode(),
        StartGuidingNode(),
        AutofocusNode(),
      ]);
      expect(
          _foldedGroup(_fold(sequence)).chipText, 'slew · center · guide · AF');
    });

    test('a triple without autofocus folds', () {
      final sequence = _sequenceOf([
        SlewNode(),
        CenterNode(),
        StartGuidingNode(),
      ]);
      final group = _foldedGroup(_fold(sequence));
      expect(group.kind, FoldKind.acquireTarget);
      expect(group.memberIds, hasLength(3));
    });

    test('a duplicate leaf type does not fold', () {
      final sequence = _sequenceOf([
        SlewNode(),
        SlewNode(),
        CenterNode(),
        StartGuidingNode(),
      ]);
      expect(_fold(sequence), everyElement(isA<SingleEntry>()));
    });

    test('a pair is not an acquire run', () {
      final sequence = _sequenceOf([SlewNode(), CenterNode()]);
      expect(_fold(sequence), everyElement(isA<SingleEntry>()));
    });

    test('a disabled member breaks the acquire run', () {
      final sequence = _sequenceOf([
        SlewNode(),
        CenterNode(isEnabled: false),
        StartGuidingNode(),
        AutofocusNode(),
      ]);
      expect(_fold(sequence), everyElement(isA<SingleEntry>()));
    });

    test('an acquire run followed by a filter run folds both', () {
      final sequence = _sequenceOf([
        SlewNode(),
        CenterNode(),
        StartGuidingNode(),
        _exp('Ha'),
        _exp('OIII'),
      ]);
      final entries = _fold(sequence);
      expect(entries, hasLength(2));
      expect((entries[0] as FoldedEntry).group.kind, FoldKind.acquireTarget);
      expect((entries[1] as FoldedEntry).group.kind, FoldKind.filterRun);
    });
  });

  group('foldProgressText', () {
    test('reads captured counts from the same sources the panel does', () {
      final ha = _exp('Ha');
      final oiii = _exp('OIII');
      final sii = _exp('SII');
      final sequence = _sequenceOf([ha, oiii, sii]);
      final group = _foldedGroup(_fold(sequence));

      final progress = SequenceProgress(
        nodeStatuses: {oiii.id: NodeStatus.success},
        nodeProgressStructuredDetail: {
          // The structured frame count is post-capture: 6 frames landed.
          ha.id: const ExposureInstructionProgressDetail(
            frame: 6,
            total: 12,
            durationSecs: 300,
          ),
        },
        nodeProgressDetail: {
          // "Frame 3/12" is a frame IN FLIGHT — two have landed.
          sii.id: 'Frame 3/12',
        },
      );

      expect(
        foldProgressText(group, progress),
        'Ha 6/12 · OIII 12/12 · SII 2/12',
      );
    });

    test('the Completed wording counts the frame it names', () {
      final ha = _exp('Ha');
      final oiii = _exp('OIII');
      final sequence = _sequenceOf([ha, oiii]);
      final group = _foldedGroup(_fold(sequence));

      final progress = SequenceProgress(
        nodeProgressDetail: {ha.id: 'Completed 4/12'},
      );
      expect(foldProgressText(group, progress), 'Ha 4/12 · OIII 0/12');
    });

    test('is empty when nothing has run', () {
      final sequence = _sequenceOf([_exp('Ha'), _exp('OIII')]);
      final group = _foldedGroup(_fold(sequence));
      expect(foldProgressText(group, const SequenceProgress()), '');
      // Pending statuses are pre-run, not progress.
      final pending = SequenceProgress(nodeStatuses: {
        for (final id in group.memberIds) id: NodeStatus.pending,
      });
      expect(foldProgressText(group, pending), '');
    });

    test('is empty for an acquire group', () {
      final sequence = _sequenceOf([
        SlewNode(),
        CenterNode(),
        StartGuidingNode(),
      ]);
      final group = _foldedGroup(_fold(sequence));
      expect(foldProgressText(group, const SequenceProgress()), '');
    });
  });

  group('foldedMemberIds', () {
    test('collects every folded member id', () {
      final ha = _exp('Ha');
      final oiii = _exp('OIII');
      final delay = DelayNode(seconds: 5);
      final sequence = _sequenceOf([ha, oiii, delay]);
      final entries = _fold(sequence);
      expect(foldedMemberIds(entries), {ha.id, oiii.id});
    });
  });

  group('applyFoldsToVisibleOrder', () {
    test('drops hidden members and keeps depth', () {
      // The folded run sits at depth 2 inside a container; the first member
      // stands in for the group at its own depth.
      final container = InstructionSetNode(name: 'LRGB');
      final members = [_exp('L'), _exp('R'), _exp('G')];
      final tail = DelayNode(seconds: 5);
      final root = InstructionSetNode(name: 'Sequence');
      final nodes = <String, SequenceNode>{
        for (var i = 0; i < members.length; i++)
          members[i].id:
              members[i].copyWith(parentId: container.id, orderIndex: i),
        tail.id: tail.copyWith(parentId: container.id, orderIndex: 3),
        container.id: container.copyWith(
          parentId: root.id,
          orderIndex: 0,
          childIds: [...members.map((m) => m.id), tail.id],
        ),
        root.id: root.copyWith(childIds: [container.id]),
      };
      final sequence =
          Sequence.create(name: 'T', nodes: nodes, rootNodeId: root.id);

      final order = <VisibleNode>[
        (id: container.id, depth: 1),
        for (final m in members) (id: m.id, depth: 2),
        (id: tail.id, depth: 2),
      ];

      final folded = applyFoldsToVisibleOrder(order, sequence, const {});

      expect(folded, [
        (id: container.id, depth: 1),
        (id: members[0].id, depth: 2),
        (id: tail.id, depth: 2),
      ]);
    });

    test('an unfolded group keeps every member in the order', () {
      final members = [_exp('Ha'), _exp('OIII')];
      final sequence = _sequenceOf(members);
      final groupId = _foldedGroup(_fold(sequence)).id;
      final order = <VisibleNode>[
        for (final m in members) (id: m.id, depth: 1),
      ];

      final folded = applyFoldsToVisibleOrder(order, sequence, {groupId});
      expect(folded, order);
    });

    test('returns the order untouched when nothing folds', () {
      final sequence = _sequenceOf([_exp('Ha'), DelayNode(seconds: 5)]);
      final order = <VisibleNode>[
        for (final n in sequence.childrenOf(sequence.rootNodeId!))
          (id: n.id, depth: 1),
      ];
      expect(applyFoldsToVisibleOrder(order, sequence, const {}), order);
    });
  });

  group('unfoldedGroupIdsProvider', () {
    test('fold is the default; unfold/fold/toggle manage the exceptions', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // autoDispose needs a listener or the provider can be torn down between
      // reads; hold one open for the duration of the test.
      final sub = container.listen(unfoldedGroupIdsProvider, (_, __) {});
      addTearDown(sub.close);

      final notifier = container.read(unfoldedGroupIdsProvider.notifier);
      expect(container.read(unfoldedGroupIdsProvider), isEmpty);
      expect(notifier.isUnfolded('g1'), isFalse);

      notifier.unfold('g1');
      expect(notifier.isUnfolded('g1'), isTrue);
      // Idempotent: a second unfold changes nothing.
      notifier.unfold('g1');
      expect(container.read(unfoldedGroupIdsProvider), {'g1'});

      notifier.toggle('g1');
      expect(notifier.isUnfolded('g1'), isFalse);
      notifier.toggle('g1');
      notifier.fold('g1');
      expect(notifier.isUnfolded('g1'), isFalse);
      // Folding a group that is already folded is a no-op, not an error.
      notifier.fold('g1');
      expect(container.read(unfoldedGroupIdsProvider), isEmpty);
    });
  });
}

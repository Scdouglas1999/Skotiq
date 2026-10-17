import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

/// A sibling insert must not become a nested spine, or the run silently
/// captures nothing.
///
/// Every palette "+" reads `selectedNodeIdProvider` as the insertion parent and
/// then moves the selection to the node it just created. With no container
/// check in `addNode`, adding Unpark, then Slew to Target, then Take Exposures
/// under a Target stores `Target > Unpark > Slew > TakeExposure` on a single
/// spine while the builder draws them as a flat list. `Unpark` is a leaf, so the
/// executor runs it, returns Success and never descends — and the Session Report
/// reads "New Sequence - completed" with 0 frames, an empty `errorMessages` and
/// a header chip still saying "3 frames".

ProviderContainer _newContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

CurrentSequenceNotifier _notifier(ProviderContainer c) =>
    c.read(currentSequenceProvider.notifier);

/// Mirror of the palette's add handler (`_NodePaletteItem._addNode`): insert
/// under the current selection, then select the new node.
void _addFromPalette(ProviderContainer c, SequenceNode node) {
  final selectedId = c.read(selectedNodeIdProvider);
  _notifier(c).addNode(node, parentId: selectedId);
  c.read(selectedNodeIdProvider.notifier).state = node.id;
}

void main() {
  group('palette insertion', () {
    test('consecutive palette adds land as siblings, not a nested spine', () {
      final c = _newContainer();
      _notifier(c).createSequence();

      final target = TargetHeaderNode(
        id: 'target',
        name: 'Target',
        targetName: 'SPINE1',
        raHours: 23.4,
        decDegrees: 40.0,
        isEnabled: true,
      );
      _addFromPalette(c, target);
      _addFromPalette(c, ParkNode(id: 'unpark', name: 'Unpark Mount'));
      _addFromPalette(c, SlewNode(id: 'slew', name: 'Slew to Target'));
      _addFromPalette(c, ExposureNode(id: 'expose', name: 'Take Exposures'));

      final sequence = c.read(currentSequenceProvider)!;
      expect(
        sequence.nodes['target']!.childIds,
        ['unpark', 'slew', 'expose'],
        reason:
            'the flat list the builder draws must be the tree that is stored',
      );
      for (final id in ['unpark', 'slew', 'expose']) {
        expect(sequence.nodes[id]!.parentId, 'target');
        expect(
          sequence.nodes[id]!.childIds,
          isEmpty,
          reason: '$id is a leaf; anything under it can never execute',
        );
      }
    });

    test('a new instruction is inserted directly after the selected one', () {
      final c = _newContainer();
      _notifier(c).createSequence();

      final target = TargetHeaderNode(
        id: 'target',
        name: 'Target',
        targetName: 'SPINE1',
        raHours: 23.4,
        decDegrees: 40.0,
        isEnabled: true,
      );
      _addFromPalette(c, target);
      _addFromPalette(c, ParkNode(id: 'unpark', name: 'Unpark Mount'));
      _addFromPalette(c, ExposureNode(id: 'expose', name: 'Take Exposures'));

      // Re-select the middle step and add another: it belongs between them.
      c.read(selectedNodeIdProvider.notifier).state = 'unpark';
      _addFromPalette(c, SlewNode(id: 'slew', name: 'Slew to Target'));

      expect(c.read(currentSequenceProvider)!.nodes['target']!.childIds, [
        'unpark',
        'slew',
        'expose',
      ]);
    });

    test('adding under a container still nests inside it', () {
      final c = _newContainer();
      _notifier(c).createSequence();

      final target = TargetHeaderNode(
        id: 'target',
        name: 'Target',
        targetName: 'SPINE1',
        raHours: 23.4,
        decDegrees: 40.0,
        isEnabled: true,
      );
      _addFromPalette(c, target);
      _addFromPalette(c, LoopNode(id: 'loop', name: 'Loop'));
      _addFromPalette(c, ExposureNode(id: 'expose', name: 'Take Exposures'));

      final sequence = c.read(currentSequenceProvider)!;
      expect(sequence.nodes['loop']!.childIds, ['expose']);
      expect(sequence.nodes['expose']!.parentId, 'loop');
    });
  });
}

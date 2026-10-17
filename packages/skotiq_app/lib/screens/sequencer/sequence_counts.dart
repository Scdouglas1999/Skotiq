// The node count the USER can see.
//
// WHY THIS EXISTS: `Sequence.nodes` includes the implicit root container, a
// node nobody put there and nobody can select or delete. Surfaces that quoted
// `sequence.nodes.length` were therefore off by one against the tree they sat
// next to: a brand-new sequence read "1 node" in the header while the tree
// body under it read "Sequence / 0 steps", and Save as Template offered to
// save "1 nodes" from an empty sequence.

import 'package:skotiq_core/skotiq_core.dart';

/// Number of real instructions in [sequence] — every node except the
/// implicit root container.
///
/// Falls back to the raw map size when the sequence has no root node (an
/// unrooted/flat sequence has no invisible node to discount).
int visibleInstructionCount(Sequence sequence) {
  final rootId = sequence.rootNodeId;
  if (rootId == null || !sequence.nodes.containsKey(rootId)) {
    return sequence.nodes.length;
  }
  return sequence.nodes.length - 1;
}

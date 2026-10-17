// Derived tree-index sibling class for `Sequence`.
//
// The lookup maps live here, not on the model: freezed generates `==` /
// `hashCode` over every field, and derived indexes must not participate in
// sequence equality (see
// `equality_via_props_uses_nodes_map_and_excludes_derived_indexes`). The
// index is cached per `Sequence` instance via an [Expando], external to the
// data class, so repeated lookups against one instance still hit a single
// pre-built index and stay O(1) per hop on hot paths.
//
// `Sequence.childrenOf` / `parentOf` / `descendantsOf` / `invariants` /
// `countDescendants` delegate here and pick up the cache implicitly. Callers
// that want to share one index across several lookups without going through
// `Sequence` construct one via [SequenceTreeIndex.from].

import 'sequence_models.dart';

/// Derived tree-index over a [Sequence].
///
/// Built eagerly from `sequence.nodes` in [SequenceTreeIndex.from] — the
/// previous `late final` lazy semantic is preserved by the [Expando]-backed
/// cache on the [Sequence] side: the index is built once, at the first
/// `sequence.childrenOf(...)` (or similar) call, then reused for every
/// subsequent lookup against the same instance.
///
/// Two [SequenceTreeIndex] instances built from sequences with equal
/// `nodes` maps will produce identical lookup results, but the index
/// objects themselves are deliberately NOT comparable — they are pure
/// caches.
class SequenceTreeIndex {
  /// Maps `parentId -> ordered child IDs`. The key `null` collects orphan
  /// nodes (those whose `parentId == null`). The list ordering matches the
  /// canonical `parent.childIds` ordering; we do NOT depend on
  /// `node.orderIndex` for runtime traversal — that field is reserved for
  /// persistence/serialization round-trips.
  final Map<String?, List<String>> _childrenByParent;

  /// Maps `node_id -> parent_id` (with `null` for nodes whose `parentId` is
  /// null). Note: the root node has `parentId == null` and is therefore in
  /// this map with a `null` value, which is distinct from "node not found".
  final Map<String, String?> _parentById;

  /// Snapshot of `sequence.nodes` taken at build time. Held so the index
  /// can resolve IDs back to materialized [SequenceNode] instances without
  /// requiring the caller to thread the original [Sequence] through every
  /// call.
  final Map<String, SequenceNode> _nodes;

  SequenceTreeIndex._(this._childrenByParent, this._parentById, this._nodes);

  /// Build a fresh tree index from [seq]. Eager — runs both index passes
  /// up-front so subsequent lookups are O(1) / O(K). Equivalent to the
  /// previous `_buildChildrenIndex` + `_buildParentIndex` on `Sequence`.
  factory SequenceTreeIndex.from(Sequence seq) {
    final nodes = seq.nodes;

    final childrenByParent = <String?, List<String>>{};
    for (final entry in nodes.entries) {
      final node = entry.value;
      // Seed the parent's bucket from this node's `childIds`. We iterate
      // `nodes` rather than walking from a root because:
      //   * the editor occasionally constructs partially-detached nodes
      //     (e.g., during snippet inserts);
      //   * we want every node referenced by some parent.childIds to be
      //     resolvable without depending on which order keys appear in.
      // Reading `node.childIds` for the bucket keyed by `node.id` is the
      // authoritative source — `parent.childIds` is what the model has
      // always documented as canonical.
      childrenByParent
          .putIfAbsent(node.id, () => <String>[])
          .addAll(node.childIds);
    }
    // Ensure every node id has a (possibly empty) bucket so `childrenOf`
    // returns `const <String>[]` for leaves without a map-miss check.
    for (final id in nodes.keys) {
      childrenByParent.putIfAbsent(id, () => <String>[]);
    }

    final parentById = <String, String?>{};
    // Seed from each node's own `parentId` field. This is the authoritative
    // source — the editor maintains node.parentId on every structural
    // mutation, and the database load path reconstructs it.
    for (final entry in nodes.entries) {
      parentById[entry.key] = entry.value.parentId;
    }

    return SequenceTreeIndex._(childrenByParent, parentById, nodes);
  }

  /// Children of [parentId] in their canonical order. Returns the materialized
  /// `SequenceNode` instances (skipping any IDs that don't resolve — which is
  /// a corrupt-state condition the editor never produces but defensive code
  /// elsewhere does need to tolerate, e.g. mid-import).
  ///
  /// O(K) where K is the number of children of [parentId]. Does **not** sort
  /// by `orderIndex` — the `_childrenByParent` list is already in canonical
  /// order, matching `nodes[parentId].childIds`.
  List<SequenceNode> childrenOf(String parentId) {
    final ids = _childrenByParent[parentId];
    if (ids == null || ids.isEmpty) return const <SequenceNode>[];
    final out = <SequenceNode>[];
    for (final id in ids) {
      final n = _nodes[id];
      if (n != null) out.add(n);
    }
    return out;
  }

  /// Parent ID of [nodeId], or `null` if [nodeId] is a root node OR is not
  /// in this sequence. Use `nodes.containsKey` to distinguish those cases.
  ///
  /// O(1).
  String? parentOf(String nodeId) => _parentById[nodeId];

  /// IDs of all descendants of [nodeId] in DFS pre-order (children first, then
  /// grandchildren, ...). The node itself is NOT included.
  ///
  /// Cycles cannot exist if [invariants] holds, but we guard with a visited
  /// set anyway so a corrupted import doesn't loop forever.
  List<String> descendantsOf(String nodeId) {
    if (!_nodes.containsKey(nodeId)) return const <String>[];
    final out = <String>[];
    final visited = <String>{nodeId};
    void walk(String id) {
      final children = _childrenByParent[id];
      if (children == null) return;
      for (final childId in children) {
        if (!visited.add(childId)) continue;
        if (!_nodes.containsKey(childId)) continue;
        out.add(childId);
        walk(childId);
      }
    }

    walk(nodeId);
    return out;
  }

  /// Count of descendants of [nodeId]; equivalent to `descendantsOf(id).length`
  /// without materializing the intermediate list.
  int countDescendants(String nodeId) => descendantsOf(nodeId).length;

  /// Verify the structural invariants of the underlying sequence. Returns a
  /// list of human-readable violation messages; empty list means OK.
  ///
  /// Invariants checked:
  ///   1. Every ID in `_childrenByParent[X]` exists in `nodes`.
  ///   2. Every ID in `_childrenByParent[X]` has `_parentById[id] == X`.
  ///   3. Every node in `nodes` has a `_parentById` entry.
  ///   4. The graph is acyclic (no node is in its own ancestry).
  ///   5. `node.childIds` matches `_childrenByParent[node.id]` (the two
  ///      tree views agree).
  List<String> invariants() {
    final issues = <String>[];

    // (3) Every node has a parent entry.
    for (final id in _nodes.keys) {
      if (!_parentById.containsKey(id)) {
        issues.add('node "$id" missing from _parentById');
      }
    }

    // (1), (2), (5)
    for (final entry in _childrenByParent.entries) {
      final parent = entry.key;
      final list = entry.value;
      for (final childId in list) {
        if (!_nodes.containsKey(childId)) {
          // It's legal to have an entry in _childrenByParent for a parent
          // that's no longer in nodes (orphaned bucket) only if the bucket
          // is empty; non-empty buckets pointing at missing nodes are bad.
          issues.add(
            'child "$childId" of parent "$parent" not present in nodes',
          );
          continue;
        }
        final parentOfChild = _parentById[childId];
        if (parentOfChild != parent) {
          issues.add(
            'child "$childId" of "$parent" has parentId=$parentOfChild',
          );
        }
      }
      // (5) cross-check childIds.
      if (parent != null) {
        final parentNode = _nodes[parent];
        if (parentNode != null) {
          final declared = parentNode.childIds;
          if (declared.length != list.length) {
            issues.add(
              'parent "$parent" childIds length ${declared.length} != index ${list.length}',
            );
          } else {
            for (var i = 0; i < declared.length; i++) {
              if (declared[i] != list[i]) {
                issues.add(
                  'parent "$parent" childIds[$i]=${declared[i]} != index[$i]=${list[i]}',
                );
                break;
              }
            }
          }
        }
      }
    }

    // (4) No cycles. Walk every node's ancestry; bail when we find a
    // revisit. We bound the walk length to nodes.length so a true cycle
    // can't run forever.
    for (final id in _nodes.keys) {
      var hops = 0;
      var cursor = _parentById[id];
      final seen = <String>{id};
      while (cursor != null) {
        if (!seen.add(cursor)) {
          issues.add('cycle detected at "$id" via ancestor "$cursor"');
          break;
        }
        if (++hops > _nodes.length) {
          issues.add('ancestry walk for "$id" exceeded node count');
          break;
        }
        cursor = _parentById[cursor];
      }
    }

    return issues;
  }
}

/// Per-instance cache so repeated `childrenOf` / `parentOf` / etc. against
/// the same [Sequence] reuse the eagerly-built index instead of rebuilding
/// it on every call.
///
/// Lives at top level so it stays outside the [Sequence] data class — that
/// is the whole point of the hoist: freezed-generated equality / hashCode
/// must NOT see the index. An [Expando] keys by instance identity (not
/// value equality), which matches the previous `late final` semantic
/// exactly: a fresh `Sequence` built from the same `nodes` map starts with
/// an empty cache and re-derives the index on first access.
final Expando<SequenceTreeIndex> sequenceTreeIndexCache =
    Expando<SequenceTreeIndex>('SequenceTreeIndex');

/// Internal helper used by [Sequence] to fetch (and lazily build) its
/// cached index. Public so the [Sequence] class in the sibling library file
/// can reach it; callers outside the model layer should go through
/// `sequence.childrenOf(...)` instead.
SequenceTreeIndex sequenceTreeIndexFor(Sequence seq) {
  final cached = sequenceTreeIndexCache[seq];
  if (cached != null) return cached;
  final built = SequenceTreeIndex.from(seq);
  sequenceTreeIndexCache[seq] = built;
  return built;
}

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../tables/sequences.dart';
import '../tables/targets.dart';

part 'sequences_dao.g.dart';

/// Lightweight per-sequence roll-up produced by
/// [SequencesDao.getSequenceSummaryRows] without hydrating any node tree.
///
/// `nodeType` / `specificType` mirror the persisted `sequence_nodes` columns:
/// `nodeType == 'target'` counts a target-category node, and the exposure
/// count sums nodes whose `specificType` is one of the capture node types.
class SequenceSummaryRow {
  final int id;
  final String name;
  final int estimatedDurationMins;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String tagsJson;
  final bool isFavorite;
  final int nodeCount;
  final int targetCount;
  final int exposureCount;
  final String? primaryTargetName;

  const SequenceSummaryRow({
    required this.id,
    required this.name,
    required this.estimatedDurationMins,
    required this.createdAt,
    required this.updatedAt,
    required this.tagsJson,
    required this.isFavorite,
    required this.nodeCount,
    required this.targetCount,
    required this.exposureCount,
    required this.primaryTargetName,
  });
}

@DriftAccessor(tables: [Sequences, SequenceNodes, Targets])
class SequencesDao extends DatabaseAccessor<SkotiqDatabase>
    with _$SequencesDaoMixin {
  SequencesDao(super.db);

  /// Wire string written into `sequence_nodes.node_type` for target-category
  /// nodes (see `SequenceRepository._categoryWireString`). Matched here to
  /// count targets without loading node properties.
  static const String _targetCategoryWire = 'target';

  /// `sequence_nodes.specific_type` values that represent a capture/exposure
  /// node. Kept in sync with the model node types `TakeExposure` /
  /// `SmartExposure` so the library summary's exposure count never hydrates
  /// node trees.
  static const Set<String> _exposureSpecificTypes = {
    'TakeExposure',
    'SmartExposure',
  };

  /// Get all sequences
  Future<List<Sequence>> getAllSequences() {
    return (select(sequences)
          ..where((s) => s.isTemplate.equals(false))
          ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]))
        .get();
  }

  /// Watch all sequences
  Stream<List<Sequence>> watchAllSequences() {
    return (select(sequences)
          ..where((s) => s.isTemplate.equals(false))
          ..orderBy([(s) => OrderingTerm.desc(s.updatedAt)]))
        .watch();
  }

  /// Get all templates
  Future<List<Sequence>> getAllTemplates() {
    return (select(sequences)
          ..where((s) => s.isTemplate.equals(true))
          ..orderBy([(s) => OrderingTerm.asc(s.name)]))
        .get();
  }

  /// Watch all templates
  Stream<List<Sequence>> watchAllTemplates() {
    return (select(sequences)
          ..where((s) => s.isTemplate.equals(true))
          ..orderBy([(s) => OrderingTerm.asc(s.name)]))
        .watch();
  }

  /// Get sequence by ID
  Future<Sequence?> getSequenceById(int id) {
    return (select(sequences)..where((s) => s.id.equals(id))).getSingleOrNull();
  }

  /// Create a new sequence
  Future<int> createSequence(SequencesCompanion sequence) {
    return into(sequences).insert(sequence);
  }

  /// Update a sequence
  Future<bool> updateSequence(Sequence sequence) {
    return update(sequences).replace(sequence);
  }

  /// Set the JSON-encoded tag list for [sequenceId] and bump `updatedAt`.
  ///
  /// [tagsJson] must be a JSON-encoded `List<String>` (the repository encodes
  /// it). Touching `updatedAt` keeps the library's "recently modified" sort
  /// honest — re-tagging a sequence is a meaningful library edit.
  Future<void> setTagsJson(int sequenceId, String tagsJson) {
    return (update(sequences)..where((s) => s.id.equals(sequenceId))).write(
      SequencesCompanion(
        tagsJson: Value(tagsJson),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Set the favorite flag for [sequenceId].
  ///
  /// Favoriting is a library-organisation flag, not a content edit, so it
  /// deliberately does NOT touch `updatedAt` — starring a sequence should not
  /// reorder a "recently modified" list.
  Future<void> setFavorite(int sequenceId, bool isFavorite) {
    return (update(sequences)..where((s) => s.id.equals(sequenceId))).write(
      SequencesCompanion(isFavorite: Value(isFavorite)),
    );
  }

  /// One grouped query that returns a lightweight roll-up for every
  /// non-template sequence — the counts the library list needs WITHOUT
  /// hydrating each sequence's full node tree (the N+1 that
  /// `loadAllSequences` incurs).
  ///
  /// A single left join + group-by yields `nodeCount`, `targetCount`, and
  /// `exposureCount` per sequence; the primary target name is resolved in one
  /// extra batched query rather than per sequence. Newest-modified first, to
  /// match [getAllSequences].
  Future<List<SequenceSummaryRow>> getSequenceSummaryRows() async {
    final nodeCountExpr = sequenceNodes.id.count();
    final targetCountExpr = sequenceNodes.id.count(
      filter: sequenceNodes.nodeType.equals(_targetCategoryWire),
    );
    final exposureCountExpr = sequenceNodes.id.count(
      filter: sequenceNodes.specificType.isIn(_exposureSpecificTypes.toList()),
    );

    final query =
        select(sequences).join([
            leftOuterJoin(
              sequenceNodes,
              sequenceNodes.sequenceId.equalsExp(sequences.id),
            ),
          ])
          ..addColumns([nodeCountExpr, targetCountExpr, exposureCountExpr])
          ..where(sequences.isTemplate.equals(false))
          ..groupBy([sequences.id])
          ..orderBy([OrderingTerm.desc(sequences.updatedAt)]);

    final rows = await query.get();

    final primaryNames = await _primaryTargetNames(
      rows.map((r) => r.readTable(sequences).id).toList(),
    );

    return [
      for (final row in rows)
        () {
          final seq = row.readTable(sequences);
          return SequenceSummaryRow(
            id: seq.id,
            name: seq.name,
            estimatedDurationMins: seq.estimatedDurationMins,
            createdAt: seq.createdAt,
            updatedAt: seq.updatedAt,
            tagsJson: seq.tagsJson,
            isFavorite: seq.isFavorite,
            nodeCount: row.read(nodeCountExpr) ?? 0,
            targetCount: row.read(targetCountExpr) ?? 0,
            exposureCount: row.read(exposureCountExpr) ?? 0,
            primaryTargetName: primaryNames[seq.id],
          );
        }(),
    ];
  }

  /// The display name of the first (lowest `order_index`, ties broken by row
  /// id) target-category node for each sequence in [sequenceIds]. One query
  /// over the whole set rather than one per sequence. Sequences with no target
  /// node are simply absent from the returned map.
  Future<Map<int, String>> _primaryTargetNames(List<int> sequenceIds) async {
    if (sequenceIds.isEmpty) return const {};
    final rows =
        await (select(sequenceNodes)
              ..where(
                (n) =>
                    n.sequenceId.isIn(sequenceIds) &
                    n.nodeType.equals(_targetCategoryWire),
              )
              ..orderBy([
                (n) => OrderingTerm.asc(n.orderIndex),
                (n) => OrderingTerm.asc(n.id),
              ]))
            .get();
    final out = <int, String>{};
    for (final node in rows) {
      // First row wins per sequence thanks to the ordering above.
      out.putIfAbsent(node.sequenceId, () => _targetNameOf(node));
    }
    return out;
  }

  /// The human target name for a target-category node row. Prefers the
  /// `targetName` stored in the node's properties JSON (what the catalog/target
  /// actually is) and falls back to the node's display `name` when the
  /// properties are absent or unparseable.
  String _targetNameOf(SequenceNode node) {
    try {
      final decoded = jsonDecode(node.properties);
      if (decoded is Map) {
        final raw = decoded['targetName'];
        if (raw is String && raw.trim().isNotEmpty) return raw;
      }
    } on FormatException {
      // Fall through to the display name below.
    }
    return node.name;
  }

  /// Delete a sequence and its nodes
  Future<void> deleteSequence(int id) async {
    await transaction(() async {
      // Delete all nodes
      await (delete(sequenceNodes)..where((n) => n.sequenceId.equals(id))).go();
      // Delete the sequence
      await (delete(sequences)..where((s) => s.id.equals(id))).go();
    });
  }

  /// Duplicate a sequence
  ///
  /// Generates fresh UUIDs for all duplicated nodes and remaps parent-child
  /// references (parentNodeId) and the sequence's rootNodeId to the new IDs.
  Future<int> duplicateSequence(int sourceId, String newName) async {
    final source = await getSequenceById(sourceId);
    if (source == null) {
      throw Exception('Sequence not found');
    }

    final sourceNodes = await getNodesForSequence(sourceId);
    const uuid = Uuid();

    // Build mapping from old nodeId → new nodeId
    final idMapping = <String, String>{};
    for (final node in sourceNodes) {
      idMapping[node.nodeId] = uuid.v4();
    }

    // Remap rootNodeId
    final newRootNodeId = source.rootNodeId != null
        ? idMapping[source.rootNodeId!] ?? source.rootNodeId
        : null;

    return transaction(() async {
      // Create new sequence with remapped root
      final newId = await into(sequences).insert(
        SequencesCompanion.insert(
          name: newName,
          description: Value(source.description),
          rootNodeId: Value(newRootNodeId),
          isTemplate: Value(source.isTemplate),
        ),
      );

      // Copy all nodes with new UUIDs and remapped parent references
      for (final node in sourceNodes) {
        final newNodeId = idMapping[node.nodeId]!;
        final newParentNodeId = node.parentNodeId != null
            ? idMapping[node.parentNodeId!] ?? node.parentNodeId
            : null;

        await into(sequenceNodes).insert(
          SequenceNodesCompanion.insert(
            nodeId: newNodeId,
            sequenceId: newId,
            targetId: Value(node.targetId),
            nodeType: node.nodeType,
            specificType: node.specificType,
            name: node.name,
            properties: Value(node.properties),
            recoveryConfig: Value(node.recoveryConfig),
            parentNodeId: Value(newParentNodeId),
            orderIndex: Value(node.orderIndex),
            isEnabled: Value(node.isEnabled),
          ),
        );
      }

      return newId;
    });
  }

  // Node operations

  /// Get all nodes for a sequence
  Future<List<SequenceNode>> getNodesForSequence(int sequenceId) {
    return (select(sequenceNodes)
          ..where((n) => n.sequenceId.equals(sequenceId))
          ..orderBy([(n) => OrderingTerm.asc(n.orderIndex)]))
        .get();
  }

  /// Watch nodes for a sequence
  Stream<List<SequenceNode>> watchNodesForSequence(int sequenceId) {
    return (select(sequenceNodes)
          ..where((n) => n.sequenceId.equals(sequenceId))
          ..orderBy([(n) => OrderingTerm.asc(n.orderIndex)]))
        .watch();
  }

  /// Get node by ID
  Future<SequenceNode?> getNodeById(int id) {
    return (select(
      sequenceNodes,
    )..where((n) => n.id.equals(id))).getSingleOrNull();
  }

  /// Get node by UUID
  Future<SequenceNode?> getNodeByUuid(String nodeId) {
    return (select(
      sequenceNodes,
    )..where((n) => n.nodeId.equals(nodeId))).getSingleOrNull();
  }

  /// Create a new node
  Future<int> createNode(SequenceNodesCompanion node) {
    return into(sequenceNodes).insert(node);
  }

  /// Update a node
  Future<bool> updateNode(SequenceNode node) {
    return update(sequenceNodes).replace(node);
  }

  /// Delete a node
  Future<int> deleteNode(int id) {
    return (delete(sequenceNodes)..where((n) => n.id.equals(id))).go();
  }

  /// Enable/disable a node
  Future<void> setNodeEnabled(int id, bool enabled) {
    return (update(sequenceNodes)..where((n) => n.id.equals(id))).write(
      SequenceNodesCompanion(isEnabled: Value(enabled)),
    );
  }

  /// Reorder nodes
  Future<void> reorderNodes(int sequenceId, List<String> nodeIds) async {
    await batch((batch) {
      for (var i = 0; i < nodeIds.length; i++) {
        batch.update(
          sequenceNodes,
          SequenceNodesCompanion(orderIndex: Value(i)),
          where: (n) =>
              n.nodeId.equals(nodeIds[i]) & n.sequenceId.equals(sequenceId),
        );
      }
    });
  }

  /// Get children of a node
  Future<List<SequenceNode>> getChildNodes(
    int sequenceId,
    String parentNodeId,
  ) {
    return (select(sequenceNodes)
          ..where(
            (n) =>
                n.sequenceId.equals(sequenceId) &
                n.parentNodeId.equals(parentNodeId),
          )
          ..orderBy([(n) => OrderingTerm.asc(n.orderIndex)]))
        .get();
  }
}

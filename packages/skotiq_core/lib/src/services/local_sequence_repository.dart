import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../database/database.dart' as db;
import '../database/daos/sequence_runs_dao.dart';
import '../database/daos/sequence_versions_dao.dart';
import '../database/daos/sequences_dao.dart';
import 'sequence_rollup.dart' show sequenceRollupSecs;
import '../models/sequence/sequence_models.dart';
import '../utils/json_validation.dart';
import 'sequence_file_service.dart';
import 'sequence_repository.dart';


/// The saved sequences in this process's own database.
final class LocalSequenceRepository implements SequenceRepository {
  /// [runsDao], [versionsDao] and [fileService] are needed only by the run
  /// diff and the version history, which throw a [StateError] without them;
  /// the provider passes all four.
  LocalSequenceRepository(
    SequencesDao dao, {
    SequenceRunsDao? runsDao,
    SequenceVersionsDao? versionsDao,
    SequenceFileService? fileService,
  }) : _dao = dao,
       _runsDao = runsDao,
       _versionsDao = versionsDao,
       _fileService = fileService;

  final SequencesDao _dao;
  final SequenceRunsDao? _runsDao;
  final SequenceVersionsDao? _versionsDao;
  final SequenceFileService? _fileService;

  SequenceFileService _requireFileService(String feature) {
    final service = _fileService;
    if (service == null) {
      throw StateError(
        'LocalSequenceRepository.$feature requires a SequenceFileService. '
        'Construct the repository through sequenceRepositoryProvider, which '
        'wires it, rather than LocalSequenceRepository(dao) alone.',
      );
    }
    return service;
  }

  SequenceRunsDao _requireRunsDao(String feature) {
    final dao = _runsDao;
    if (dao == null) {
      throw StateError(
        'LocalSequenceRepository.$feature requires a SequenceRunsDao. '
        'Construct the repository through sequenceRepositoryProvider, which '
        'wires it, rather than LocalSequenceRepository(dao) alone.',
      );
    }
    return dao;
  }

  SequenceVersionsDao _requireVersionsDao(String feature) {
    final dao = _versionsDao;
    if (dao == null) {
      throw StateError(
        'LocalSequenceRepository.$feature requires a SequenceVersionsDao. '
        'Construct the repository through sequenceRepositoryProvider, which '
        'wires it, rather than LocalSequenceRepository(dao) alone.',
      );
    }
    return dao;
  }

  @override
  Future<int> saveSequence(Sequence sequence, {bool isTemplate = false}) async {
    // Check if this sequence already exists in database
    final existingId = sequence.databaseId;

    if (existingId != null) {
      await _updateSequence(existingId, sequence, isTemplate);
      return existingId;
    } else {
      return await _createSequence(sequence, isTemplate);
    }
  }

  Future<int> _createSequence(Sequence sequence, bool isTemplate) async {
    final dao = _dao;
    final sequenceId = await dao.createSequence(
      db.SequencesCompanion.insert(
        name: sequence.name,
        description: Value(sequence.description),
        rootNodeId: Value(sequence.rootNodeId),
        estimatedDurationMins: Value(_estimatedMinutes(sequence)),
        isTemplate: Value(isTemplate),
      ),
    );

    await _saveNodes(sequenceId, sequence.nodes);

    return sequenceId;
  }

  /// Apply an edited [sequence] over its persisted rows.
  ///
  /// The metadata update and the whole node diff run as ONE transaction, and
  /// the diff itself as one batch. Applying it statement-by-statement meant a
  /// failure (or an app kill) part-way through a 200-node save left the library
  /// row updated and the node set half-migrated — some nodes updated, some
  /// inserted, some of the to-delete set still present — and the next load
  /// rebuilt a corrupted tree from whatever survived, with no recovery path.
  Future<void> _updateSequence(
    int sequenceId,
    Sequence sequence,
    bool isTemplate,
  ) async {
    final dao = _dao;
    final existing = await dao.getSequenceById(sequenceId);
    if (existing == null) {
      throw Exception('Sequence $sequenceId not found');
    }

    final existingNodes = await dao.getNodesForSequence(sequenceId);
    final existingNodeMap = {for (final n in existingNodes) n.nodeId: n};

    // Update in place where the node survives (preserves database row IDs),
    // insert what is new, delete what the edit dropped.
    final updates = <db.DbSequenceNode>[];
    final deletedRowIds = <int>[];
    for (final dbNode in existingNodes) {
      final node = sequence.nodes[dbNode.nodeId];
      if (node == null) {
        deletedRowIds.add(dbNode.id);
      } else {
        updates.add(_nodeUpdateRow(sequenceId, node, dbNode));
      }
    }
    final inserts = [
      for (final node in sequence.nodes.values)
        if (!existingNodeMap.containsKey(node.id))
          _nodeInsertCompanion(sequenceId, node),
    ];

    await dao.transaction(() async {
      await dao.updateSequence(
        db.DbSequence(
          id: sequenceId,
          name: sequence.name,
          description: sequence.description,
          rootNodeId: sequence.rootNodeId,
          estimatedDurationMins: _estimatedMinutes(sequence),
          createdAt: existing.createdAt,
          updatedAt: DateTime.now(),
          isTemplate: isTemplate,
          tagsJson: existing.tagsJson,
          isFavorite: existing.isFavorite,
        ),
      );
      await dao.batch((batch) {
        for (final node in updates) {
          batch.replace(dao.sequenceNodes, node);
        }
        batch.insertAll(dao.sequenceNodes, inserts);
        if (deletedRowIds.isNotEmpty) {
          batch.deleteWhere(dao.sequenceNodes, (n) => n.id.isIn(deletedRowIds));
        }
      });
    });
  }

  Future<void> _saveNodes(
    int sequenceId,
    Map<String, SequenceNode> nodes,
  ) async {
    final dao = _dao;
    await dao.batch((batch) {
      batch.insertAll(dao.sequenceNodes, [
        for (final node in nodes.values) _nodeInsertCompanion(sequenceId, node),
      ]);
    });
  }

  /// The persisted row for a node that already exists, carrying the database
  /// row id (and the target link, which lives only on the row) forward.
  db.DbSequenceNode _nodeUpdateRow(
    int sequenceId,
    SequenceNode node,
    db.DbSequenceNode existing,
  ) => db.DbSequenceNode(
    id: existing.id,
    nodeId: node.id,
    sequenceId: sequenceId,
    targetId: existing.targetId,
    nodeType: _getNodeCategory(node),
    specificType: node.nodeType,
    name: node.name,
    properties: jsonEncode(_nodeToPropertiesWithComment(node)),
    // `recoveryConfig` is a legacy persistence field that is no longer
    // surfaced in the runtime model. Clearing it on save prevents stale
    // node-id references from surviving deletes and subsequent edits.
    recoveryConfig: null,
    parentNodeId: node.parentId,
    orderIndex: node.orderIndex,
    isEnabled: node.isEnabled,
  );

  db.SequenceNodesCompanion _nodeInsertCompanion(
    int sequenceId,
    SequenceNode node,
  ) => db.SequenceNodesCompanion.insert(
    nodeId: node.id,
    sequenceId: sequenceId,
    nodeType: _getNodeCategory(node),
    specificType: node.nodeType,
    name: node.name,
    properties: Value(jsonEncode(_nodeToPropertiesWithComment(node))),
    parentNodeId: Value(node.parentId),
    orderIndex: Value(node.orderIndex),
    isEnabled: Value(node.isEnabled),
  );

  /// Serialize a node's coarse category for the persisted
  /// `sequence_nodes.node_type` column.
  ///
  /// Single source of truth: delegates to the model's `node.category` getter
  /// and maps the [NodeCategory] enum to its wire string. Hand-classifying
  /// subtypes here lets the persisted value drift from `node.category`;
  /// deriving it makes that divergence impossible.
  String _getNodeCategory(SequenceNode node) =>
      _categoryWireString(node.category);

  /// Map a [NodeCategory] to the string persisted in
  /// `sequence_nodes.node_type`. Exhaustive over the enum so a future
  /// category produces a compile-time error rather than a silent
  /// mis-bucket.
  static String _categoryWireString(NodeCategory category) {
    return switch (category) {
      NodeCategory.instruction => 'instruction',
      NodeCategory.trigger => 'trigger',
      NodeCategory.logic => 'logic',
      NodeCategory.target => 'target',
    };
  }

  @override
  Future<Sequence?> loadSequence(int sequenceId) async {
    final dbSequence = await _dao.getSequenceById(sequenceId);
    if (dbSequence == null) return null;

    final dbNodes = await _dao.getNodesForSequence(sequenceId);

    final nodes = <String, SequenceNode>{};
    for (final dbNode in dbNodes) {
      final node = _dbNodeToModel(dbNode);
      if (node == null) {
        throw StateError(
          'Unsupported sequence node type '
          '"${dbNode.specificType}" for node ${dbNode.nodeId}',
        );
      }
      nodes[node.id] = node;
    }

    for (final dbNode in dbNodes) {
      if (dbNode.parentNodeId != null &&
          nodes.containsKey(dbNode.parentNodeId)) {
        final parent = nodes[dbNode.parentNodeId!]!;
        final childIds = [...parent.childIds, dbNode.nodeId];
        nodes[dbNode.parentNodeId!] = parent.copyWith(childIds: childIds);
      }
    }

    return Sequence(
      id: dbSequence.id.toString(),
      databaseId: dbSequence.id,
      name: dbSequence.name,
      description: dbSequence.description ?? '',
      nodes: nodes,
      rootNodeId: dbSequence.rootNodeId,
      isTemplate: dbSequence.isTemplate,
      createdAt: dbSequence.createdAt,
      modifiedAt: dbSequence.updatedAt,
    );
  }

  @override
  Future<List<Sequence>> loadAllSequences() async {
    final dbSequences = await _dao.getAllSequences();
    final sequences = <Sequence>[];

    for (final dbSequence in dbSequences) {
      final sequence = await loadSequence(dbSequence.id);
      if (sequence != null) {
        sequences.add(sequence);
      }
    }

    return sequences;
  }

  @override
  Future<List<Sequence>> loadAllTemplates() async {
    final dbTemplates = await _dao.getAllTemplates();
    final templates = <Sequence>[];

    for (final dbTemplate in dbTemplates) {
      final template = await loadSequence(dbTemplate.id);
      if (template != null) {
        templates.add(template);
      }
    }

    return templates;
  }

  /// Load lightweight summaries for every saved (non-template) sequence.
  ///
  /// Two grouped DAO queries — the summary rows, then one run-history roll-up
  /// covering every id on the page — so the library list renders without
  /// hydrating any node tree (the N+1 that [loadAllSequences] incurs, one full
  /// load per row) and without a round trip per card. Newest-modified first.
  ///
  /// Remote repositories use the host's dedicated summary endpoint so tags,
  /// favorites and run roll-ups stay authoritative without transferring every
  /// full node tree.
  @override
  Future<List<SequenceSummary>> loadSequenceSummaries() async {
    final rows = await _dao.getSequenceSummaryRows();
    final runsDao = _runsDao;
    final rollups = runsDao == null
        ? const <int, ({int runCount, DateTime? lastRunAt})>{}
        : await runsDao.runSummariesForSequences(rows.map((r) => r.id));
    return [
      for (final row in rows)
        SequenceSummary(
          id: row.id,
          name: row.name,
          nodeCount: row.nodeCount,
          targetCount: row.targetCount,
          exposureCount: row.exposureCount,
          totalIntegrationSecs: row.estimatedDurationMins * 60,
          primaryTargetName: row.primaryTargetName,
          lastRunAt: rollups[row.id]?.lastRunAt,
          runCount: rollups[row.id]?.runCount ?? 0,
          tags: SequenceSummary.decodeTags(row.tagsJson),
          isFavorite: row.isFavorite,
          createdAt: row.createdAt,
          modifiedAt: row.updatedAt,
        ),
    ];
  }

  /// The sequence JSON of the most recent COMPLETED run of [sequenceId] that
  /// started strictly before [beforeRunId]'s run.
  ///
  /// Used by the run-history "diff vs previous run" view: pass the run the user
  /// is inspecting as [beforeRunId] and this returns the snapshot of the run
  /// immediately before it, so the diff compares the two sequences that
  /// actually executed. Returns `null` when there is no earlier completed run,
  /// when the earlier run predates the snapshot column, or when [beforeRunId]
  /// is unknown. Remote repositories ask the host for this context; they never
  /// consult the controller's unrelated local run database.
  @override
  Future<String?> loadPreviousRunSnapshot(
    int sequenceId, {
    required int beforeRunId,
  }) async {
    final runsDao = _requireRunsDao('loadPreviousRunSnapshot');
    final before = await runsDao.getRunById(beforeRunId);
    if (before == null || before.sequenceId != sequenceId) return null;
    return runsDao.previousCompletedRunSnapshot(
      sequenceId,
      before: before.startedAt,
    );
  }

  /// Load the exact current and prior-completed snapshots for [runId].
  ///
  /// The combined call matters for remote clients: it keeps the two sides
  /// host-authoritative and avoids silently comparing an old run to the
  /// sequence's current, since-edited definition.
  @override
  Future<SequenceRunDiffContext> loadRunDiffContext(int runId) async {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
    final runsDao = _requireRunsDao('loadRunDiffContext');
    final run = await runsDao.getRunById(runId);
    if (run == null) {
      throw StateError('Sequence run $runId no longer exists.');
    }
    final sequenceId = run.sequenceId;
    final previousSnapshot = sequenceId == null
        ? null
        : await runsDao.previousCompletedRunSnapshot(
            sequenceId,
            before: run.startedAt,
          );
    return SequenceRunDiffContext(
      sequenceId: sequenceId,
      currentSnapshotJson: _nonEmptyRunSnapshot(run.sequenceSnapshotJson),
      previousSnapshotJson: _nonEmptyRunSnapshot(previousSnapshot),
    );
  }

  String? _nonEmptyRunSnapshot(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  /// Set the library tags for [sequenceId]. Replaces the full tag list.
  @override
  Future<void> setTags(int sequenceId, List<String> tags) async {
    final cleaned = cleanedSequenceTags(tags);
    await _dao.setTagsJson(sequenceId, jsonEncode(cleaned));
  }

  /// Toggle the favorite flag for [sequenceId]; returns the new value.
  @override
  Future<bool> toggleFavorite(int sequenceId) async {
    final dao = _dao;
    final existing = await dao.getSequenceById(sequenceId);
    if (existing == null) {
      throw Exception('Sequence $sequenceId not found');
    }
    final next = !existing.isFavorite;
    await dao.setFavorite(sequenceId, next);
    return next;
  }

  /// Capture a point-in-time version snapshot of [sequence] in its version
  /// history. No-op (returns `null`) for an unsaved sequence (no `databaseId`)
  /// since version history is keyed by the persisted row.
  ///
  /// Call this on a meaningful save so the user can later review and restore an
  /// earlier shape of the sequence. Returns the new version row id, or `null`
  /// when the sequence has no `databaseId`. History is capped per sequence by
  /// the DAO ([SequenceVersionsDao.maxVersionsPerSequence]).
  @override
  Future<int?> snapshotVersionOnSave(Sequence sequence, {String? label}) async {
    final sequenceId = sequence.databaseId;
    if (sequenceId == null) return null;
    final fileService = _requireFileService('snapshotVersionOnSave');
    final versionsDao = _requireVersionsDao('snapshotVersionOnSave');
    final snapshotJson = jsonEncode(fileService.sequenceToMap(sequence));
    return versionsDao.appendVersion(
      sequenceId: sequenceId,
      snapshotJson: snapshotJson,
      label: label,
    );
  }

  /// List the version history of [sequenceId], newest first.
  @override
  Future<List<SequenceVersionSummary>> listVersions(int sequenceId) async {
    final versions = await _requireVersionsDao(
      'listVersions',
    ).listVersions(sequenceId);
    return [
      for (final version in versions)
        SequenceVersionSummary(
          id: version.id,
          sequenceId: version.sequenceId,
          label: version.label,
          createdAt: version.createdAt,
        ),
    ];
  }

  /// Rebuild an editable [Sequence] from the stored version with row id
  /// [versionId]. Returns `null` when that version no longer exists.
  ///
  /// The returned sequence keeps the version's owning `databaseId` so a
  /// subsequent save updates the same library row (restoring in place rather
  /// than forking a copy). The caller (editor) loads it into the editor and
  /// saves to persist the restore.
  @override
  Future<Sequence?> restoreVersion(int versionId) async {
    final fileService = _requireFileService('restoreVersion');
    final version = await _requireVersionsDao(
      'restoreVersion',
    ).loadVersion(versionId);
    if (version == null) return null;
    return sequenceFromVersionSnapshot(
      fileService,
      versionId: versionId,
      sequenceId: version.sequenceId,
      snapshotJson: version.snapshotJson,
    );
  }

  @override
  Future<void> deleteSequence(int sequenceId) async {
    await _dao.deleteSequence(sequenceId);
  }

  /// Duplicate a sequence with fresh UUIDs for all nodes.
  ///
  /// Generates new UUIDs for every node and remaps all parent/child references
  /// so the duplicated sequence is fully independent from the original.
  @override
  Future<Sequence?> duplicateSequence(int sequenceId, String newName) async {
    final source = await loadSequence(sequenceId);
    if (source == null) {
      throw Exception('Sequence $sequenceId not found');
    }

    const uuid = Uuid();

    final idMapping = <String, String>{};
    for (final oldId in source.nodes.keys) {
      idMapping[oldId] = uuid.v4();
    }

    final newRootNodeId = source.rootNodeId != null
        ? idMapping[source.rootNodeId] ?? source.rootNodeId
        : null;

    final newNodes = <String, SequenceNode>{};
    for (final entry in source.nodes.entries) {
      final oldNode = entry.value;
      final newId = idMapping[entry.key]!;
      final newParentId = oldNode.parentId != null
          ? idMapping[oldNode.parentId] ?? oldNode.parentId
          : null;
      final newChildIds = oldNode.childIds
          .map((childId) => idMapping[childId] ?? childId)
          .toList();

      final remappedNode = oldNode.copyWith(
        id: newId,
        parentId: newParentId,
        childIds: newChildIds,
      );
      newNodes[newId] = remappedNode;
    }

    final duplicated = Sequence(
      id: uuid.v4(),
      name: newName,
      description: source.description,
      nodes: newNodes,
      rootNodeId: newRootNodeId,
      isTemplate: source.isTemplate,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
    );

    final newDbId = await _createSequence(duplicated, source.isTemplate);
    return loadSequence(newDbId);
  }

  /// The persisted `sequence_nodes.properties` blob of [node]: its fields,
  /// plus its comment when it has one.
  Map<String, dynamic> _nodeToPropertiesWithComment(SequenceNode node) => {
    ...node.kind.encodeFields(node, NodeStore.database),
    if (node.comment != null && node.comment!.isNotEmpty)
      'comment': node.comment,
  };

  SequenceNode? _dbNodeToModel(db.DbSequenceNode dbNode) {
    final kind = NodeKind.forDatabaseName(dbNode.specificType);
    if (kind == null) return null;
    final props = decodeJsonObjectString(
      dbNode.properties,
      context:
          'sequence_nodes.properties for node ${dbNode.nodeId} (${dbNode.specificType})',
    );
    return kind
        .decodeFields(props, NodeStore.database)
        .copyWith(
          id: dbNode.nodeId,
          name: dbNode.name,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );
  }
}

/// The saved plan's length for the library card: the Builder's own estimate,
/// so the card and the Builder show the same figure for the same plan.
int _estimatedMinutes(Sequence sequence) =>
    (sequenceRollupSecs(sequence) / 60).ceil();

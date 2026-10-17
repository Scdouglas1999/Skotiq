import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../backend/network_backend.dart';
import '../database/database.dart' as db;
import '../database/daos/sequence_runs_dao.dart';
import '../database/daos/sequence_versions_dao.dart';
import '../database/daos/sequences_dao.dart';
import '../models/imaging/imaging_models.dart' show FrameType;
import '../models/notification/notification_categories.dart'
    show NotificationTransportKind;
import '../models/sequence/sequence_models.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
import '../providers/sequence_stats_provider.dart'
    show sequenceRunsDaoProvider, sequenceVersionsDaoProvider;
import '../utils/json_validation.dart';
import 'scheduler/horizon_profile.dart';
import 'sequence_file_service.dart';
import 'sequence_wire_codec.dart';
import 'sequence_summary.dart';

export 'sequence_summary.dart';

part 'sequence_repository/node_decoder.dart';
part 'sequence_repository/node_encoder.dart';

/// Exact persisted sequence documents surrounding a recorded run.
///
/// Either side may be absent for legacy rows recorded before run snapshots
/// existed. [previousSnapshotJson] is drawn only from an earlier completed run
/// of the same sequence.
class SequenceRunDiffContext {
  final int? sequenceId;
  final String? currentSnapshotJson;
  final String? previousSnapshotJson;

  const SequenceRunDiffContext({
    required this.sequenceId,
    required this.currentSnapshotJson,
    required this.previousSnapshotJson,
  });
}

/// Lightweight row for the sequence version-history list.
///
/// The full snapshot is deliberately absent: remote libraries can render up
/// to 20 restore points without downloading 20 complete sequence documents.
/// [restoreVersion] fetches only the snapshot the operator actually chooses.
class SequenceVersionSummary {
  final int id;
  final int sequenceId;
  final String? label;
  final DateTime createdAt;

  const SequenceVersionSummary({
    required this.id,
    required this.sequenceId,
    required this.createdAt,
    this.label,
  });
}

/// Repository for saving and loading sequences from the database
class SequenceRepository {
  final SequencesDao? _dao;
  final SequenceRunsDao? _runsDao;
  final SequenceVersionsDao? _versionsDao;
  final NetworkBackend? _remote;
  final SequenceFileService? _fileService;

  SequenceRepository._({
    SequencesDao? dao,
    SequenceRunsDao? runsDao,
    SequenceVersionsDao? versionsDao,
    NetworkBackend? remote,
    SequenceFileService? fileService,
  }) : _dao = dao,
       _runsDao = runsDao,
       _versionsDao = versionsDao,
       _remote = remote,
       _fileService = fileService {
    assert(
      (dao != null && remote == null) || (dao == null && remote != null),
      'SequenceRepository must be either local (dao) or remote (NetworkBackend)',
    );
    if (remote != null) {
      assert(
        fileService != null,
        'Remote SequenceRepository requires fileService',
      );
    }
  }

  /// Local repository backed by the database.
  ///
  /// [runsDao], [versionsDao], and [fileService] are optional so existing
  /// callers (and tests) that only need save/load can pass the [SequencesDao]
  /// alone. The diff / version-history features ([loadPreviousRunSnapshot],
  /// [snapshotVersionOnSave], [listVersions], [restoreVersion]) require the
  /// matching dependency and throw a clear [StateError] if invoked without it;
  /// the production provider wires all four.
  factory SequenceRepository(
    SequencesDao dao, {
    SequenceRunsDao? runsDao,
    SequenceVersionsDao? versionsDao,
    SequenceFileService? fileService,
  }) => SequenceRepository._(
    dao: dao,
    runsDao: runsDao,
    versionsDao: versionsDao,
    fileService: fileService,
  );

  factory SequenceRepository.remote(
    NetworkBackend remote,
    SequenceFileService fileService,
  ) => SequenceRepository._(remote: remote, fileService: fileService);

  bool get _isRemote => _remote != null;

  SequenceFileService _requireFileService(String feature) {
    final service = _fileService;
    if (service == null) {
      throw StateError(
        'SequenceRepository.$feature requires a SequenceFileService. '
        'Construct the repository through sequenceRepositoryProvider, which '
        'wires it, rather than SequenceRepository(dao) alone.',
      );
    }
    return service;
  }

  SequenceRunsDao _requireRunsDao(String feature) {
    final dao = _runsDao;
    if (dao == null) {
      throw StateError(
        'SequenceRepository.$feature requires a SequenceRunsDao. '
        'Construct the repository through sequenceRepositoryProvider, which '
        'wires it, rather than SequenceRepository(dao) alone.',
      );
    }
    return dao;
  }

  SequenceVersionsDao _requireVersionsDao(String feature) {
    final dao = _versionsDao;
    if (dao == null) {
      throw StateError(
        'SequenceRepository.$feature requires a SequenceVersionsDao. '
        'Construct the repository through sequenceRepositoryProvider, which '
        'wires it, rather than SequenceRepository(dao) alone.',
      );
    }
    return dao;
  }

  Sequence _sequenceFromRemoteMap(Map<String, dynamic> map) {
    final dbId = map.remove('databaseId');
    final sequence = _fileService!.parseFromMap(map);
    if (dbId is int) {
      return sequence.copyWith(databaseId: dbId);
    }
    return sequence;
  }

  Map<String, dynamic> _sequenceToRemoteMap(Sequence sequence) {
    final map = _fileService!.sequenceToMap(sequence);
    if (sequence.databaseId != null) {
      map['databaseId'] = sequence.databaseId;
    }
    return map;
  }

  /// Save a sequence to the database
  /// Returns the database ID of the saved sequence
  Future<int> saveSequence(Sequence sequence, {bool isTemplate = false}) async {
    if (_isRemote) {
      return _remote!.saveFullSequence(
        _sequenceToRemoteMap(sequence),
        isTemplate: isTemplate,
        databaseId: sequence.databaseId,
      );
    }

    // Check if this sequence already exists in database
    final existingId = sequence.databaseId;

    if (existingId != null) {
      // Update existing sequence
      await _updateSequence(existingId, sequence, isTemplate);
      return existingId;
    } else {
      // Create new sequence
      return await _createSequence(sequence, isTemplate);
    }
  }

  Future<int> _createSequence(Sequence sequence, bool isTemplate) async {
    final dao = _dao!;
    // Create the sequence record
    final sequenceId = await dao.createSequence(
      db.SequencesCompanion.insert(
        name: sequence.name,
        description: Value(sequence.description),
        rootNodeId: Value(sequence.rootNodeId),
        estimatedDurationMins: Value(
          (sequence.totalIntegrationSecs / 60).ceil(),
        ),
        isTemplate: Value(isTemplate),
      ),
    );

    // Save all nodes
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
    final dao = _dao!;
    final existing = await dao.getSequenceById(sequenceId);
    if (existing == null) {
      throw Exception('Sequence $sequenceId not found');
    }

    final existingNodes = await dao.getNodesForSequence(sequenceId);
    final existingNodeMap = {for (final n in existingNodes) n.nodeId: n};

    // Update in place where the node survives (preserves database row IDs),
    // insert what is new, delete what the edit dropped.
    final updates = <db.SequenceNode>[];
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
        db.Sequence(
          id: sequenceId,
          name: sequence.name,
          description: sequence.description,
          rootNodeId: sequence.rootNodeId,
          estimatedDurationMins: (sequence.totalIntegrationSecs / 60).ceil(),
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
    final dao = _dao!;
    await dao.batch((batch) {
      batch.insertAll(dao.sequenceNodes, [
        for (final node in nodes.values) _nodeInsertCompanion(sequenceId, node),
      ]);
    });
  }

  /// The persisted row for a node that already exists, carrying the database
  /// row id (and the target link, which lives only on the row) forward.
  db.SequenceNode _nodeUpdateRow(
    int sequenceId,
    SequenceNode node,
    db.SequenceNode existing,
  ) => db.SequenceNode(
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

  /// Load a sequence from the database
  Future<Sequence?> loadSequence(int sequenceId) async {
    if (_isRemote) {
      final map = await _remote!.getFullSequence(sequenceId);
      return map == null
          ? null
          : _sequenceFromRemoteMap(Map<String, dynamic>.from(map));
    }

    final dbSequence = await _dao!.getSequenceById(sequenceId);
    if (dbSequence == null) return null;

    final dbNodes = await _dao.getNodesForSequence(sequenceId);

    // Convert database nodes to model nodes
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

    // Build child relationships
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

  /// Load all sequences from the database
  Future<List<Sequence>> loadAllSequences() async {
    if (_isRemote) {
      final maps = await _remote!.listFullSequences();
      return maps
          .map((map) => _sequenceFromRemoteMap(Map<String, dynamic>.from(map)))
          .toList();
    }

    final dbSequences = await _dao!.getAllSequences();
    final sequences = <Sequence>[];

    for (final dbSequence in dbSequences) {
      final sequence = await loadSequence(dbSequence.id);
      if (sequence != null) {
        sequences.add(sequence);
      }
    }

    return sequences;
  }

  /// Load all templates from the database
  Future<List<Sequence>> loadAllTemplates() async {
    if (_isRemote) {
      final maps = await _remote!.listFullTemplates();
      return maps
          .map((map) => _sequenceFromRemoteMap(Map<String, dynamic>.from(map)))
          .toList();
    }

    final dbTemplates = await _dao!.getAllTemplates();
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
  Future<List<SequenceSummary>> loadSequenceSummaries() async {
    if (_isRemote) {
      final summaries = await _remote!.listSequenceSummaries();
      return [
        for (final summary in summaries)
          SequenceSummary(
            id: summary.id,
            name: summary.name,
            nodeCount: summary.nodeCount,
            targetCount: summary.targetCount,
            exposureCount: summary.exposureCount,
            totalIntegrationSecs: summary.totalIntegrationSecs,
            primaryTargetName: summary.primaryTargetName,
            lastRunAt: summary.lastRunAt,
            runCount: summary.runCount,
            tags: summary.tags,
            isFavorite: summary.isFavorite,
            createdAt: summary.createdAt,
            modifiedAt: summary.modifiedAt,
          ),
      ];
    }

    final rows = await _dao!.getSequenceSummaryRows();
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
  Future<String?> loadPreviousRunSnapshot(
    int sequenceId, {
    required int beforeRunId,
  }) async {
    if (_isRemote) {
      final context = await loadRunDiffContext(beforeRunId);
      if (context.sequenceId != sequenceId) {
        throw StateError(
          'Run $beforeRunId belongs to sequence ${context.sequenceId}, '
          'not sequence $sequenceId.',
        );
      }
      return context.previousSnapshotJson;
    }
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
  Future<SequenceRunDiffContext> loadRunDiffContext(int runId) async {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
    if (_isRemote) {
      final remote = await _remote!.fetchSequenceRunDiffContext(runId);
      return SequenceRunDiffContext(
        sequenceId: remote.sequenceId,
        currentSnapshotJson: remote.currentSnapshotJson,
        previousSnapshotJson: remote.previousSnapshotJson,
      );
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
  Future<void> setTags(int sequenceId, List<String> tags) async {
    // Normalise: trim, drop blanks, de-duplicate while preserving order.
    final seen = <String>{};
    final cleaned = <String>[
      for (final tag in tags)
        if (tag.trim().isNotEmpty && seen.add(tag.trim())) tag.trim(),
    ];
    if (_isRemote) {
      await _remote!.setSequenceTags(sequenceId, cleaned);
      return;
    }
    await _dao!.setTagsJson(sequenceId, jsonEncode(cleaned));
  }

  /// Toggle the favorite flag for [sequenceId]; returns the new value.
  Future<bool> toggleFavorite(int sequenceId) async {
    if (_isRemote) {
      return _remote!.toggleSequenceFavorite(sequenceId);
    }
    final dao = _dao!;
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
  Future<int?> snapshotVersionOnSave(Sequence sequence, {String? label}) async {
    final sequenceId = sequence.databaseId;
    if (sequenceId == null) return null;
    final fileService = _requireFileService('snapshotVersionOnSave');
    if (_isRemote) {
      return _remote!.snapshotSequenceVersion(
        sequenceId,
        fileService.sequenceToMap(sequence),
        label: label,
      );
    }
    final versionsDao = _requireVersionsDao('snapshotVersionOnSave');
    final snapshotJson = jsonEncode(fileService.sequenceToMap(sequence));
    return versionsDao.appendVersion(
      sequenceId: sequenceId,
      snapshotJson: snapshotJson,
      label: label,
    );
  }

  /// List the version history of [sequenceId], newest first.
  Future<List<SequenceVersionSummary>> listVersions(int sequenceId) async {
    if (_isRemote) {
      final versions = await _remote!.listSequenceVersions(sequenceId);
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
  Future<Sequence?> restoreVersion(int versionId) async {
    final fileService = _requireFileService('restoreVersion');
    final db.SequenceVersion? version;
    if (_isRemote) {
      final remote = await _remote!.getSequenceVersion(versionId);
      version = remote == null
          ? null
          : db.SequenceVersion(
              id: remote.id,
              sequenceId: remote.sequenceId,
              snapshotJson: remote.snapshotJson,
              label: remote.label,
              createdAt: remote.createdAt,
            );
    } else {
      version = await _requireVersionsDao(
        'restoreVersion',
      ).loadVersion(versionId);
    }
    if (version == null) return null;
    final decoded = jsonDecode(version.snapshotJson);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Version $versionId snapshot is not a JSON object '
        '(got ${decoded.runtimeType}).',
      );
    }
    final restored = fileService.parseFromMap(decoded);
    // Re-anchor to the owning sequence row so saving updates in place.
    return restored.copyWith(databaseId: version.sequenceId);
  }

  /// Delete a sequence from the database
  Future<void> deleteSequence(int sequenceId) async {
    if (_isRemote) {
      await _remote!.deleteSequence(sequenceId);
      return;
    }
    await _dao!.deleteSequence(sequenceId);
  }

  /// Duplicate a sequence with fresh UUIDs for all nodes.
  ///
  /// Generates new UUIDs for every node and remaps all parent/child references
  /// so the duplicated sequence is fully independent from the original.
  Future<Sequence?> duplicateSequence(int sequenceId, String newName) async {
    if (_isRemote) {
      final newId = await _remote!.duplicateSequence(sequenceId, newName);
      return loadSequence(newId);
    }

    // Load the source sequence with its full node tree
    final source = await loadSequence(sequenceId);
    if (source == null) {
      throw Exception('Sequence $sequenceId not found');
    }

    const uuid = Uuid();

    // Build a mapping from old node ID to new node ID
    final idMapping = <String, String>{};
    for (final oldId in source.nodes.keys) {
      idMapping[oldId] = uuid.v4();
    }

    // Remap the root node ID
    final newRootNodeId = source.rootNodeId != null
        ? idMapping[source.rootNodeId] ?? source.rootNodeId
        : null;

    // Rebuild nodes with new IDs, remapping parent and child references
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

    // Create a new sequence with the remapped nodes
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

  // Enum wire conversion for the DB `sequence_nodes.properties` blob.
  //
  // The tokens themselves live in `sequence_wire_codec.dart`, shared with the
  // sequence FILE codec: these are the DB codec's bindings to that vocabulary,
  // kept as members because the encoder/decoder parts call them unqualified.

  String _binningToString(BinningMode mode) => mode.name;

  BinningMode _stringToBinning(String? s) =>
      enumFromWireOr(BinningMode.values, s, BinningMode.one);

  FrameType _stringToFrameType(String? value) =>
      enumFromWireOr(FrameType.values, value, FrameType.light);

  String _autofocusMethodToString(AutofocusMethod method) => method.name;

  AutofocusMethod _stringToAutofocusMethod(String? s) =>
      autofocusMethodFromWire(s);

  String _twilightToString(TwilightType type) => type.name;

  TwilightType? _stringToTwilight(String? s) =>
      enumFromWire(TwilightType.values, s);

  String _notificationLevelToString(NotificationLevel level) => level.name;

  NotificationLevel _stringToNotificationLevel(String? s) =>
      enumFromWireOr(NotificationLevel.values, s, NotificationLevel.info);

  List<NotificationTransportKind>? _parseExplicitTransports(dynamic raw) =>
      explicitTransportsFromWire(raw);

  String _loopConditionToString(LoopConditionType type) => type.name;

  LoopConditionType _stringToLoopCondition(String? s) =>
      enumFromWireOr(LoopConditionType.values, s, LoopConditionType.count);

  String _conditionalTypeToString(ConditionalType type) => type.name;

  ConditionalType _stringToConditionalType(String? s) =>
      enumFromWireOr(ConditionalType.values, s, ConditionalType.always);

  String _recoveryActionToString(RecoveryActionType action) =>
      recoveryActionToDbWire(action);

  RecoveryActionType _stringToRecoveryAction(String? s) =>
      recoveryActionFromWire(s, fallback: RecoveryActionType.continueExecution);

  MeridianTriggerMethod _stringToMeridianTriggerMethod(String? s) =>
      enumFromWireOr(
        MeridianTriggerMethod.values,
        s,
        MeridianTriggerMethod.minutesPastMeridian,
      );

  FlipFailureAction _stringToFlipFailureAction(String? s) => enumFromWireOr(
    FlipFailureAction.values,
    s,
    FlipFailureAction.pauseAndAlert,
  );

  TriggerType? _stringToTriggerType(String? s) =>
      enumFromWire(TriggerType.values, s);

  DitherPattern _parseDitherPattern(Object? raw) =>
      enumFromWireOr(DitherPattern.values, raw, DitherPattern.random);
}

BrightnessTierPreferences _parseBrightnessTierPreferences(Object? value) {
  if (value is Map) {
    return BrightnessTierPreferences.fromJson(value.cast<String, dynamic>());
  }
  return const BrightnessTierPreferences();
}

/// Persist a [TargetSchedulerNode]'s azimuth horizon mask as
/// `{id?, name, samples:[{az,alt}]}`. `null` profile encodes to `null`.
Map<String, dynamic>? _schedulerHorizonToJson(HorizonProfile? profile) {
  if (profile == null) return null;
  return {
    if (profile.id != null) 'id': profile.id,
    'name': profile.name,
    'samples': profile.samples.map((s) => s.toJson()).toList(),
  };
}

/// Inverse of [_schedulerHorizonToJson]. Tolerates a missing/empty samples
/// list (returns `null` — flat altitude floor) so legacy saved nodes load.
HorizonProfile? _schedulerHorizonFromJson(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<String, dynamic>();
  final samplesRaw = map['samples'] as List<dynamic>? ?? const [];
  if (samplesRaw.isEmpty) return null;
  return HorizonProfile(
    id: (map['id'] as num?)?.toInt(),
    name: map['name'] as String? ?? 'Site horizon',
    samples: samplesRaw
        .map((e) => HorizonSample.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
  );
}

/// Provider for the sequence repository
final sequenceRepositoryProvider = Provider<SequenceRepository>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return SequenceRepository.remote(
      backend,
      ref.watch(sequenceFileServiceProvider),
    );
  }
  return SequenceRepository(
    ref.watch(sequencesDaoProvider),
    runsDao: ref.watch(sequenceRunsDaoProvider),
    versionsDao: ref.watch(sequenceVersionsDaoProvider),
    fileService: ref.watch(sequenceFileServiceProvider),
  );
});

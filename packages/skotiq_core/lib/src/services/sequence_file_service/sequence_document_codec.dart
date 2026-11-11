part of '../sequence_file_service.dart';

extension _SequenceFileEncoder on SequenceFileService {
  Map<String, dynamic> _sequenceToJson(Sequence sequence) {
    return {
      'schemaVersion': SequenceFileService.currentSchemaVersion,
      'version': '2.0',
      SequenceFileService.qualityStopsMovedKey: true,
      'name': sequence.name,
      'description': sequence.description,
      'rootNodeId': sequence.rootNodeId,
      'isTemplate': sequence.isTemplate,
      'nodes': sequence.nodes.map(
        (id, node) => MapEntry(id, _nodeToJson(node)),
      ),
      'createdAt': sequence.createdAt.toIso8601String(),
      'modifiedAt': sequence.modifiedAt.toIso8601String(),
    };
  }

  Sequence _jsonToSequence(Map<String, dynamic> json) {
    final nodes = <String, SequenceNode>{};
    final nodesJson = (json['nodes'] as Map?)?.cast<String, dynamic>() ?? {};

    for (final entry in nodesJson.entries) {
      final node = nodeFromMap(
        entry.value as Map<String, dynamic>,
        fallbackId: entry.key,
      );
      nodes[node.id] = node;
    }

    return Sequence(
      id: const Uuid().v4(), // Generate new ID for imported sequence
      name: json['name'] as String? ?? 'Imported Sequence',
      description: json['description'] as String? ?? '',
      nodes: nodes,
      rootNodeId: json['rootNodeId'] as String?,
      isTemplate: json['isTemplate'] as bool? ?? false,
      createdAt: _parseDate(json['createdAt']) ?? DateTime.now(),
      modifiedAt: _parseDate(json['modifiedAt']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> _nodeToJson(SequenceNode node) => {
    'id': node.id,
    'nodeType': node.nodeType,
    'name': node.name,
    'parentId': node.parentId,
    'childIds': node.childIds,
    'orderIndex': node.orderIndex,
    'isEnabled': node.isEnabled,
    'comment': node.comment,
    ...node.kind.encodeFields(node, NodeStore.document),
  };

  SequenceNode _jsonToNode(Map<String, dynamic> json, {String? fallbackId}) {
    final rawType = json['nodeType'] as String?;
    if (rawType == null || rawType.trim().isEmpty) {
      throw const FormatException('Sequence node missing nodeType');
    }
    final kind = NodeKind.forDocumentName(rawType);
    if (kind == null) {
      throw FormatException('Unsupported sequence node type: $rawType');
    }
    return kind
        .decodeFields(json, NodeStore.document)
        .copyWith(
          id: (json['id'] as String?) ?? fallbackId ?? const Uuid().v4(),
          name: json['name'] as String?,
          parentId: json['parentId'] as String?,
          childIds: (json['childIds'] as List<dynamic>?)?.cast<String>(),
          orderIndex: (json['orderIndex'] as num?)?.toInt(),
          isEnabled: json['isEnabled'] as bool?,
        );
  }

  DateTime? _parseDate(dynamic value) => switch (value) {
    int() => DateTime.fromMillisecondsSinceEpoch(value),
    String() => DateTime.parse(value),
    _ => null,
  };
}

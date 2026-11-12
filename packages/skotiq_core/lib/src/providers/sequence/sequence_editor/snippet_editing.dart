part of '../sequence_editor.dart';

extension CurrentSequenceSnippetEditing on CurrentSequenceNotifier {
  /// Merge template nodes into an existing target.
  /// If targetId is null, merges into the first target found, or directly to root.
  /// The template's root node children are added as children of the target.
  void mergeTemplateNodes({
    required Map<String, SequenceNode> templateNodes,
    required String? templateRootId,
    String? targetId,
  }) {
    if (_currentSequence == null) return;
    if (templateRootId == null) return;
    _ensureEditable('merge template');
    // Single undo entry for the whole merge — the helper writes the new
    // _currentSequence map atomically below, but a future refactor that splits the
    // write into per-node updates will still be correctly coalesced.
    withUndoBatch(() {
      _saveUndo();
      _mergeTemplateNodesImpl(
        templateNodes: templateNodes,
        templateRootId: templateRootId,
        targetId: targetId,
      );
    });
  }

  void _mergeTemplateNodesImpl({
    required Map<String, SequenceNode> templateNodes,
    required String templateRootId,
    String? targetId,
  }) {
    final newNodes = Map<String, SequenceNode>.from(_currentSequence!.nodes);
    final idMapping = <String, String>{};

    for (final entry in templateNodes.entries) {
      idMapping[entry.key] = const Uuid().v4();
    }

    String? mergeParentId = targetId;
    if (mergeParentId == null) {
      for (final node in newNodes.values) {
        if (node is TargetHeaderNode) {
          mergeParentId = node.id;
          break;
        }
      }
    }
    mergeParentId ??= _currentSequence!.rootNodeId;
    if (mergeParentId == null) return;

    final mergeParent = newNodes[mergeParentId];
    if (mergeParent == null) return;

    final templateRoot = templateNodes[templateRootId];
    if (templateRoot == null) return;

    final childIdsToAdd = <String>[];

    for (final entry in templateNodes.entries) {
      if (entry.key == templateRootId) continue;

      final oldNode = entry.value;
      final newId = idMapping[entry.key]!;

      String? newParentId;
      if (oldNode.parentId == templateRootId) {
        // Direct child of template root -> becomes child of merge target
        newParentId = mergeParentId;
        childIdsToAdd.add(newId);
      } else if (oldNode.parentId != null) {
        newParentId = idMapping[oldNode.parentId];
      }

      final newChildIds = oldNode.childIds
          .map((id) => idMapping[id] ?? id)
          .toList();

      newNodes[newId] = oldNode.copyWith(
        id: newId,
        parentId: newParentId,
        childIds: newChildIds,
      );
    }

    final existingChildCount = mergeParent.childIds.length;
    final updatedChildIds = List<String>.from(mergeParent.childIds)
      ..addAll(childIdsToAdd);
    newNodes[mergeParentId] = mergeParent.copyWith(childIds: updatedChildIds);

    for (int i = 0; i < childIdsToAdd.length; i++) {
      final childId = childIdsToAdd[i];
      if (newNodes.containsKey(childId)) {
        newNodes[childId] = newNodes[childId]!.copyWith(
          orderIndex: existingChildCount + i,
        );
      }
    }

    _currentSequence = _currentSequence!.copyWith(
      nodes: newNodes,
      modifiedAt: DateTime.now(),
    );
  }

  /// Insert a template snippet into the sequence.
  /// The snippet's nodes are deserialized and inserted at the specified parent,
  /// or the currently selected node if no parent is specified.
  ///
  /// Throws [SnippetDeserializationException] if any node in the snippet
  /// carries a `nodeType` value the editor does not recognize. The whole
  /// insertion is rejected (undo entry is still pushed; _currentSequence is unchanged).
  void insertSnippet(
    TemplateSnippet snippet, {
    String? parentId,
    int? index,
    List<String>? profileFilterNames,
  }) {
    if (snippet.nodeData.isEmpty) return;
    _ensureEditable('insert snippet');
    if (_currentSequence == null) {
      createSequence();
      parentId = null;
      index = null;
    }
    withUndoBatch(() {
      _saveUndo();
      _insertSnippetImpl(
        snippet,
        parentId: parentId,
        index: index,
        profileFilterNames: profileFilterNames,
      );
    });
  }

  void _insertSnippetImpl(
    TemplateSnippet snippet, {
    String? parentId,
    int? index,
    List<String>? profileFilterNames,
  }) {
    final newNodes = Map<String, SequenceNode>.from(_currentSequence!.nodes);
    final idMapping = <String, String>{};
    final createdNodes = <SequenceNode>[];

    String? insertParentId = parentId;
    if (insertParentId != null) {
      final parentNode = newNodes[insertParentId];
      if (parentNode != null && !parentNode.kind.isContainer) {
        // Substitute the parent's parent — keeps the insertion semantically
        // attached to a valid container instead of dropping it on a leaf.
        insertParentId = parentNode.parentId;
      }
    }

    insertParentId ??= _currentSequence!.rootNodeId;
    if (insertParentId == null) {
      final rootNode = InstructionSetNode(name: 'Sequence Root');
      newNodes[rootNode.id] = rootNode;
      insertParentId = rootNode.id;
    }

    final insertParent = newNodes[insertParentId];
    if (insertParent == null) return;

    SequenceNode deserializeNodeData(
      Map<String, dynamic> json, {
      String? parentIdOverride,
      int orderIdx = 0,
    }) {
      final originalId = json['id'] as String? ?? const Uuid().v4();
      final newId = const Uuid().v4();
      idMapping[originalId] = newId;

      final childrenJson = json['children'] as List<dynamic>? ?? [];
      final childNodes = <SequenceNode>[];
      for (int i = 0; i < childrenJson.length; i++) {
        final childJson = childrenJson[i] as Map<String, dynamic>;
        final childNode = deserializeNodeData(
          childJson,
          parentIdOverride: newId,
          orderIdx: i,
        );
        childNodes.add(childNode);
      }
      final childIds = childNodes.map((n) => n.id).toList();

      final nodeJson = Map<String, dynamic>.from(json);
      nodeJson['id'] = newId;
      nodeJson['parentId'] = parentIdOverride;
      nodeJson['childIds'] = childIds;
      nodeJson['orderIndex'] = orderIdx;
      // Remove children from JSON — already processed into childIds.
      nodeJson.remove('children');

      final node = _deserializeSnippetNode(nodeJson, snippetName: snippet.name);
      createdNodes.add(node);
      return node;
    }

    final topLevelNodeIds = <String>[];
    final existingChildCount = insertParent.childIds.length;
    final insertIdx = index ?? existingChildCount;

    for (int i = 0; i < snippet.nodeData.length; i++) {
      final nodeJson = snippet.nodeData[i];
      final node = deserializeNodeData(
        nodeJson,
        parentIdOverride: insertParentId,
        orderIdx: insertIdx + i,
      );
      topLevelNodeIds.add(node.id);
    }

    developer.log(
      'insertSnippet: profileFilterNames=$profileFilterNames, createdNodes=${createdNodes.length}',
      name: 'Sequence',
    );
    if (profileFilterNames != null && profileFilterNames.isNotEmpty) {
      for (int i = 0; i < createdNodes.length; i++) {
        final node = createdNodes[i];
        if (node is ExposureNode &&
            node.filter != null &&
            node.filter!.isNotEmpty) {
          final matchedIndex = matchingFilterIndex(
            node.filter!,
            profileFilterNames,
          );
          if (matchedIndex != null) {
            createdNodes[i] = node.copyWith(
              filter: profileFilterNames[matchedIndex],
              filterIndex: matchedIndex,
            );
            developer.log(
              'insertSnippet: Mapped filter "${node.filter}" -> "${profileFilterNames[matchedIndex]}" (index $matchedIndex)',
              name: 'Sequence',
            );
          }
        } else if (node is FilterChangeNode) {
          final matchedIndex = matchingFilterIndex(
            node.filterName,
            profileFilterNames,
          );
          if (matchedIndex != null) {
            createdNodes[i] = node.copyWith(
              filterName: profileFilterNames[matchedIndex],
              filterPosition: matchedIndex,
            );
          }
        }
      }
    }

    for (final node in createdNodes) {
      newNodes[node.id] = node;
    }

    final newChildIds = List<String>.from(insertParent.childIds);
    newChildIds.insertAll(insertIdx, topLevelNodeIds);

    for (
      int i = insertIdx + topLevelNodeIds.length;
      i < newChildIds.length;
      i++
    ) {
      final childId = newChildIds[i];
      if (newNodes.containsKey(childId)) {
        newNodes[childId] = newNodes[childId]!.copyWith(orderIndex: i);
      }
    }

    newNodes[insertParentId] = insertParent.copyWith(childIds: newChildIds);

    _currentSequence = _currentSequence!.copyWith(
      nodes: newNodes,
      modifiedAt: DateTime.now(),
    );
  }

  /// Snippet-only spellings of a node type, from builds that saved snippets
  /// before snippets shared the sequence-file codec.
  static const _legacySnippetTypes = {
    'targetschedulernode': 'TargetScheduler',
    'smartexposurenode': 'SmartExposure',
  };

  /// Deserialize a single node from snippet JSON data with the sequence-file
  /// codec, so a snippet can hold every node type and field a sequence can.
  ///
  /// Old snippets may hold a target with no name or coordinates; it gets the
  /// placeholder target a new Target step gets, which the sequence checks
  /// then flag. [snippetName] names the snippet in the error for a node type
  /// this build does not know.
  SequenceNode _deserializeSnippetNode(
    Map<String, dynamic> json, {
    required String snippetName,
  }) {
    final rawType = json['nodeType'] as String?;
    if (rawType == null || rawType.trim().isEmpty) {
      throw SnippetDeserializationException(
        unknownType: '<missing>',
        snippetName: snippetName,
      );
    }
    final kind = NodeKind.forDocumentName(
      _legacySnippetTypes[normalizeNodeTypeName(rawType)] ?? rawType,
    );
    if (kind == null) {
      throw SnippetDeserializationException(
        unknownType: rawType,
        snippetName: snippetName,
      );
    }
    final stored = {
      ...json,
      'nodeType': kind.wireName,
      if (kind == NodeKinds.targetHeader) ...{
        'targetName': json['targetName'] ?? 'Target',
        'raHours': json['raHours'] ?? 0.0,
        'decDegrees': json['decDegrees'] ?? 0.0,
      },
    };
    return SequenceFileService().nodeFromMap(stored);
  }
}

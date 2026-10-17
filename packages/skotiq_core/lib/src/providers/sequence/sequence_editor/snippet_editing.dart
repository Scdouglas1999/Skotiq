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
    if (_currentSequence == null) return;
    if (snippet.nodeData.isEmpty) return;
    _ensureEditable('insert snippet');
    // Single undo entry for the whole multi-node insertion.
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
      if (parentNode != null && !_canHaveChildren(parentNode)) {
        // Substitute the parent's parent — keeps the insertion semantically
        // attached to a valid container instead of dropping it on a leaf.
        insertParentId = parentNode.parentId;
      }
    }

    insertParentId ??= _currentSequence!.rootNodeId;
    if (insertParentId == null) {
      // Create root if sequence is empty
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
          final matchedIndex = _matchFilterToProfile(
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
          final matchedIndex = _matchFilterToProfile(
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

  /// Check if a node type can have children.
  ///
  /// `SequenceNode` is sealed, so every concrete subtype must be classified
  /// below — a new node type will produce a compile-time error here.
  bool _canHaveChildren(SequenceNode node) {
    return switch (node) {
      TargetHeaderNode _ ||
      LoopNode _ ||
      InstructionSetNode _ ||
      ParallelNode _ ||
      ConditionalNode _ ||
      RecoveryNode _ ||
      // TargetScheduler is a container — children are the
      // candidate TargetHeaders the scheduler picks from.
      TargetSchedulerNode _ => true,
      ExposureNode _ ||
      SlewNode _ ||
      CenterNode _ ||
      AutofocusNode _ ||
      DitherNode _ ||
      StartGuidingNode _ ||
      StopGuidingNode _ ||
      FilterChangeNode _ ||
      CoolCameraNode _ ||
      WarmCameraNode _ ||
      RotatorNode _ ||
      ParkNode _ ||
      UnparkNode _ ||
      WaitTimeNode _ ||
      DelayNode _ ||
      NotificationNode _ ||
      ScriptNode _ ||
      MeridianFlipNode _ ||
      OpenDomeNode _ ||
      CloseDomeNode _ ||
      ParkDomeNode _ ||
      PolarAlignmentNode _ ||
      OpenCoverNode _ ||
      CloseCoverNode _ ||
      CalibratorOnNode _ ||
      CalibratorOffNode _ ||
      // SmartExposure is a *leaf* in the Dart tree — all
      // per-filter behaviour is encoded in `plans` and Rust dispatches the
      // batches internally via the InstructionRegistry. The Dart node
      // intentionally has no childIds so the editor must not accept drops
      // onto it.
      SmartExposureNode _ ||
      // LiveStacking is a leaf side-effect instruction
      // — it arms the broadcast service and returns. Any child would
      // never execute.
      LiveStackingNode _ ||
      // Science: SciencePhotometry is a leaf — the per-frame
      // photometric capture is fully encoded in the node's config.
      SciencePhotometryNode _ ||
      // Plugin nodes are leaves. The plugin author owns
      // any internal fan-out; nesting Dart-side children under a
      // plugin node would never execute.
      PluginInstructionNode _ => false,
    };
  }

  /// Deserialize a single node from snippet JSON data.
  ///
  /// [snippetName] is propagated into [SnippetDeserializationException] so
  /// the user can identify which snippet referenced the bad node type.
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

    final nodeType = rawType.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final id = json['id'] as String? ?? const Uuid().v4();
    final name = json['name'] as String?;
    final parentId = json['parentId'] as String?;
    final childIds =
        (json['childIds'] as List<dynamic>?)?.cast<String>() ?? const [];
    final orderIndex = (json['orderIndex'] as num?)?.toInt() ?? 0;
    // Match the SequenceNode model default (isEnabled defaults to true).
    // Legacy snippet JSON that predates the flag must deserialize enabled,
    // not silently disabled — a disabled node is skipped at execution and
    // gives the user a "why didn't my pasted snippet run?" surprise.
    final isEnabled = json['isEnabled'] as bool? ?? true;

    // Canonical path: use the exhaustive sequence-file decoder so a snippet
    // cannot silently lose fields (or reject node types) that normal sequence
    // import already supports. The switch below remains as a compatibility
    // fallback for legacy snippet-only aliases and permissive old payloads.
    final canonicalJson = Map<String, dynamic>.from(json)
      ..['isEnabled'] = isEnabled;
    try {
      return SequenceFileService().nodeFromMap(canonicalJson);
    } on FormatException {
      // Fall through to the legacy compatibility decoder below. Its default
      // branch still raises SnippetDeserializationException with the snippet
      // name for genuinely unknown node types.
    }

    switch (nodeType) {
      case 'targetheader':
      case 'targetgroup':
        return TargetHeaderNode(
          id: id,
          name: name ?? 'Target',
          targetName: json['targetName'] as String? ?? 'Target',
          raHours: (json['raHours'] as num?)?.toDouble() ?? 0.0,
          decDegrees: (json['decDegrees'] as num?)?.toDouble() ?? 0.0,
          rotation: (json['rotation'] as num?)?.toDouble(),
          priority: (json['priority'] as num?)?.toInt() ?? 0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'loop':
        return LoopNode(
          id: id,
          name: name ?? 'Loop',
          conditionType: _parseLoopType(json['conditionType']),
          repeatCount: (json['repeatCount'] as num?)?.toInt(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'parallel':
        return ParallelNode(
          id: id,
          name: name ?? 'Parallel',
          requiredSuccesses: (json['requiredSuccesses'] as num?)?.toInt(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'targetscheduler':
      case 'targetschedulernode':
        return TargetSchedulerNode(
          id: id,
          name: name ?? 'Scheduler',
          altitudeWeight: (json['altitudeWeight'] as num?)?.toDouble() ?? 0.25,
          moonDistanceWeight:
              (json['moonDistanceWeight'] as num?)?.toDouble() ?? 0.25,
          transitProximityWeight:
              (json['transitProximityWeight'] as num?)?.toDouble() ?? 0.20,
          darknessWeight: (json['darknessWeight'] as num?)?.toDouble() ?? 0.15,
          airmassWeight: (json['airmassWeight'] as num?)?.toDouble() ?? 0.15,
          minScoreToRun: (json['minScoreToRun'] as num?)?.toDouble() ?? 30.0,
          recomputeEveryNExposures:
              (json['recomputeEveryNExposures'] as num?)?.toInt() ?? 0,
          finishIterationOnSwitch:
              json['finishIterationOnSwitch'] as bool? ?? true,
          swapOnConditionsBelow:
              (json['swapOnConditionsBelow'] as num?)?.toDouble() ??
              (json['swap_on_conditions_below'] as num?)?.toDouble(),
          swapHysteresisSecs:
              (json['swapHysteresisSecs'] as num?)?.toDouble() ??
              (json['swap_hysteresis_secs'] as num?)?.toDouble() ??
              180.0,
          brightnessTierPreferences: _parseBrightnessTierPreferencesForSnippet(
            json['brightnessTierPreferences'] ??
                json['brightness_tier_preferences'],
          ),
          maxConditionsScoreAgeSecs:
              (json['maxConditionsScoreAgeSecs'] as num?)?.toInt() ??
              (json['max_conditions_score_age_secs'] as num?)?.toInt() ??
              300,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'conditional':
        return ConditionalNode(
          id: id,
          name: name ?? 'Conditional',
          conditionType: _parseConditionType(json['conditionType']),
          thresholdValue: (json['thresholdValue'] as num?)?.toDouble(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'recovery':
        return RecoveryNode(
          id: id,
          name: name ?? 'Recovery',
          recoveryAction: _parseRecoveryAction(json['recoveryAction']),
          maxRetries: (json['maxRetries'] as num?)?.toInt() ?? 3,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'instructionset':
        return InstructionSetNode(
          id: id,
          name: name ?? 'Instructions',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'slewtotarget':
      case 'slew':
        return SlewNode(
          id: id,
          name: name ?? 'Slew to Target',
          useTargetCoords: json['useTargetCoords'] as bool? ?? false,
          customRa: (json['customRa'] as num?)?.toDouble(),
          customDec: (json['customDec'] as num?)?.toDouble(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'centertarget':
      case 'center':
        return CenterNode(
          id: id,
          name: name ?? 'Center Target',
          useTargetCoords: json['useTargetCoords'] as bool? ?? false,
          accuracyArcsec: (json['accuracyArcsec'] as num?)?.toDouble() ?? 5.0,
          maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 5,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'takeexposure':
      case 'exposure':
        return ExposureNode(
          id: id,
          name: name ?? 'Take Exposures',
          durationSecs: (json['durationSecs'] as num?)?.toDouble() ?? 60.0,
          count: (json['count'] as num?)?.toInt() ?? 10,
          frameType: _parseFrameTypeForSnippet(json['frameType']),
          filter: json['filter'] as String?,
          filterIndex: (json['filterIndex'] as num?)?.toInt(),
          gain: (json['gain'] as num?)?.toInt(),
          offset: (json['offset'] as num?)?.toInt(),
          binning: _parseBinningForSnippet(json['binning']),
          ditherEvery: (json['ditherEvery'] as num?)?.toInt(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'smartexposure':
      case 'smartexposurenode':
        return SmartExposureNode(
          id: id,
          name: name ?? 'Smart Exposure',
          plans: ((json['plans'] as List?) ?? const [])
              .whereType<Map>()
              .map((plan) => FilterPlan.fromJson(plan.cast<String, dynamic>()))
              .toList(growable: false),
          rotateFilters: json['rotateFilters'] as bool? ?? true,
          ditherOnFilterChange: json['ditherOnFilterChange'] as bool? ?? false,
          integrationBudgetSecs:
              (json['integrationBudgetSecs'] as num?)?.toDouble() ?? 0.0,
          batchSize: (json['batchSize'] as num?)?.toInt() ?? 1,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'autofocus':
        return AutofocusNode(
          id: id,
          name: name ?? 'Autofocus',
          method: _parseAutofocusMethodForSnippet(json['method']),
          stepSize: (json['stepSize'] as num?)?.toInt() ?? 100,
          stepsOut: (json['stepsOut'] as num?)?.toInt() ?? 7,
          exposuresPerPoint: (json['exposuresPerPoint'] as num?)?.toInt() ?? 1,
          exposureDuration:
              (json['exposureDuration'] as num?)?.toDouble() ?? 3.0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'dither':
        return DitherNode(
          id: id,
          name: name ?? 'Dither',
          pixels: (json['pixels'] as num?)?.toDouble() ?? 5.0,
          settlePixels: (json['settlePixels'] as num?)?.toDouble() ?? 1.5,
          settleTime: (json['settleTime'] as num?)?.toDouble() ?? 30.0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'startguiding':
        return StartGuidingNode(
          id: id,
          name: name ?? 'Start Guiding',
          settlePixels: (json['settlePixels'] as num?)?.toDouble() ?? 1.5,
          settleTime: (json['settleTime'] as num?)?.toDouble() ?? 10.0,
          settleTimeout: (json['settleTimeout'] as num?)?.toDouble() ?? 60.0,
          autoSelectStar: json['autoSelectStar'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'stopguiding':
        return StopGuidingNode(
          id: id,
          name: name ?? 'Stop Guiding',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'changefilter':
      case 'filterchange':
        return FilterChangeNode(
          id: id,
          name: name ?? 'Change Filter',
          filterName:
              json['filterName'] as String? ?? json['filter'] as String? ?? 'L',
          filterPosition:
              (json['filterPosition'] as num?)?.toInt() ??
              (json['filterIndex'] as num?)?.toInt(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'coolcamera':
        return CoolCameraNode(
          id: id,
          name: name ?? 'Cool Camera',
          targetTemp: (json['targetTemp'] as num?)?.toDouble() ?? -10.0,
          durationMins: (json['durationMins'] as num?)?.toDouble(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'warmcamera':
        return WarmCameraNode(
          id: id,
          name: name ?? 'Warm Camera',
          ratePerMin: (json['ratePerMin'] as num?)?.toDouble() ?? 5.0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'park':
        return ParkNode(
          id: id,
          name: name ?? 'Park Mount',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'unpark':
        return UnparkNode(
          id: id,
          name: name ?? 'Unpark Mount',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'meridianflip':
        return MeridianFlipNode(
          id: id,
          name: name ?? 'Meridian Flip',
          minutesPastMeridian:
              (json['minutesPastMeridian'] as num?)?.toDouble() ?? 5.0,
          pauseGuiding: json['pauseGuiding'] as bool? ?? false,
          autoCenter: json['autoCenter'] as bool? ?? false,
          settleTime: (json['settleTime'] as num?)?.toDouble() ?? 10.0,
          // Legacy JSON has no flag; pin the values verbatim.
          useGlobalDefaults: json['useGlobalDefaults'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'delay':
        return DelayNode(
          id: id,
          name: name ?? 'Delay',
          seconds: (json['seconds'] as num?)?.toDouble() ?? 0.0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'notification':
        return NotificationNode(
          id: id,
          name: name ?? 'Notification',
          title: json['title'] as String? ?? 'Notification',
          message: json['message'] as String? ?? '',
          level: _parseNotificationLevel(json['level']),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      default:
        // Unknown discriminator — fail loudly so the importer can surface
        // a meaningful error to the user instead of silently dropping
        // unrelated nodes into the tree as empty containers.
        throw SnippetDeserializationException(
          unknownType: rawType,
          snippetName: snippetName,
        );
    }
  }

  LoopConditionType _parseLoopType(dynamic value) {
    if (value == null) return LoopConditionType.count;
    final str = value.toString().toLowerCase();
    return LoopConditionType.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => LoopConditionType.count,
    );
  }

  ConditionalType _parseConditionType(dynamic value) {
    if (value == null) return ConditionalType.weatherSafe;
    final str = value.toString().toLowerCase();
    return ConditionalType.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => ConditionalType.weatherSafe,
    );
  }

  RecoveryActionType _parseRecoveryAction(dynamic value) {
    if (value == null) return RecoveryActionType.retry;
    final str = value.toString().toLowerCase();
    return RecoveryActionType.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => RecoveryActionType.retry,
    );
  }

  FrameType _parseFrameTypeForSnippet(dynamic value) {
    if (value == null) return FrameType.light;
    final str = value.toString().toLowerCase();
    return FrameType.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => FrameType.light,
    );
  }

  BinningMode _parseBinningForSnippet(dynamic value) {
    if (value == null) return BinningMode.one;
    final str = value.toString().toLowerCase();
    return BinningMode.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => BinningMode.one,
    );
  }

  BrightnessTierPreferences _parseBrightnessTierPreferencesForSnippet(
    dynamic value,
  ) {
    if (value is Map) {
      return BrightnessTierPreferences.fromJson(value.cast<String, dynamic>());
    }
    return const BrightnessTierPreferences();
  }

  AutofocusMethod _parseAutofocusMethodForSnippet(dynamic value) {
    if (value == null) return AutofocusMethod.vCurve;
    final str = value.toString().toLowerCase();
    return AutofocusMethod.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => AutofocusMethod.vCurve,
    );
  }

  NotificationLevel _parseNotificationLevel(dynamic value) {
    if (value == null) return NotificationLevel.info;
    final str = value.toString().toLowerCase();
    return NotificationLevel.values.firstWhere(
      (e) => e.name.toLowerCase() == str,
      orElse: () => NotificationLevel.info,
    );
  }

  /// Common abbreviation map for filter name matching.
  /// Maps normalized template names to possible profile name patterns.
  static const _filterAbbreviations = <String, List<String>>{
    'l': ['lum', 'luminance', 'luminosity', 'clear'],
    'r': ['red'],
    'g': ['green'],
    'b': ['blue'],
    'ha': ['halpha', 'h-alpha', 'h_alpha', 'hydrogen', 'hydrogen-alpha'],
    'oiii': ['o3', 'oxygen', 'oxygeniii'],
    'sii': ['s2', 'sulfur', 'sulphur', 'sulfurii'],
    'nii': ['n2', 'nitrogen', 'nitrogenii'],
  };

  /// Try to match a template filter name to one of the profile filter names.
  /// Returns the matched index (0-based) or null if no match found.
  int? _matchFilterToProfile(String templateFilter, List<String> profileNames) {
    final templateLower = templateFilter.toLowerCase().trim();
    if (templateLower.isEmpty) return null;

    // Pass 1: Exact match (case-insensitive)
    for (int i = 0; i < profileNames.length; i++) {
      if (profileNames[i].toLowerCase().trim() == templateLower) return i;
    }

    // Pass 2: Profile name starts with template name (e.g. "L" matches "Lum")
    for (int i = 0; i < profileNames.length; i++) {
      final profileLower = profileNames[i].toLowerCase().trim();
      if (profileLower.startsWith(templateLower)) return i;
    }

    // Pass 3: Template name starts with profile name (e.g. "Luminance" matches "Lum")
    for (int i = 0; i < profileNames.length; i++) {
      final profileLower = profileNames[i].toLowerCase().trim();
      if (templateLower.startsWith(profileLower) && profileLower.isNotEmpty) {
        return i;
      }
    }

    // Pass 4: Known abbreviation matching
    final knownAliases = _filterAbbreviations[templateLower];
    if (knownAliases != null) {
      for (int i = 0; i < profileNames.length; i++) {
        final profileLower = profileNames[i].toLowerCase().trim();
        for (final alias in knownAliases) {
          if (profileLower == alias ||
              profileLower.startsWith(alias) ||
              alias.startsWith(profileLower)) {
            return i;
          }
        }
      }
    }

    // Pass 5: Reverse — match abbreviation aliases against profile names.
    for (final entry in _filterAbbreviations.entries) {
      for (final alias in entry.value) {
        if (alias == templateLower || templateLower.startsWith(alias)) {
          for (int i = 0; i < profileNames.length; i++) {
            final profileLower = profileNames[i].toLowerCase().trim();
            if (profileLower.startsWith(entry.key) ||
                entry.key.startsWith(profileLower)) {
              return i;
            }
          }
        }
      }
    }

    return null;
  }
}

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/sequence/template_snippet.dart';
import '../models/sequence/sequence_models.dart';
import '../services/sequence_file_service.dart';
import '../utils/skotiq_data_directory.dart';

// Built-in snippets provider

/// Provider that returns all built-in template snippets
final builtInSnippetsProvider = Provider<List<TemplateSnippet>>((ref) {
  return BuiltInSnippets.all;
});

// Custom snippets provider

/// Provider for managing user-created custom snippets
final customSnippetsProvider =
    StateNotifierProvider<CustomSnippetsNotifier, List<TemplateSnippet>>((ref) {
      return CustomSnippetsNotifier();
    });

/// Notifier for managing custom template snippets with file persistence.
///
/// Snippets are lazily loaded from disk on first access that needs them
/// (add, update, remove, or explicit load). The provider starts with an
/// empty list and sets [_loaded] once disk data has been read, so the
/// list-building cost is deferred until the template browser is opened.
class CustomSnippetsNotifier extends StateNotifier<List<TemplateSnippet>> {
  bool _loaded = false;
  Object? _loadFailure;
  Future<void>? _loadFuture;
  Future<void> _mutationTail = Future<void>.value();
  final Future<File> Function() _snippetsFile;

  CustomSnippetsNotifier({Future<File> Function()? snippetsFile})
    : _snippetsFile = snippetsFile ?? _defaultSnippetsFile,
      super([]) {
    // Trigger lazy load on construction so data is ready when first watched.
    // The load is async and the UI will see an empty list until it completes.
    loadFromDisk();
  }

  /// Ensure snippets have been loaded from disk. No-op after the first load.
  Future<void> _ensureLoaded() async {
    if (!_loaded) {
      await (_loadFuture ??= _readFromDisk());
    }
    final failure = _loadFailure;
    if (failure != null) {
      throw StateError(
        'Custom templates could not be loaded; refusing to overwrite them: '
        '$failure',
      );
    }
  }

  /// Load custom snippets from disk.
  ///
  /// Sets [_loaded] on completion (even on error) so subsequent calls are
  /// no-ops via [_ensureLoaded].
  Future<void> loadFromDisk() {
    if (!_loaded && _loadFuture != null) return _loadFuture!;
    _loaded = false;
    _loadFailure = null;
    return _loadFuture = _readFromDisk();
  }

  Future<void> _readFromDisk() async {
    try {
      final file = await _snippetsFile();
      if (!await file.exists()) {
        state = [];
        return;
      }

      final jsonString = await file.readAsString();
      if (jsonString.isEmpty) {
        state = [];
        return;
      }

      final List<dynamic> jsonList = jsonDecode(jsonString);
      final snippets = jsonList
          .map((json) => TemplateSnippet.fromJson(json as Map<String, dynamic>))
          .toList();
      state = snippets;
    } catch (e) {
      _loadFailure = e;
      developer.log(
        'Error loading custom snippets: $e',
        name: 'TemplateSnippet',
        level: 1000,
      );
    } finally {
      _loaded = true;
    }
  }

  /// Save custom snippets to disk
  Future<void> saveToDisk() async {
    try {
      final file = await _snippetsFile();

      // Ensure directory exists
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final jsonList = state.map((s) => s.toJson()).toList();
      final jsonString = const JsonEncoder.withIndent('  ').convert(jsonList);
      await file.writeAsString(jsonString);
    } catch (e) {
      // Re-throw to let caller handle the error
      throw Exception('Failed to save custom snippets: $e');
    }
  }

  /// Add a new custom snippet
  Future<void> addSnippet(TemplateSnippet snippet) async {
    // Ensure the snippet is not marked as built-in
    final snippetToAdd = snippet.isBuiltIn
        ? snippet.copyWith(isBuiltIn: false)
        : snippet;
    await _mutateAndSave(() => state = [...state, snippetToAdd]);
  }

  /// Remove a custom snippet by ID
  Future<void> removeSnippet(String id) async {
    await _mutateAndSave(() => state = state.where((s) => s.id != id).toList());
  }

  /// Update an existing custom snippet
  Future<void> updateSnippet(TemplateSnippet snippet) async {
    await _mutateAndSave(() {
      final index = state.indexWhere((s) => s.id == snippet.id);
      if (index == -1) {
        throw ArgumentError('Snippet with id ${snippet.id} not found');
      }

      final updatedList = [...state];
      updatedList[index] = snippet;
      state = updatedList;
    });
  }

  Future<void> _mutateAndSave(void Function() mutation) {
    final operation = _mutationTail.then((_) async {
      await _ensureLoaded();
      final previous = state;
      try {
        mutation();
        await saveToDisk();
      } catch (error) {
        state = previous;
        rethrow;
      }
    });
    _mutationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }
}

Future<File> _defaultSnippetsFile() async {
  final appDir = await resolveSkotiqDataDirectory();
  final snippetsDir = '${appDir.path}${Platform.pathSeparator}snippets';
  return File('$snippetsDir${Platform.pathSeparator}custom_snippets.json');
}

// Combined snippets providers

/// Provider that combines built-in and custom snippets
final allSnippetsProvider = Provider<List<TemplateSnippet>>((ref) {
  final builtIn = ref.watch(builtInSnippetsProvider);
  final custom = ref.watch(customSnippetsProvider);
  return [...builtIn, ...custom];
});

/// Provider that groups all snippets by category
final snippetsByCategoryProvider =
    Provider<Map<SnippetCategory, List<TemplateSnippet>>>((ref) {
      final all = ref.watch(allSnippetsProvider);

      final grouped = <SnippetCategory, List<TemplateSnippet>>{};

      for (final snippet in all) {
        final category = snippet.category;
        if (!grouped.containsKey(category)) {
          grouped[category] = [];
        }
        grouped[category]!.add(snippet);
      }

      // Sort snippets within each category by name
      for (final category in grouped.keys) {
        grouped[category]!.sort((a, b) => a.name.compareTo(b.name));
      }

      return grouped;
    });

// Helper functions

/// Create a template snippet from selected nodes in a sequence
///
/// This extracts the specified nodes from the sequence, serializes them,
/// and creates a new TemplateSnippet that can be saved and reused.
TemplateSnippet createSnippetFromSelection({
  required String name,
  required String description,
  required SnippetCategory category,
  required String iconName,
  required List<String> nodeIds,
  required Sequence sequence,
}) {
  if (nodeIds.isEmpty) {
    throw ArgumentError('nodeIds cannot be empty');
  }

  // Create a SequenceFileService instance to use its serialization methods
  final fileService = SequenceFileService();

  // Extract and serialize each selected node
  final nodeData = <Map<String, dynamic>>[];

  for (final nodeId in nodeIds) {
    final node = sequence.getNode(nodeId);
    if (node == null) {
      throw ArgumentError('Node with id $nodeId not found in sequence');
    }

    // Use the file service's internal serialization method
    // We need to access it through a workaround since it's private
    nodeData.add(_serializeNode(node, sequence, fileService));
  }

  return TemplateSnippet(
    id: const Uuid().v4(),
    name: name,
    description: description,
    category: category,
    iconName: iconName,
    nodeData: nodeData,
    isBuiltIn: false,
    createdAt: DateTime.now(),
  );
}

/// Serialize a node and its children to JSON
///
/// This is a helper that replicates the serialization logic from SequenceFileService
/// but also handles recursive serialization of children for snippets.
Map<String, dynamic> _serializeNode(
  SequenceNode node,
  Sequence sequence,
  SequenceFileService fileService,
) {
  // Start from the canonical, exhaustive sequence-file codec. The
  // hand-maintained map below is incomplete — it covers neither every field
  // nor every node type — so taking the canonical map first is what keeps
  // snippet save/insert from dropping them. Strip
  // tree identity because snippets rebuild topology recursively under fresh
  // IDs when inserted.
  final base = fileService.nodeToMap(node)
    ..remove('id')
    ..remove('parentId')
    ..remove('childIds')
    ..remove('orderIndex');

  // Add type-specific properties
  if (node is TargetHeaderNode) {
    base.addAll({
      'targetName': node.targetName,
      'raHours': node.raHours,
      'decDegrees': node.decDegrees,
      'rotation': node.rotation,
      'priority': node.priority,
      'minAltitude': node.minAltitude,
      'maxAltitude': node.maxAltitude,
      'startAfter': node.startAfter?.toIso8601String(),
      'endBefore': node.endBefore?.toIso8601String(),
      'mosaicPanel': node.mosaicPanel?.toJson(),
    });
  } else if (node is LoopNode) {
    base.addAll({
      'conditionType': node.conditionType.name,
      'repeatCount': node.repeatCount,
      'repeatUntil': node.repeatUntil?.toIso8601String(),
      'repeatUntilAltitude': node.repeatUntilAltitude,
      'integrationTimeTarget': node.integrationTimeTarget,
      'maxSafetyIterations': node.maxSafetyIterations,
    });
  } else if (node is ParallelNode) {
    base.addAll({'requiredSuccesses': node.requiredSuccesses});
  } else if (node is TargetSchedulerNode) {
    base.addAll({
      'altitudeWeight': node.altitudeWeight,
      'moonDistanceWeight': node.moonDistanceWeight,
      'transitProximityWeight': node.transitProximityWeight,
      'darknessWeight': node.darknessWeight,
      'airmassWeight': node.airmassWeight,
      'minScoreToRun': node.minScoreToRun,
      'recomputeEveryNExposures': node.recomputeEveryNExposures,
      'finishIterationOnSwitch': node.finishIterationOnSwitch,
      'swapOnConditionsBelow': node.swapOnConditionsBelow,
      'swapHysteresisSecs': node.swapHysteresisSecs,
      'brightnessTierPreferences': node.brightnessTierPreferences.toJson(),
      'maxConditionsScoreAgeSecs': node.maxConditionsScoreAgeSecs,
    });
  } else if (node is ConditionalNode) {
    base.addAll({
      'conditionType': node.conditionType.name,
      'thresholdValue': node.thresholdValue,
      'thresholdTime': node.thresholdTime?.toIso8601String(),
    });
  } else if (node is RecoveryNode) {
    base.addAll({
      'recoveryAction': node.recoveryAction.name,
      'maxRetries': node.maxRetries,
      'triggerType': node.triggerType?.name,
      'triggerThreshold': node.triggerThreshold,
      'hfrThresholdPercent': node.hfrThresholdPercent,
      'hfrConsecutiveFrames': node.hfrConsecutiveFrames,
    });
  } else if (node is SlewNode) {
    base.addAll({
      'useTargetCoords': node.useTargetCoords,
      'customRa': node.customRa,
      'customDec': node.customDec,
    });
  } else if (node is CenterNode) {
    base.addAll({
      'useTargetCoords': node.useTargetCoords,
      'customRa': node.customRa,
      'customDec': node.customDec,
      'accuracyArcsec': node.accuracyArcsec,
      'maxAttempts': node.maxAttempts,
      'exposureDuration': node.exposureDuration,
      'filter': node.filter,
    });
  } else if (node is ExposureNode) {
    base.addAll({
      'durationSecs': node.durationSecs,
      'count': node.count,
      'frameType': node.frameType.name,
      'filter': node.filter,
      'filterIndex': node.filterIndex,
      'gain': node.gain,
      'offset': node.offset,
      'binning': node.binning.name,
      'ditherEvery': node.ditherEvery,
    });
  } else if (node is SmartExposureNode) {
    base.addAll({
      'plans': node.plans.map((p) => p.toJson()).toList(growable: false),
      'rotateFilters': node.rotateFilters,
      'ditherOnFilterChange': node.ditherOnFilterChange,
      'integrationBudgetSecs': node.integrationBudgetSecs,
      'batchSize': node.batchSize,
      'loopUntilStopped': node.loopUntilStopped,
    });
  } else if (node is AutofocusNode) {
    base.addAll({
      'method': node.method.name,
      'stepSize': node.stepSize,
      'stepsOut': node.stepsOut,
      'exposuresPerPoint': node.exposuresPerPoint,
      'exposureDuration': node.exposureDuration,
      'useSettingsDefaults': node.useSettingsDefaults,
    });
  } else if (node is DitherNode) {
    base.addAll({
      'pixels': node.pixels,
      'settlePixels': node.settlePixels,
      'settleTime': node.settleTime,
      'settleTimeout': node.settleTimeout,
      'raOnly': node.raOnly,
    });
  } else if (node is StartGuidingNode) {
    base.addAll({
      'settlePixels': node.settlePixels,
      'settleTime': node.settleTime,
      'settleTimeout': node.settleTimeout,
      'autoSelectStar': node.autoSelectStar,
    });
  } else if (node is FilterChangeNode) {
    base.addAll({
      'filterName': node.filterName,
      'filterPosition': node.filterPosition,
    });
  } else if (node is CoolCameraNode) {
    base.addAll({
      'targetTemp': node.targetTemp,
      'durationMins': node.durationMins,
    });
  } else if (node is WarmCameraNode) {
    base.addAll({'ratePerMin': node.ratePerMin});
  } else if (node is RotatorNode) {
    base.addAll({'targetAngle': node.targetAngle, 'relative': node.relative});
  } else if (node is WaitTimeNode) {
    base.addAll({
      'waitUntil': node.waitUntil?.toIso8601String(),
      'waitForTwilight': node.waitForTwilight?.name,
    });
  } else if (node is DelayNode) {
    base.addAll({'seconds': node.seconds});
  } else if (node is NotificationNode) {
    base.addAll({
      'title': node.title,
      'message': node.message,
      'level': node.level.name,
    });
  } else if (node is ScriptNode) {
    base.addAll({
      'scriptPath': node.scriptPath,
      'arguments': node.arguments,
      'timeoutSecs': node.timeoutSecs,
    });
  } else if (node is MeridianFlipNode) {
    base.addAll({
      'triggerMethod': node.triggerMethod.name,
      'minutesPastMeridian': node.minutesPastMeridian,
      'minutesBeforeLimit': node.minutesBeforeLimit,
      'hourAngleThreshold': node.hourAngleThreshold,
      'pauseGuiding': node.pauseGuiding,
      'autoCenter': node.autoCenter,
      'refocusAfter': node.refocusAfter,
      'settleTime': node.settleTime,
      'resumeGuiding': node.resumeGuiding,
      'maxRetries': node.maxRetries,
      'failureAction': node.failureAction.name,
    });
  } else if (node is OpenDomeNode) {
    base.addAll({'shutterOnly': node.shutterOnly});
  } else if (node is CloseDomeNode) {
    base.addAll({'shutterOnly': node.shutterOnly});
  } else if (node is ParkDomeNode) {
    base.addAll({'shutterOnly': node.shutterOnly});
  } else if (node is PolarAlignmentNode) {
    base.addAll({
      'exposureDuration': node.exposureDuration,
      'binning': node.binning,
      'startAltitude': node.startAltitude,
      'rotationStep': node.rotationStep,
      'gain': node.gain,
      'offset': node.offset,
      'startFromCurrent': node.startFromCurrent,
      'isNorth': node.isNorth,
      'manualSlew': node.manualSlew,
    });
  }

  // Recursively serialize children if the node has any
  if (node.childIds.isNotEmpty) {
    final children = <Map<String, dynamic>>[];
    for (final childId in node.childIds) {
      final childNode = sequence.getNode(childId);
      if (childNode != null) {
        children.add(_serializeNode(childNode, sequence, fileService));
      }
    }
    if (children.isNotEmpty) {
      base['children'] = children;
    }
  }

  return base;
}

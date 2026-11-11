import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/sequence/template_snippet.dart';
import '../models/sequence/sequence_models.dart';
import '../services/sequence_file_service.dart';
import '../utils/skotiq_data_directory.dart';

final builtInSnippetsProvider = Provider<List<TemplateSnippet>>((ref) {
  return BuiltInSnippets.all;
});

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

  Future<void> addSnippet(TemplateSnippet snippet) async {
    // Ensure the snippet is not marked as built-in
    final snippetToAdd = snippet.isBuiltIn
        ? snippet.copyWith(isBuiltIn: false)
        : snippet;
    await _mutateAndSave(() => state = [...state, snippetToAdd]);
  }

  Future<void> removeSnippet(String id) async {
    await _mutateAndSave(() => state = state.where((s) => s.id != id).toList());
  }

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

      for (final category in grouped.keys) {
        grouped[category]!.sort((a, b) => a.name.compareTo(b.name));
      }

      return grouped;
    });

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

/// [node] and its subtree as snippet node data: the sequence-file node map
/// without tree identity, since an inserted snippet gets fresh ids, and with
/// the children nested under `children`.
Map<String, dynamic> _serializeNode(
  SequenceNode node,
  Sequence sequence,
  SequenceFileService fileService,
) {
  final children = [
    for (final childId in node.childIds)
      if (sequence.getNode(childId) case final child?)
        _serializeNode(child, sequence, fileService),
  ];
  return fileService.nodeToMap(node)
    ..remove('id')
    ..remove('parentId')
    ..remove('childIds')
    ..remove('orderIndex')
    ..addAll({if (children.isNotEmpty) 'children': children});
}

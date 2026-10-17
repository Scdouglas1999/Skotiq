import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/sequence/sequence_models.dart';
import 'sequence_file_service.dart';

/// Skill level classification for sample sequences.
enum SampleSequenceSkillLevel {
  beginner,
  intermediate,
  advanced;

  String get label {
    switch (this) {
      case SampleSequenceSkillLevel.beginner:
        return 'Beginner';
      case SampleSequenceSkillLevel.intermediate:
        return 'Intermediate';
      case SampleSequenceSkillLevel.advanced:
        return 'Advanced';
    }
  }
}

/// Bundled sample-sequence metadata + lazily-parsed [Sequence].
///
/// These templates ship with the app and are loaded from `rootBundle` at
/// runtime. They are READ-ONLY — the Library tab clones them (with fresh
/// UUIDs) before placing them in the user's working sequence so the
/// originals can be re-used indefinitely.
class SampleSequence {
  /// Stable identifier used by UI selection state. Not the per-clone Sequence id.
  final String id;

  /// Human-readable display name (matches the JSON `name` field).
  final String displayName;

  /// 2-3 sentence description (matches the JSON `description` field).
  final String description;

  /// Lucide icon name for the thumbnail tile.
  final String iconName;

  /// Beginner / Intermediate / Advanced.
  final SampleSequenceSkillLevel skillLevel;

  /// Human-readable expected total run time (e.g. "1 hr 15 min", "16 hr").
  ///
  /// A duration and nothing else — no "~3 min capture" qualifiers, so the
  /// column stays comparable at a glance.
  final String expectedTotalTime;

  /// Path of the JSON asset under the `skotiq_core` package's
  /// asset bundle.
  final String assetPath;

  /// Parsed template sequence. Lazily populated by [SampleSequenceService.load].
  /// The contained [Sequence] preserves the original IDs from the JSON file —
  /// callers must clone via [SampleSequenceService.cloneForUse] before applying.
  final Sequence template;

  const SampleSequence({
    required this.id,
    required this.displayName,
    required this.description,
    required this.iconName,
    required this.skillLevel,
    required this.expectedTotalTime,
    required this.assetPath,
    required this.template,
  });
}

/// Loads, parses, and clones the bundled sample sequences shipped under
/// `packages/skotiq_core/assets/sample_sequences/`.
///
/// The service exposes the curated [catalog] (id + metadata + asset path) and
/// a [load] method that reads + parses each asset into a real [Sequence] using
/// the same JSON deserializer the import/export flow uses
/// ([SequenceFileService]). This guarantees the sample JSONs round-trip
/// through the canonical schema and stay valid as the schema evolves.
class SampleSequenceService {
  SampleSequenceService();

  /// The bundled asset directory inside the `skotiq_core` package.
  ///
  /// When loading from the asset bundle, Flutter prefixes asset paths
  /// belonging to a package dependency with `packages/<package_name>/`.
  static const String _assetPrefix =
      'packages/skotiq_core/assets/sample_sequences';

  /// Metadata catalog for the five bundled samples. Order is the suggested
  /// display order in the Library tab (beginner -> advanced).
  static const List<_SampleSequenceEntry> _catalog = [
    _SampleSequenceEntry(
      id: 'dslr_m31_lrgb',
      iconName: 'camera',
      skillLevel: SampleSequenceSkillLevel.beginner,
      expectedTotalTime: '~1 hr 15 min',
      assetFileName: 'dslr_m31_lrgb.json',
    ),
    _SampleSequenceEntry(
      id: 'lunar_terminator',
      iconName: 'moon',
      skillLevel: SampleSequenceSkillLevel.beginner,
      expectedTotalTime: '~3 min',
      assetFileName: 'lunar_terminator.json',
    ),
    _SampleSequenceEntry(
      id: 'mono_lrgb_m51',
      iconName: 'aperture',
      skillLevel: SampleSequenceSkillLevel.intermediate,
      expectedTotalTime: '~3 hr 30 min',
      assetFileName: 'mono_lrgb_m51.json',
    ),
    _SampleSequenceEntry(
      id: 'planetary_jupiter',
      iconName: 'circle',
      skillLevel: SampleSequenceSkillLevel.intermediate,
      expectedTotalTime: '~10 min',
      assetFileName: 'planetary_jupiter.json',
    ),
    _SampleSequenceEntry(
      id: 'narrowband_ngc7000_sho',
      iconName: 'layers',
      skillLevel: SampleSequenceSkillLevel.advanced,
      expectedTotalTime: '~16 hr (multi-night)',
      assetFileName: 'narrowband_ngc7000_sho.json',
    ),
  ];

  Future<List<SampleSequence>>? _cachedLoad;

  /// Returns the parsed catalog of sample sequences. Results are cached
  /// per service instance — subsequent calls return the same list.
  ///
  /// Throws [FormatException] from [SequenceFileService] if any bundled
  /// JSON fails to parse. This is intentional: a malformed sample sequence
  /// is a shipping bug, not a recoverable runtime condition.
  Future<List<SampleSequence>> load() {
    return _cachedLoad ??= _loadAll();
  }

  Future<List<SampleSequence>> _loadAll() async {
    final results = <SampleSequence>[];
    for (final entry in _catalog) {
      results.add(await _loadOne(entry));
    }
    return results;
  }

  Future<SampleSequence> _loadOne(_SampleSequenceEntry entry) async {
    final assetPath = '$_assetPrefix/${entry.assetFileName}';
    final raw = await rootBundle.loadString(assetPath);

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Sample sequence asset "$assetPath" must be a JSON object, '
        'got ${decoded.runtimeType}',
      );
    }

    // Reuse the canonical sequence-file parser so the bundled samples go
    // through the same node-type switch as user-imported files. We use
    // [SequenceFileService.parseFromMap] (which skips the equipment-profile
    // filter-validation hook) because samples are catalog templates — the
    // user's active profile gets bound when they apply the template.
    final parser = SequenceFileService();
    final sequence = parser.parseFromMap(decoded);

    return SampleSequence(
      id: entry.id,
      displayName: sequence.name,
      description: sequence.description,
      iconName: entry.iconName,
      skillLevel: entry.skillLevel,
      expectedTotalTime: entry.expectedTotalTime,
      assetPath: assetPath,
      template: sequence,
    );
  }

  /// Clone a sample sequence template so it becomes a fresh, editable
  /// sequence ready to load into the current builder.
  ///
  /// Generates a new [Sequence] id, regenerates every node id (preserving
  /// the parent/child wiring via an id-mapping), unsets `isTemplate`, and
  /// updates `createdAt`/`modifiedAt` to now. The original template is
  /// not modified — this matches the "READ-ONLY" guarantee the audit calls
  /// for and lets the user apply the same sample multiple times without
  /// node-id collisions.
  Sequence cloneForUse(SampleSequence sample, {String? nameOverride}) {
    final template = sample.template;
    final newNodes = <String, SequenceNode>{};
    final idMapping = <String, String>{};

    for (final oldId in template.nodes.keys) {
      idMapping[oldId] = const Uuid().v4();
    }

    for (final entry in template.nodes.entries) {
      final oldNode = entry.value;
      final newId = idMapping[entry.key]!;
      final newParentId = oldNode.parentId != null
          ? idMapping[oldNode.parentId]
          : null;
      final newChildIds = oldNode.childIds
          .map((id) => idMapping[id] ?? id)
          .toList();

      newNodes[newId] = oldNode.copyWith(
        id: newId,
        parentId: newParentId,
        childIds: newChildIds,
      );
    }

    final newRootId = template.rootNodeId != null
        ? idMapping[template.rootNodeId]
        : null;

    return Sequence.create(
      name: nameOverride ?? template.name,
      description: template.description,
      nodes: newNodes,
      rootNodeId: newRootId,
      isTemplate: false,
    );
  }
}

/// Internal catalog row binding asset-file metadata to UI hints.
class _SampleSequenceEntry {
  final String id;
  final String iconName;
  final SampleSequenceSkillLevel skillLevel;
  final String expectedTotalTime;
  final String assetFileName;

  const _SampleSequenceEntry({
    required this.id,
    required this.iconName,
    required this.skillLevel,
    required this.expectedTotalTime,
    required this.assetFileName,
  });
}

/// Provider for the [SampleSequenceService] singleton.
final sampleSequenceServiceProvider = Provider<SampleSequenceService>((ref) {
  return SampleSequenceService();
});

/// Provider that loads the bundled sample sequences exactly once.
final sampleSequencesProvider = FutureProvider<List<SampleSequence>>((ref) {
  final service = ref.watch(sampleSequenceServiceProvider);
  return service.load();
});

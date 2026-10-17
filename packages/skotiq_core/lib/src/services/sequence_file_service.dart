import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/imaging/imaging_models.dart' show FrameType;
import '../models/notification/notification_categories.dart'
    show NotificationTransportKind;
import '../models/sequence/sequence_models.dart';
import '../providers/profiles_provider.dart';
import '../providers/sequence/sequence_editor_exceptions.dart';
import '../utils/export_target.dart';
import '../providers/sequence/sequence_validation.dart';
import '../providers/sequence_provider.dart' show currentSequenceProvider;
import '../providers/settings_provider.dart';
// Prefixed: settings_provider.dart also exports a legacy `HorizonProfile`;
// the in-sequence TargetSchedulerNode uses the scheduler samples-based one.
import 'scheduler/horizon_profile.dart' as sched_horizon;
import 'quality_stop_migration.dart';
import 'sequence_wire_codec.dart';

part 'sequence_file_service/sequence_encoder.dart';
part 'sequence_file_service/sequence_decoder.dart';

/// Service for saving and loading sequences to/from JSON files
typedef SequenceImportValidator = void Function(Sequence sequence);

/// Strategy invoked by [SequenceFileService.exportSequence] to run the
/// validator. The provider wiring at the bottom of this file binds this
/// to [validateSequence] (the pure structural pass). Tests can inject
/// a stub.
typedef ExportValidatorStrategy =
    List<ValidationIssue> Function(Sequence sequence);

class SequenceFileService {
  final SequenceImportValidator? _importValidator;
  final ExportValidatorStrategy _exportValidator;
  final void Function(Sequence sequence)? _onExportSaved;

  /// Default directory for export/import file pickers.
  ///
  /// Why: Settings → File Paths → Sequences exposes a "Sequences" folder so
  /// users can keep sequence JSON exports alongside the rest of their
  /// observatory documentation. Routing the file_selector dialogs at this
  /// directory makes the setting actually consequential
  /// Empty string means "let the
  /// platform pick the default location".
  final String _defaultDirectory;
  final String Function()? _defaultDirectoryProvider;

  SequenceFileService({
    SequenceImportValidator? importValidator,
    ExportValidatorStrategy? exportValidator,
    void Function(Sequence sequence)? onExportSaved,
    String defaultDirectory = '',
    String Function()? defaultDirectoryProvider,
  }) : _importValidator = importValidator,
       _exportValidator = exportValidator ?? validateSequence,
       _onExportSaved = onExportSaved,
       _defaultDirectory = defaultDirectory,
       _defaultDirectoryProvider = defaultDirectoryProvider;

  String? get _initialDirectoryOrNull {
    final directory = (_defaultDirectoryProvider?.call() ?? _defaultDirectory)
        .trim();
    return directory.isEmpty ? null : directory;
  }

  /// Serialize one node with the same exhaustive codec used by sequence files.
  ///
  /// Snippets and other partial-tree formats should build on this method
  /// instead of maintaining a second type switch that can omit newly-added
  /// fields or node types.
  Map<String, dynamic> nodeToMap(SequenceNode node) => _nodeToJson(node);

  /// Deserialize one node with the same exhaustive codec used by imports.
  SequenceNode nodeFromMap(Map<String, dynamic> json, {String? fallbackId}) {
    final node = _jsonToNode(json, fallbackId: fallbackId);
    final comment = json['comment'];
    return comment is String ? node.copyWith(comment: comment) : node;
  }

  /// Export a sequence to a JSON file.
  ///
  /// Before writing, runs [validateSequence] over [sequence] (or the
  /// override strategy supplied at construction). If the result contains
  /// any [ValidationSeverity.error]-level issues, throws
  /// [SequenceValidationFailedException] and does **not** open the save
  /// dialog or write the file. Warnings and info-level findings do not
  /// block export.
  ///
  /// Pass [forceExport] = `true` to bypass the gate (e.g. the user clicked
  /// "Export anyway" in the confirmation dialog). The validation pass still
  /// runs so callers can include the issue list in any audit log, but the
  /// failure is not raised as an exception.
  /// Returns the path written, or `null` when nothing was written. Dismissing
  /// the platform save dialog returns `null` so callers do not report a
  /// cancelled export as a successful save.
  ///
  /// The path is returned rather than a bare `true` because on Android/iOS the
  /// destination is inside the app sandbox — the caller has to hand it to the
  /// share sheet (see [ExportTarget.needsShareSheet]) or the user never gets
  /// the file. This service has no `BuildContext`, so it cannot do that itself.
  Future<String?> exportSequence(
    Sequence sequence, {
    bool forceExport = false,
  }) async {
    // Validate first — refusing to write a known-broken file is cheaper
    // than letting the user discover the corruption on re-import. Errors
    // are blocking unless the caller explicitly opted into [forceExport].
    final issues = _exportValidator(sequence);
    final hasErrors = issues.any((i) => i.severity == ValidationSeverity.error);
    if (hasErrors && !forceExport) {
      throw SequenceValidationFailedException(issues);
    }

    // Prepare JSON
    final json = sequenceToMap(sequence);
    final jsonString = const JsonEncoder.withIndent('  ').convert(json);

    // Save dialog on desktop; a sandbox path plus a share sheet on touch.
    final target = await chooseExportTarget(
      initialDirectory: _initialDirectoryOrNull,
      suggestedName: '${sequence.name}.skeq.json',
      acceptedTypeGroups: [
        const file_selector.XTypeGroup(
          label: 'Skotiq Sequence',
          // 'nseq' keeps pre-rename sequence files selectable.
          extensions: ['json', 'skeq', 'nseq'],
        ),
      ],
    );

    if (target == null) return null;

    // Write file
    final file = File(target.path);
    await file.writeAsString(jsonString);
    // Marking-saved is the caller's responsibility — the editor notifier
    // owns the dirty flag and we can't reach it from this stateless file-
    // service without a Ref. The provider wiring at the bottom of this
    // file injects an optional `onExportSaved` callback that the desktop
    // / mobile export buttons hook up to `markSaved()`.
    final cb = _onExportSaved;
    if (cb != null) cb(sequence);
    return target.path;
  }

  /// Import a sequence from a JSON file
  Future<Sequence?> importSequence() async {
    // Show open dialog
    final file = await file_selector.openFile(
      initialDirectory: _initialDirectoryOrNull,
      acceptedTypeGroups: [
        const file_selector.XTypeGroup(
          label: 'Skotiq Sequence',
          // 'nseq' keeps pre-rename sequence files selectable.
          extensions: ['json', 'skeq', 'nseq'],
        ),
      ],
    );

    if (file == null) return null;

    // Read and parse file
    final jsonString = await file.readAsString();
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      throw FormatException('Invalid JSON in sequence file: $e');
    }

    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Sequence file must contain a JSON object, got ${decoded.runtimeType}',
      );
    }

    _validateSequenceJson(decoded);

    // Read schema version and apply migrations if needed
    final migrated = _migrateSchema(decoded);

    final sequence = _jsonToSequence(migrated);
    _importValidator?.call(sequence);
    return sequence;
  }

  /// Read the schemaVersion from a sequence JSON and apply any needed migrations.
  /// Files without a schemaVersion are treated as version 0 (pre-versioning format).
  /// Returns the migrated JSON (may be the same object if no migration needed).
  Map<String, dynamic> _migrateSchema(Map<String, dynamic> json) {
    final rawVersion = json['schemaVersion'];
    final version = rawVersion is int ? rawVersion : 0;

    if (version > currentSchemaVersion) {
      throw FormatException(
        'Sequence file has schemaVersion $version, but this version of Skotiq '
        'only supports up to schemaVersion $currentSchemaVersion. '
        'Please update Skotiq to open this file.',
      );
    }

    // Apply migrations in order. Each case falls through to the next.
    // Add new migration cases here when incrementing currentSchemaVersion.
    //
    // Example for future migration:
    // if (version < 2) {
    //   // Migrate from v1 to v2: e.g., rename a field
    //   json['newFieldName'] = json.remove('oldFieldName');
    // }

    // Version 0 -> 1: No structural changes needed. Version 0 files
    // (pre-versioning) are compatible with version 1.

    // A file saved before 2026-10-06 has its quality stops moved to notices,
    // as the database migration to schema 61 did for saved sequences (owner
    // decision that day: only a risk to the hardware pauses or ends a run by
    // itself). Files written since carry [qualityStopsMovedKey], so a pause
    // the operator chose afterwards survives export and import. A marker
    // rather than a schema bump: older builds refuse a newer schemaVersion,
    // and a desktop and a phone on different builds share sequences.
    if (json[SequenceFileService.qualityStopsMovedKey] != true) {
      final nodes = json['nodes'];
      if (nodes is Map) {
        for (final node in nodes.values) {
          if (node is Map<String, dynamic>) {
            final nodeType = node['nodeType'];
            if (nodeType is String) {
              notifyInsteadOfQualityStops(nodeType, node);
            }
          }
        }
      }
      json[SequenceFileService.qualityStopsMovedKey] = true;
    }

    // Stamp the current version so re-exports are up to date
    json['schemaVersion'] = currentSchemaVersion;
    return json;
  }

  /// Validate that a sequence JSON object has the required fields and types
  /// before attempting to parse it. Throws [FormatException] on validation failure.
  void _validateSequenceJson(Map<String, dynamic> json) {
    // 'nodes' is required and must be a map
    if (!json.containsKey('nodes')) {
      throw const FormatException(
        'Sequence file missing required field "nodes"',
      );
    }
    if (json['nodes'] is! Map) {
      throw FormatException(
        'Sequence field "nodes" must be a JSON object, '
        'got ${json['nodes'].runtimeType}',
      );
    }

    // 'name' must be a string if present
    if (json.containsKey('name') && json['name'] is! String) {
      throw FormatException(
        'Sequence field "name" must be a string, got ${json['name'].runtimeType}',
      );
    }

    // 'rootNodeId' must be a string if present
    if (json.containsKey('rootNodeId') &&
        json['rootNodeId'] != null &&
        json['rootNodeId'] is! String) {
      throw FormatException(
        'Sequence field "rootNodeId" must be a string, '
        'got ${json['rootNodeId'].runtimeType}',
      );
    }

    // 'isTemplate' must be a bool if present
    if (json.containsKey('isTemplate') &&
        json['isTemplate'] != null &&
        json['isTemplate'] is! bool) {
      throw FormatException(
        'Sequence field "isTemplate" must be a boolean, '
        'got ${json['isTemplate'].runtimeType}',
      );
    }

    // Validate each node has a 'nodeType' string
    final nodesMap = (json['nodes'] as Map).cast<String, dynamic>();
    for (final entry in nodesMap.entries) {
      if (entry.value is! Map) {
        throw FormatException(
          'Sequence node "${entry.key}" must be a JSON object, '
          'got ${entry.value.runtimeType}',
        );
      }
      final nodeJson = (entry.value as Map).cast<String, dynamic>();
      if (!nodeJson.containsKey('nodeType') ||
          nodeJson['nodeType'] is! String ||
          (nodeJson['nodeType'] as String).trim().isEmpty) {
        throw FormatException(
          'Sequence node "${entry.key}" missing required string field "nodeType"',
        );
      }
    }
  }

  /// Encode [sequence] using the same schema written by [exportSequence],
  /// without opening a file picker.
  ///
  /// Smart Night draft persistence uses this so persisted draft plans and
  /// user-exported sequence files cannot diverge.
  Map<String, dynamic> sequenceToMap(Sequence sequence) {
    return _sequenceToJson(sequence);
  }

  /// Current schema version for exported sequences.
  /// Increment this when making breaking changes to the JSON format
  /// and add a migration case in [_migrateSchema].
  static const int currentSchemaVersion = 1;

  /// Top-level key every file written since 2026-10-06 carries: its quality
  /// stops were already moved to notices, so the importer leaves its actions
  /// alone. See [notifyInsteadOfQualityStops].
  static const String qualityStopsMovedKey = 'qualityStopsMovedToNotify';

  /// Parse a pre-decoded sequence JSON map (no file I/O, no migration).
  /// Used by [SampleSequenceService] to decode bundled assets through the
  /// same node-type switch the file-picker importer uses, so the on-disk
  /// schema stays the single source of truth.
  ///
  /// Callers are expected to supply a map that already conforms to the
  /// current schema version. Validation is identical to the file importer
  /// (missing `nodes` / bad `nodeType` throws [FormatException]) but the
  /// import-validator callback is NOT invoked — that hook is reserved for
  /// user-imported files and shouldn't run on bundled templates.
  Sequence parseFromMap(Map<String, dynamic> json) {
    _validateSequenceJson(json);
    final migrated = _migrateSchema(json);
    return _jsonToSequence(migrated);
  }
}

BrightnessTierPreferences _parseBrightnessTierPreferences(Object? value) {
  if (value is Map) {
    return BrightnessTierPreferences.fromJson(value.cast<String, dynamic>());
  }
  return const BrightnessTierPreferences();
}

/// Provider for the sequence file service
final sequenceFileServiceProvider = Provider<SequenceFileService>((ref) {
  return SequenceFileService(
    // Read at dialog-open time so changing Settings → File Paths → Sequences
    // takes effect immediately without rebuilding every service dependent.
    defaultDirectoryProvider: () {
      try {
        return ref.read(appSettingsProvider).valueOrNull?.sequencesPath ?? '';
      } catch (_) {
        // Unit tests may construct the service without a settings database.
        return '';
      }
    },
    onExportSaved: (exported) {
      // Reach into the sequence editor and clear the dirty flag. The
      // export wrote the canonical bytes for the in-memory sequence, so
      // any subsequent createSequence/loadSequence should no longer
      // prompt "discard unsaved changes?" — the user just saved.
      //
      // Read (not watch) — this is a one-shot side effect inside an
      // async write path, not a reactive subscription.
      try {
        final editor = ref.read(currentSequenceProvider.notifier);
        editor.markSavedIfCurrent(exported);
      } catch (_) {
        // Tests may construct this provider without the sequence
        // notifier. Failing silent is acceptable here because the
        // editor is the only place that cares about the flag — a missing
        // notifier means there's no editor to dirty.
      }
    },
    importValidator: (sequence) {
      final activeProfile = ref.read(activeEquipmentProfileProvider);
      final availableFilters =
          activeProfile?.filterNames.toSet() ?? const <String>{};
      final referencedFilters = <String>{};

      for (final node in sequence.nodes.values) {
        if (node is ExposureNode &&
            node.filter != null &&
            node.filter!.isNotEmpty) {
          referencedFilters.add(node.filter!);
        } else if (node is FilterChangeNode && node.filterName.isNotEmpty) {
          referencedFilters.add(node.filterName);
        }
      }

      if (referencedFilters.isEmpty) {
        return;
      }

      if (availableFilters.isEmpty) {
        throw FormatException(
          'Sequence import requires an active equipment profile with filters configured. '
          'Referenced filters: ${referencedFilters.toList()..sort()}',
        );
      }

      final missingFilters = referencedFilters.difference(availableFilters);
      if (missingFilters.isNotEmpty) {
        final missing = missingFilters.toList()..sort();
        throw FormatException(
          'Sequence references filters not present in the active equipment profile: $missing',
        );
      }
    },
  );
});

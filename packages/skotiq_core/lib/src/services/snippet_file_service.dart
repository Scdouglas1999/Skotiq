import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/sequence/template_snippet.dart';
import '../providers/settings_provider.dart';
import '../utils/export_target.dart';

/// File extension Skotiq writes for shared / exported snippet bundles.
///
/// Mirrors the `.nseq.json` convention from [SequenceFileService] — the
/// trailing `.json` keeps the file recognisably JSON in plain-text editors
/// and lets the OS pick a sensible icon on platforms that key off the
/// final extension. The `.nsnippet` segment is what distinguishes a
/// snippet bundle from a full sequence file.
const String snippetFileExtension = 'nsnippet.json';

/// Schema-version constant for snippet bundles produced by
/// [SnippetFileService.exportSnippet]. Bump and add a migration in
/// [_migrateSchema] when changing the on-disk shape.
const int snippetFileCurrentSchemaVersion = 1;

/// Wire-format `kind` discriminator. The importer refuses to parse a
/// file whose `kind` does not match this exact string so a misplaced
/// `.nseq.json` (full sequence) cannot be silently loaded as a snippet.
const String snippetFileKind = 'skotiq.snippet';

/// Issue surfaced by [SnippetImportException].
///
/// Each entry maps to a single concrete problem with the imported file
/// (missing field, wrong type, checksum mismatch, etc.). The UI lists
/// every issue together rather than aborting on the first failure so
/// the user can fix the file in one editing pass.
class SnippetImportIssue {
  const SnippetImportIssue({required this.field, required this.message});

  /// JSON-path-style field the issue applies to (e.g. `name`,
  /// `nodeData[0].nodeType`, `checksum`). Empty string for file-level
  /// issues (top-level not-an-object, invalid JSON, etc.).
  final String field;

  /// Human-readable description of the problem suitable for display in
  /// a per-issue list.
  final String message;

  @override
  String toString() => field.isEmpty ? message : '$field: $message';
}

/// Thrown by [SnippetFileService.importSnippet] when the file cannot be
/// loaded. Carries the full issue list so the UI can render every problem at
/// once, like the sequence importer.
class SnippetImportException implements Exception {
  SnippetImportException(this.issues) : assert(issues.isNotEmpty);

  final List<SnippetImportIssue> issues;

  @override
  String toString() {
    final lines = issues.map((i) => '  - $i').join('\n');
    return 'Snippet file has ${issues.length} '
        'issue${issues.length == 1 ? '' : 's'}:\n$lines';
  }
}

/// Thrown by [SnippetFileService.importSnippet] when the file's
/// `schemaVersion` is newer than this build supports. Separated from
/// [SnippetImportException] so the UI can suggest "update Skotiq"
/// instead of "fix the file".
class SnippetVersionMismatchException implements Exception {
  SnippetVersionMismatchException({
    required this.fileVersion,
    required this.supportedVersion,
  });

  final int fileVersion;
  final int supportedVersion;

  @override
  String toString() =>
      'Snippet file has schemaVersion $fileVersion, but this build of '
      'Skotiq only supports up to schemaVersion $supportedVersion. '
      'Please update Skotiq to open this file.';
}

/// Service for sharing custom snippets between machines / users by
/// reading and writing self-contained `.nsnippet.json` bundles.
///
/// Sits beside [SequenceFileService] on purpose — they're sibling
/// concepts (one writes a whole sequence, the other writes a reusable
/// sub-graph) and share the same file-picker library + naming
/// convention. The snippet model itself (the in-memory shape consumed
/// by [CustomSnippetsNotifier]) lives in `template_snippet.dart` and
/// is **not** redesigned by this service: this code only adds an
/// envelope around `TemplateSnippet.toJson()` for transport.
class SnippetFileService {
  /// Default directory hint passed to the file picker. Empty string
  /// means "let the platform pick".
  final String _defaultDirectory;

  SnippetFileService({String defaultDirectory = ''})
    : _defaultDirectory = defaultDirectory;

  String? get _initialDirectoryOrNull =>
      _defaultDirectory.isEmpty ? null : _defaultDirectory;

  /// Encode [snippet] to the canonical on-disk JSON envelope, including
  /// a SHA-256 checksum over the encoded body.
  ///
  /// Exposed for tests and for in-process "save to a known path" call
  /// sites (e.g. the share workflow which needs a file handle without
  /// the user picking a location). [exportSnippet] is the public API.
  String encodeSnippet(TemplateSnippet snippet) {
    final body = _buildBody(snippet);
    final checksum = _checksumOf(body);
    final envelope = <String, dynamic>{...body, 'checksum': checksum};
    return const JsonEncoder.withIndent('  ').convert(envelope);
  }

  /// Suggest a filesystem-safe filename for [snippet].
  ///
  /// Strips characters Windows / macOS / Linux reject in filenames and
  /// collapses whitespace runs to single underscores. The returned name
  /// already includes the `.nsnippet.json` extension.
  String suggestedFilename(TemplateSnippet snippet) {
    final cleaned = snippet.name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    final base = cleaned.isEmpty ? 'snippet' : cleaned;
    return '$base.$snippetFileExtension';
  }

  /// Write [snippet] to the platform's export destination.
  ///
  /// Returns the destination path on success, or `null` if the user
  /// cancelled the dialog. The file content is identical to what
  /// [encodeSnippet] returns.
  ///
  /// The destination comes from [chooseExportTarget], not a bare save dialog:
  /// `file_selector` has no `getSavePath` on Android/iOS, so asking for one
  /// threw UnimplementedError and snippet export was dead on a phone. There the
  /// path is inside the app sandbox, so the caller must hand it to the share
  /// sheet (`revealExportedFile`) — this service has no `BuildContext` and
  /// cannot do that itself, which is why the path is returned.
  Future<String?> exportSnippet(TemplateSnippet snippet) async {
    final jsonString = encodeSnippet(snippet);

    final target = await chooseExportTarget(
      initialDirectory: _initialDirectoryOrNull,
      suggestedName: suggestedFilename(snippet),
      acceptedTypeGroups: [
        const file_selector.XTypeGroup(
          label: 'Skotiq Snippet',
          extensions: ['nsnippet.json', 'json'],
        ),
      ],
    );

    if (target == null) return null;

    final file = File(target.path);
    await file.writeAsString(jsonString);
    return target.path;
  }

  /// Write [snippet] to [path]. Used by the share workflow which needs
  /// a file handle on disk before invoking the platform share sheet.
  ///
  /// Overwrites the file if it exists. The parent directory must
  /// already exist — this method does not create it (callers using a
  /// temp dir always have it).
  Future<void> exportSnippetToPath(TemplateSnippet snippet, String path) async {
    final jsonString = encodeSnippet(snippet);
    await File(path).writeAsString(jsonString);
  }

  /// Open the platform file picker, parse the chosen file, and return
  /// the snippet ready to add to the user's library.
  ///
  /// Returns `null` if the user cancelled the dialog. Throws
  /// [SnippetVersionMismatchException] when the file's schemaVersion
  /// is newer than this build supports, or [SnippetImportException]
  /// with the full issue list when the file fails schema validation
  /// (including checksum mismatch).
  ///
  /// Always assigns a fresh [TemplateSnippet.id] so importing the same
  /// file twice produces two distinct library entries — matches the
  /// behaviour of [SequenceFileService.importSequence] which generates
  /// a new sequence UUID on import.
  Future<TemplateSnippet?> importSnippet() async {
    final picked = await file_selector.openFile(
      initialDirectory: _initialDirectoryOrNull,
      acceptedTypeGroups: [
        const file_selector.XTypeGroup(
          label: 'Skotiq Snippet',
          extensions: ['nsnippet.json', 'json'],
        ),
      ],
    );

    if (picked == null) return null;

    final raw = await picked.readAsString();
    return parseEncoded(raw);
  }

  /// Parse a pre-loaded snippet JSON string. Useful for tests and for
  /// loading snippets from sources other than the file picker (e.g. a
  /// future plugin gallery). Same exception contract as [importSnippet].
  TemplateSnippet parseEncoded(String jsonString) {
    final issues = <SnippetImportIssue>[];

    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      throw SnippetImportException([
        SnippetImportIssue(field: '', message: 'Invalid JSON: $e'),
      ]);
    }

    if (decoded is! Map<String, dynamic>) {
      throw SnippetImportException([
        SnippetImportIssue(
          field: '',
          message:
              'Snippet file must contain a JSON object at the top level, '
              'got ${decoded.runtimeType}',
        ),
      ]);
    }

    final rawVersion = decoded['schemaVersion'];
    final version = rawVersion is int ? rawVersion : 0;
    if (version > snippetFileCurrentSchemaVersion) {
      throw SnippetVersionMismatchException(
        fileVersion: version,
        supportedVersion: snippetFileCurrentSchemaVersion,
      );
    }

    final kind = decoded['kind'];
    if (kind != snippetFileKind) {
      issues.add(
        SnippetImportIssue(
          field: 'kind',
          message:
              'Expected "$snippetFileKind", got "$kind". '
              'This may be a Skotiq sequence file (.nseq.json) — '
              'open it from the sequence editor instead.',
        ),
      );
    }

    _validateString(decoded, 'name', issues);
    _validateString(decoded, 'description', issues, allowEmpty: true);
    _validateString(decoded, 'iconName', issues);
    _validateString(decoded, 'category', issues);
    _validateString(decoded, 'createdAt', issues);
    _validateChecksum(decoded, issues);
    _validateNodeData(decoded, issues);

    if (issues.isNotEmpty) {
      throw SnippetImportException(issues);
    }

    final migrated = _migrateSchema(decoded);
    return _bodyToSnippet(migrated);
  }

  // Internals

  /// Build the "body" — everything that goes into the checksum — for
  /// [snippet]. Excludes the checksum field itself so encoding and
  /// verification operate on identical input.
  Map<String, dynamic> _buildBody(TemplateSnippet snippet) {
    return <String, dynamic>{
      'schemaVersion': snippetFileCurrentSchemaVersion,
      'kind': snippetFileKind,
      'name': snippet.name,
      'description': snippet.description,
      'category': snippet.category.name,
      'iconName': snippet.iconName,
      'nodeData': snippet.nodeData,
      'createdAt': snippet.createdAt.toIso8601String(),
    };
  }

  /// SHA-256 hex digest over the canonically-encoded [body] map.
  ///
  /// Canonical encoding == `jsonEncode` with no whitespace. Dart's
  /// `jsonEncode` is deterministic for `Map<String, dynamic>` because it
  /// preserves insertion order, and [_buildBody] uses a fixed key order
  /// — so this digest is stable across runs as long as the body
  /// construction order doesn't change.
  String _checksumOf(Map<String, dynamic> body) {
    final bytes = utf8.encode(jsonEncode(body));
    return sha256.convert(bytes).toString();
  }

  void _validateString(
    Map<String, dynamic> json,
    String field,
    List<SnippetImportIssue> issues, {
    bool allowEmpty = false,
  }) {
    final value = json[field];
    if (value == null) {
      issues.add(
        SnippetImportIssue(field: field, message: 'Required field is missing'),
      );
      return;
    }
    if (value is! String) {
      issues.add(
        SnippetImportIssue(
          field: field,
          message: 'Expected string, got ${value.runtimeType}',
        ),
      );
      return;
    }
    if (!allowEmpty && value.trim().isEmpty) {
      issues.add(
        SnippetImportIssue(field: field, message: 'Field must not be empty'),
      );
    }
  }

  void _validateChecksum(
    Map<String, dynamic> json,
    List<SnippetImportIssue> issues,
  ) {
    final claimed = json['checksum'];
    if (claimed == null) {
      issues.add(
        const SnippetImportIssue(
          field: 'checksum',
          message: 'Required field is missing',
        ),
      );
      return;
    }
    if (claimed is! String) {
      issues.add(
        SnippetImportIssue(
          field: 'checksum',
          message: 'Expected string, got ${claimed.runtimeType}',
        ),
      );
      return;
    }
    final body = Map<String, dynamic>.from(json)..remove('checksum');
    final computed = _checksumOf(body);
    if (computed != claimed) {
      issues.add(
        SnippetImportIssue(
          field: 'checksum',
          message:
              'Checksum mismatch (file may have been edited or corrupted). '
              'Expected $computed, got $claimed',
        ),
      );
    }
  }

  void _validateNodeData(
    Map<String, dynamic> json,
    List<SnippetImportIssue> issues,
  ) {
    final raw = json['nodeData'];
    if (raw == null) {
      issues.add(
        const SnippetImportIssue(
          field: 'nodeData',
          message: 'Required field is missing',
        ),
      );
      return;
    }
    if (raw is! List) {
      issues.add(
        SnippetImportIssue(
          field: 'nodeData',
          message: 'Expected array, got ${raw.runtimeType}',
        ),
      );
      return;
    }
    if (raw.isEmpty) {
      issues.add(
        const SnippetImportIssue(
          field: 'nodeData',
          message: 'Snippet contains no nodes',
        ),
      );
      return;
    }
    for (var i = 0; i < raw.length; i++) {
      final node = raw[i];
      if (node is! Map) {
        issues.add(
          SnippetImportIssue(
            field: 'nodeData[$i]',
            message: 'Each node must be a JSON object, got ${node.runtimeType}',
          ),
        );
        continue;
      }
      final nodeType = node['nodeType'];
      if (nodeType is! String || nodeType.trim().isEmpty) {
        issues.add(
          SnippetImportIssue(
            field: 'nodeData[$i].nodeType',
            message: 'Each node must have a non-empty "nodeType" string',
          ),
        );
      }
    }
  }

  /// Apply version migrations to bring [json] up to the current schema.
  ///
  /// Today there is only one snippet schema version. New migrations
  /// should be added as cascading `if (version < N) { ... }` blocks so
  /// older files transparently upgrade in-memory on import.
  Map<String, dynamic> _migrateSchema(Map<String, dynamic> json) {
    final rawVersion = json['schemaVersion'];
    final version = rawVersion is int ? rawVersion : 0;
    // Version 0 -> 1: no structural change. Files saved before
    // versioning had no schemaVersion field and are compatible with v1.
    if (version < 1) {
      json['schemaVersion'] = 1;
    }
    return json;
  }

  /// Convert the validated, migrated body into an in-memory snippet
  /// with a fresh ID. Preserves `nodeData` verbatim — re-validation of
  /// individual node types happens at insertion time by the sequence
  /// editor (which throws [SnippetDeserializationException] for
  /// unknown nodeType discriminators).
  TemplateSnippet _bodyToSnippet(Map<String, dynamic> json) {
    final categoryName = json['category'] as String;
    final category = SnippetCategory.values.firstWhere(
      (c) => c.name == categoryName,
      orElse: () => SnippetCategory.custom,
    );

    final nodeDataRaw = json['nodeData'] as List<dynamic>;
    final nodeData = nodeDataRaw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    final createdAtRaw = json['createdAt'] as String;
    final createdAt = DateTime.tryParse(createdAtRaw) ?? DateTime.now();

    return TemplateSnippet(
      // Fresh id on import — re-importing the same file gives a new
      // library entry rather than silently overwriting.
      id: const Uuid().v4(),
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      category: category,
      iconName: json['iconName'] as String,
      nodeData: nodeData,
      // Always false — built-in snippets are not user-importable, so
      // the importer must never produce one (matches the guard in
      // [CustomSnippetsNotifier.addSnippet]).
      isBuiltIn: false,
      createdAt: createdAt,
    );
  }
}

/// Provider for the snippet file service.
///
/// Resolves the default directory from `Settings → File Paths →
/// Sequences` so snippet exports/imports land beside sequence files by
/// default. Falls back to the OS-picked default when settings are
/// unavailable (e.g. in unit tests with no database).
final snippetFileServiceProvider = Provider<SnippetFileService>((ref) {
  String defaultDir = '';
  try {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    defaultDir = settings?.sequencesPath ?? '';
  } catch (_) {
    defaultDir = '';
  }
  return SnippetFileService(defaultDirectory: defaultDir);
});

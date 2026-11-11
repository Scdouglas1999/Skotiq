part of '../network_backend.dart';

/// Wire row for `/api/db/notes` — the operator's per-target / per-run
/// journal notes (the `notes_journal` table). Mirrors `JournalNote.toJson`
/// the host serializes. Tolerant defaults so a malformed/partial row never
/// blanks the whole notes panel.
class RemoteJournalNote {
  final String id;
  final String targetId;
  final int? sequenceRunId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? title;
  final String body;
  final List<String> tags;
  final List<String> attachments;
  final String? sentiment;

  const RemoteJournalNote({
    required this.id,
    required this.targetId,
    required this.createdAt,
    required this.updatedAt,
    required this.body,
    this.sequenceRunId,
    this.title,
    this.tags = const [],
    this.attachments = const [],
    this.sentiment,
  });

  factory RemoteJournalNote.fromJson(Map<String, dynamic> json) {
    return RemoteJournalNote(
      id: json['id'] as String? ?? '',
      targetId: json['targetId'] as String? ?? '',
      sequenceRunId: (json['sequenceRunId'] as num?)?.toInt(),
      createdAt:
          _parseDateField(json['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          _parseDateField(json['updatedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      title: json['title'] as String?,
      body: json['body'] as String? ?? '',
      tags: _stringList(json['tags']),
      attachments: _stringList(json['attachments']),
      sentiment: json['sentiment'] as String?,
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is List) {
      return raw.whereType<String>().toList(growable: false);
    }
    return const <String>[];
  }
}

// Wire types for the plugin management endpoints.

/// Wire row for `/api/plugins`.
///
/// New hosts report the live, compiled-in plugin runtime. Older hosts may
/// return archive-registry rows, so [source], [runtimeLoaded], and [canEnable]
/// let clients distinguish an executable plugin from a stored artifact.
class RemotePluginManifest {
  final String id;
  final String name;
  final String version;
  final String? description;
  final String? author;
  final bool enabled;
  final bool signed;
  final bool signatureValid;
  final String? sha256;
  final int? sizeBytes;
  final DateTime? installedAt;
  final String? installedFilename;
  final String? loadError;
  final String source;
  final bool runtimeLoaded;
  final bool canEnable;

  const RemotePluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.enabled,
    required this.signed,
    required this.signatureValid,
    this.description,
    this.author,
    this.sha256,
    this.sizeBytes,
    this.installedAt,
    this.installedFilename,
    this.loadError,
    this.source = 'uploadedArchive',
    this.runtimeLoaded = false,
    this.canEnable = false,
  });

  factory RemotePluginManifest.fromJson(Map<String, dynamic> json) {
    return RemotePluginManifest(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      description: json['description'] as String?,
      author: json['author'] as String?,
      enabled: json['enabled'] as bool? ?? false,
      signed: json['signed'] as bool? ?? false,
      signatureValid: json['signatureValid'] as bool? ?? false,
      sha256: json['sha256'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      installedAt: _parseDateField(json['installedAt']),
      installedFilename: json['installedFilename'] as String?,
      loadError: json['loadError'] as String?,
      source: json['source'] as String? ?? 'uploadedArchive',
      runtimeLoaded: json['runtimeLoaded'] as bool? ?? false,
      canEnable: json['canEnable'] as bool? ?? false,
    );
  }
}

Future<List<int>> consolidateHttpClientResponseBytes(
  HttpClientResponse response,
) {
  final completer = Completer<List<int>>();
  final chunks = <List<int>>[];

  response.listen(
    (chunk) => chunks.add(chunk),
    onDone: () => completer.complete(chunks.expand((x) => x).toList()),
    onError: completer.completeError,
    cancelOnError: true,
  );

  return completer.future;
}

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

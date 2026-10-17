import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// One row in the Backup & Restore list, portable across the local backend
/// (files on disk) and a remote headless host (`/api/backup/list`).
///
/// The [id] is the only field safe to use as an action target: for a remote
/// host it is the stable, process-independent backup id the host derives from
/// the filename (see the desktop `BackupHandlers._idForBackupFile`); for a
/// local file it is a path-derived key. [filePath] is retained for the local
/// restore path and for backward compatibility with older hosts, but a remote
/// restore/delete/download always addresses the backup by [id] so no absolute
/// server path crosses the wire.
@immutable
class BackupListEntry {
  final String id;
  final String filePath;
  final String fileName;
  final DateTime createdAt;
  final int fileSize;

  const BackupListEntry({
    required this.id,
    required this.filePath,
    required this.fileName,
    required this.createdAt,
    required this.fileSize,
  });

  static Future<BackupListEntry> fromLocalFile(File file) async {
    final stat = await file.stat();
    return BackupListEntry(
      id: file.path.hashCode.toString(),
      filePath: file.path,
      fileName: file.uri.pathSegments.last,
      createdAt: stat.modified,
      fileSize: stat.size,
    );
  }

  /// Parse a single `/api/backup/list` row, returning null when it lacks a
  /// stable non-empty `id`. A row with no id cannot be safely restored,
  /// deleted, or downloaded and would otherwise render an action that targets
  /// the wrong backup on the host, so it is dropped (fail closed).
  static BackupListEntry? tryFromRemote(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;

    final rawName = json['fileName'];
    final fileName =
        rawName is String && rawName.trim().isNotEmpty ? rawName : 'Backup';
    final createdAtMs = json['createdAt'];
    final fileSize = json['fileSize'];
    final filePath = json['filePath'];

    return BackupListEntry(
      id: id,
      filePath: filePath is String ? filePath : '',
      fileName: fileName,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdAtMs is int ? createdAtMs : 0,
      ),
      fileSize: fileSize is int ? fileSize : 0,
    );
  }
}

/// Parse `/api/backup/list` rows into actionable entries, dropping any
/// malformed row (missing/empty `id`) so a row can never render an action that
/// targets the wrong backup on the host. Fail closed rather than surfacing a
/// row whose delete/restore/download would resolve to nothing (or worse, the
/// wrong file).
List<BackupListEntry> parseRemoteBackupList(List<Map<String, dynamic>> rows) {
  final entries = <BackupListEntry>[];
  for (final row in rows) {
    final entry = BackupListEntry.tryFromRemote(row);
    if (entry != null) entries.add(entry);
  }
  return entries;
}

/// Stable identity of a backend, used to reject a slow list result or a row
/// action after the user has switched host or mode mid-flight. Remote backends
/// key on `host:port` (a reconnect to a different rig yields a different token);
/// every non-network backend shares the `local` token. A row loaded against
/// one token must never dispatch its action against a different one — that is
/// how an old row would otherwise target the current host.
String backendBackupToken(SkotiqBackend backend) => backend is NetworkBackend
    ? 'remote:${identityHashCode(backend)}:'
        '${backend.serverHost}:${backend.serverPort}'
    : 'local:${identityHashCode(backend)}';

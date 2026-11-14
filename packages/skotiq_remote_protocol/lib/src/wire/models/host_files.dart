/// Files and folders on the host: the folders a client may pick
/// (`GET /api/files/browse`) and the log files it may download
/// (`GET /api/logs`).
library;

import '../wire_time.dart';

/// One folder: its display [name] and the host [path] to send back.
class RemoteDirectoryEntry {
  final String name;
  final String path;

  const RemoteDirectoryEntry({required this.name, required this.path});

  factory RemoteDirectoryEntry.fromJson(Map<String, dynamic> json) {
    // Tolerate a non-string name/path (older/buggy host, truncated frame)
    // rather than throwing on the `as String` cast — a malformed entry must
    // not abort the whole listing parse.
    return RemoteDirectoryEntry(
      name: json['name'] is String ? json['name'] as String : '',
      path: json['path'] is String ? json['path'] as String : '',
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'path': path};
}

class RemoteDirectoryListing {
  final String? currentPath;
  final String? parentPath;
  final List<RemoteDirectoryEntry> directories;

  const RemoteDirectoryListing({
    required this.currentPath,
    required this.parentPath,
    required this.directories,
  });

  factory RemoteDirectoryListing.fromJson(Map<String, dynamic> json) {
    // Parse defensively: skip entries that are not JSON objects (a lazy
    // `.cast<Map<String, dynamic>>()` would instead throw at iteration time
    // on the first bad element and drop the entire browse response). Non-list
    // `directories`, a numeric `currentPath`, etc. degrade to empty/null so a
    // partially-malformed frame still renders the well-formed folders. Root
    // listings legitimately carry a null `currentPath`/`parentPath`.
    final rawDirectories = json['directories'];
    final directories = <RemoteDirectoryEntry>[];
    if (rawDirectories is List) {
      for (final entry in rawDirectories) {
        if (entry is Map) {
          final name = entry['name'];
          final path = entry['path'];
          if (name is! String || path is! String || path.trim().isEmpty) {
            continue;
          }
          directories.add(
            RemoteDirectoryEntry(
              name: name.trim().isEmpty ? path : name,
              path: path,
            ),
          );
        }
      }
    }
    return RemoteDirectoryListing(
      currentPath: json['currentPath'] is String
          ? json['currentPath'] as String
          : null,
      parentPath: json['parentPath'] is String
          ? json['parentPath'] as String
          : null,
      directories: directories,
    );
  }

  Map<String, dynamic> toJson() => {
    'currentPath': currentPath,
    'parentPath': parentPath,
    'directories': [for (final entry in directories) entry.toJson()],
  };
}

/// Wire shape for one entry of `GET /api/logs` — an on-disk log file the
/// host is willing to stream via `GET /api/logs/files/<name>/download`.
///
/// `modifiedAt` is null when the host sent a malformed timestamp; the
/// listing still renders.
class RemoteLogFileInfo {
  final String name;
  final int sizeBytes;
  final DateTime? modifiedAt;

  /// True for the file the daily-rolling appender is currently writing.
  final bool isCurrent;

  const RemoteLogFileInfo({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.isCurrent,
  });

  factory RemoteLogFileInfo.fromJson(Map<String, dynamic> json) {
    return RemoteLogFileInfo(
      name: json['name'] is String ? json['name'] as String : '',
      sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : 0,
      modifiedAt: json['modifiedAt'] is String
          ? tryParseWireTime(json['modifiedAt'] as String)
          : null,
      isCurrent: json['isCurrent'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'sizeBytes': sizeBytes,
    'modifiedAt': modifiedAt?.toWireTime(),
    'isCurrent': isCurrent,
  };
}

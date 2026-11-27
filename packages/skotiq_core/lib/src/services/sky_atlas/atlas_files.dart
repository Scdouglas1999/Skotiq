import 'dart:io';

import 'package:path/path.dart' as p;

/// The file names the atlas sidecars use on disk, matching the Rust engine
/// (`imaging/src/sky_atlas.rs`): a sidecar is `<stem>.skt`, and atlases from
/// before the rename may still hold `<stem>.nst`, which stays readable.
const String atlasSidecarExtension = '.skt';
const String legacyAtlasSidecarExtension = '.nst';

/// The current name of the sidecar [stem] in [dir].
String atlasSidecarPath(String dir, String stem) =>
    p.join(dir, '$stem$atlasSidecarExtension');

/// Both names the sidecar [stem] may have in [dir], current first.
List<String> atlasSidecarPaths(String dir, String stem) => [
  atlasSidecarPath(dir, stem),
  p.join(dir, '$stem$legacyAtlasSidecarExtension'),
];

/// The sidecar [stem] in [dir] that exists, current name first, or the
/// current name when neither exists.
String existingAtlasSidecarPath(String dir, String stem) {
  final paths = atlasSidecarPaths(dir, stem);
  return paths.firstWhere(
    (path) => File(path).existsSync(),
    orElse: () => paths.first,
  );
}

/// Whether [path] carries either sidecar extension (any case).
bool isAtlasSidecar(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext == atlasSidecarExtension || ext == legacyAtlasSidecarExtension;
}

/// One file a cache sweep may evict.
typedef EvictionCandidate = ({File file, DateTime modified, int size});

/// What an [evictAgedThenOldest] pass removed.
typedef EvictionResult = ({int deleted, int reclaimedBytes});

/// The cache-sweep rule both atlas caches share: delete every candidate
/// modified before [cutoff]; then, when [maxBytes] is set and the rest still
/// exceed it, delete the oldest until they fit. [delete] removes one file and
/// reports whether it did; a file it could not remove still counts toward the
/// remaining bytes.
Future<EvictionResult> evictAgedThenOldest(
  List<EvictionCandidate> candidates, {
  required DateTime cutoff,
  required int? maxBytes,
  required Future<bool> Function(File file) delete,
}) async {
  var deleted = 0;
  var reclaimedBytes = 0;
  final survivors = <EvictionCandidate>[];

  for (final entry in candidates) {
    if (entry.modified.isBefore(cutoff)) {
      if (await delete(entry.file)) {
        deleted++;
        reclaimedBytes += entry.size;
      }
    } else {
      survivors.add(entry);
    }
  }

  if (maxBytes != null) {
    var remainingBytes = survivors.fold<int>(0, (s, e) => s + e.size);
    if (remainingBytes > maxBytes) {
      survivors.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in survivors) {
        if (remainingBytes <= maxBytes) break;
        if (await delete(entry.file)) {
          deleted++;
          reclaimedBytes += entry.size;
          remainingBytes -= entry.size;
        }
      }
    }
  }
  return (deleted: deleted, reclaimedBytes: reclaimedBytes);
}

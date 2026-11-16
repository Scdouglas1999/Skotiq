import 'package:skotiq_astro/format.dart';

/// Snapshot of disk-space usage for a single directory.
///
/// All sizes are in bytes. [path] is the directory that was queried; on
/// Windows this is the drive root (e.g. `C:\`) the path lives on, because
/// `Get-PSDrive` reports per-volume free space. On Unix the path is whatever
/// `df` resolved to (typically the mount-point of the filesystem holding the
/// directory).
class DiskSpaceInfo {
  final String path;
  final int totalBytes;
  final int freeBytes;
  final DateTime sampledAt;

  const DiskSpaceInfo({
    required this.path,
    required this.totalBytes,
    required this.freeBytes,
    required this.sampledAt,
  });

  int get usedBytes => totalBytes - freeBytes;

  double get freeFraction => totalBytes > 0 ? freeBytes / totalBytes : 0.0;

  @override
  String toString() =>
      'DiskSpaceInfo(path=$path, free=${ByteFormat.size(freeBytes)}, total=${ByteFormat.size(totalBytes)})';
}

/// Thrown when the disk-space query fails. No fallback value is substituted:
/// capture sessions depend on this number being accurate, and a substituted
/// one hides misconfiguration such as a capture path on a disconnected drive.
class DiskSpaceException implements Exception {
  final String path;
  final String message;
  final Object? cause;

  /// Which failure this is, so the UI can say something useful instead of
  /// "Disk query failed".
  ///
  /// Callers match on [kind], never on [message], so the copy stays free to
  /// change: "the drive is gone" is actionable on a rig left running
  /// overnight, "disk query failed" is not.
  final DiskSpaceFailureKind kind;

  const DiskSpaceException(
    this.path,
    this.message, [
    this.cause,
    this.kind = DiskSpaceFailureKind.queryFailed,
  ]);

  @override
  String toString() =>
      'DiskSpaceException: $message (path=$path${cause != null ? ", cause=$cause" : ""})';
}

/// Why a disk-space query failed.
enum DiskSpaceFailureKind {
  /// No capture directory is configured at all.
  pathNotConfigured,

  /// A directory is configured but is not on the filesystem right now.
  pathMissing,

  /// The query itself failed: subprocess error, unparseable output, and so on.
  queryFailed,
}

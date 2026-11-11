part of '../catalog_manager.dart';

/// Static description of a catalog the headless API knows how to manage.
class CatalogDescriptor {
  final String name;
  final String displayName;
  final String description;
  final String fileName;

  /// Superseded file names this catalog may already be materialized under
  /// (see [CatalogSource.legacyFileNames]).
  final List<String> legacyFileNames;

  final String metadataFileName;
  final String version;
  final int approximateSizeBytes;

  /// Upstream FALLBACK download URL (see [CatalogSource.downloadUrl]).
  final String downloadUrl;

  /// GitHub release asset name for the PRIMARY source (see
  /// [CatalogSource.githubAssetName]). Empty when no release asset exists.
  final String githubAssetName;

  /// Expected SHA-256 of the AS-DOWNLOADED bytes (see [CatalogSource.sha256]).
  /// Empty when no canonical hash is known.
  final String sha256;

  final bool isGzipped;
  final bool requiredForPlateSolve;

  const CatalogDescriptor({
    required this.name,
    required this.displayName,
    required this.description,
    required this.fileName,
    required this.metadataFileName,
    required this.version,
    required this.approximateSizeBytes,
    required this.downloadUrl,
    required this.isGzipped,
    required this.requiredForPlateSolve,
    this.legacyFileNames = const [],
    this.githubAssetName = '',
    this.sha256 = '',
  });

  /// Every file name that counts as this catalog on disk, current name first.
  List<String> get candidateFileNames => [fileName, ...legacyFileNames];

  /// The file name to read under [directory] — see
  /// [CatalogSource.resolveInstalledName].
  String resolveInstalledName(String directory) {
    for (final candidate in candidateFileNames) {
      final file = File(path.join(directory, candidate));
      if (file.existsSync() && file.lengthSync() > 0) return candidate;
    }
    return fileName;
  }
}

/// Status of one catalog on disk.
enum CatalogInstallStatus { installed, partial, corrupted, missing }

/// Detailed on-disk status of one catalog.
class InstalledCatalogStatus {
  final String name;
  final String? version;
  final int sizeBytes;
  final int fileCount;
  final DateTime? installedAt;
  final DateTime? lastVerified;
  final String? expectedHash;
  final String? actualHash;
  final int? objectCount;
  final CatalogInstallStatus status;
  final List<String>? errors;

  const InstalledCatalogStatus({
    required this.name,
    this.version,
    this.sizeBytes = 0,
    this.fileCount = 0,
    this.installedAt,
    this.lastVerified,
    this.expectedHash,
    this.actualHash,
    this.objectCount,
    required this.status,
    this.errors,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    if (version != null) 'version': version,
    'sizeBytes': sizeBytes,
    'fileCount': fileCount,
    if (installedAt != null) 'installedAt': installedAt!.toIso8601String(),
    if (lastVerified != null) 'lastVerified': lastVerified!.toIso8601String(),
    if (expectedHash != null) 'expectedHash': expectedHash,
    if (actualHash != null) 'actualHash': actualHash,
    if (objectCount != null) 'objectCount': objectCount,
    'status': status.name,
    if (errors != null && errors!.isNotEmpty) 'errors': errors,
  };
}

/// Description of a catalog available for download.
class AvailableCatalog {
  final String name;
  final String displayName;
  final String version;
  final String description;
  final String? downloadUrl;
  final int sizeBytes;
  final String? sha256;
  final bool requiredForPlateSolve;

  const AvailableCatalog({
    required this.name,
    required this.displayName,
    required this.version,
    required this.description,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.sha256,
    required this.requiredForPlateSolve,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'displayName': displayName,
    'version': version,
    'description': description,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    'sizeBytes': sizeBytes,
    if (sha256 != null) 'sha256': sha256,
    'requiredForPlateSolve': requiredForPlateSolve,
  };
}

/// Result of `downloadAndInstall` / `installFromFile`.
class CatalogInstallResult {
  final String name;
  final String sha256;
  final int sizeBytes;
  final int objectCount;
  final String version;
  final DateTime installedAt;

  const CatalogInstallResult({
    required this.name,
    required this.sha256,
    required this.sizeBytes,
    required this.objectCount,
    required this.version,
    required this.installedAt,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    'objectCount': objectCount,
    'version': version,
    'installedAt': installedAt.toIso8601String(),
  };
}

/// Result of a single-catalog `verify` call.
class CatalogVerifyResult {
  final bool ok;
  final String? expectedHash;
  final String? actualHash;
  final List<String> errors;

  const CatalogVerifyResult({
    required this.ok,
    required this.expectedHash,
    required this.actualHash,
    required this.errors,
  });

  Map<String, Object?> toJson() => {
    'ok': ok,
    if (expectedHash != null) 'expectedHash': expectedHash,
    if (actualHash != null) 'actualHash': actualHash,
    if (errors.isNotEmpty) 'errors': errors,
  };
}

/// Structured lifecycle event emitted by [CatalogManager.events].
/// Consumed by the headless API server which fans these out to clients
/// as `SkotiqEvent`s in the `catalog` category.
class CatalogEvent {
  final String eventType;
  final Map<String, Object?> data;

  const CatalogEvent._(this.eventType, this.data);

  factory CatalogEvent.downloadStarted({
    String? jobId,
    required String name,
    required String downloadUrl,
    required int totalBytes,
  }) => CatalogEvent._('CatalogDownloadStarted', {
    if (jobId != null) 'jobId': jobId,
    'name': name,
    'downloadUrl': downloadUrl,
    'totalBytes': totalBytes,
  });

  factory CatalogEvent.downloadProgress({
    String? jobId,
    required String name,
    required int downloadedBytes,
    required int totalBytes,
  }) => CatalogEvent._('CatalogDownloadProgress', {
    if (jobId != null) 'jobId': jobId,
    'name': name,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    if (totalBytes > 0) 'pct': (downloadedBytes / totalBytes).clamp(0.0, 1.0),
  });

  factory CatalogEvent.downloadComplete({
    String? jobId,
    required String name,
    required String version,
    required int sizeBytes,
    required String sha256,
  }) => CatalogEvent._('CatalogDownloadComplete', {
    if (jobId != null) 'jobId': jobId,
    'name': name,
    'version': version,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
  });

  factory CatalogEvent.downloadFailed({
    String? jobId,
    required String name,
    required String error,
    required String phase,
  }) => CatalogEvent._('CatalogDownloadFailed', {
    if (jobId != null) 'jobId': jobId,
    'name': name,
    'error': error,
    'phase': phase,
  });

  factory CatalogEvent.verified({
    required String name,
    required bool ok,
    List<String>? errors,
  }) => CatalogEvent._('CatalogVerified', {
    'name': name,
    'ok': ok,
    if (errors != null && errors.isNotEmpty) 'errors': errors,
  });

  factory CatalogEvent.uninstalled({required String name}) =>
      CatalogEvent._('CatalogUninstalled', {'name': name});

  const CatalogEvent.reloaded()
    : eventType = 'CatalogReloaded',
      data = const {};
}

/// Exception thrown by [CatalogManager.downloadAndInstall] when a
/// cancellation token requested abort.
class CatalogCancelled implements Exception {
  const CatalogCancelled();
  @override
  String toString() => 'CatalogCancelled';
}

/// Thrown when a catalog transfer stops delivering bytes.
///
/// A TCP connection that goes quiet produces no event at all, so nothing in a
/// bare `await for` over the response body can notice it: the download, the
/// progress bar and the Cancel button all wait forever. This is what the
/// inactivity guard raises instead.
class CatalogDownloadStalled implements Exception {
  /// How long the transfer waited before being declared dead.
  final Duration idleFor;

  /// What it was waiting for — response headers, or the next body chunk.
  final String waitingFor;

  const CatalogDownloadStalled(this.idleFor, {this.waitingFor = 'data'});

  @override
  String toString() =>
      'CatalogDownloadStalled: no $waitingFor for ${idleFor.inMilliseconds}ms';
}

/// Exception thrown when SHA-256 of an uploaded catalog does not match
/// the expected value.
class CatalogHashMismatchException implements Exception {
  final String expected;
  final String actual;
  const CatalogHashMismatchException({
    required this.expected,
    required this.actual,
  });
  @override
  String toString() =>
      'CatalogHashMismatchException(expected=$expected, actual=$actual)';
}

/// Exception raised by the catalog download path with a `phase` tag so
/// the API can surface "what was being attempted when this broke".
class CatalogDownloadException implements Exception {
  final String phase;
  final String message;
  const CatalogDownloadException({required this.phase, required this.message});
  @override
  String toString() => 'CatalogDownloadException($phase): $message';
}

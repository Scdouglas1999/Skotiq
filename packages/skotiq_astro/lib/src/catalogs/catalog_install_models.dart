import 'sky_catalog.dart';

/// What is on disk for one catalog.
enum CatalogInstallStatus {
  /// Data file present with content and readable metadata (or none).
  installed,

  /// Data file present, metadata sidecar unreadable.
  partial,

  /// Data file present but empty or unreadable: an interrupted install.
  corrupted,

  /// No data file.
  missing,
}

/// On-disk state of one catalog. SHA-256 verification is not part of it (it
/// would scan the file on every poll); see `CatalogInstaller.verify`.
class CatalogStatus {
  final SkyCatalog catalog;
  final CatalogInstallStatus state;

  /// Path of the usable data file; null unless one is present with content.
  final String? installedPath;
  final String? version;
  final int sizeBytes;
  final int fileCount;
  final DateTime? installedAt;
  final DateTime? lastVerified;

  /// SHA-256 of the data file recorded at install.
  final String? expectedHash;
  final int? objectCount;

  /// GLADE+ tier recorded at install; null for the other catalogs.
  final AnnotationPackage? annotationPackage;
  final List<String> errors;

  const CatalogStatus({
    required this.catalog,
    required this.state,
    this.installedPath,
    this.version,
    this.sizeBytes = 0,
    this.fileCount = 0,
    this.installedAt,
    this.lastVerified,
    this.expectedHash,
    this.objectCount,
    this.annotationPackage,
    this.errors = const [],
  });

  const CatalogStatus.missing(this.catalog)
    : state = CatalogInstallStatus.missing,
      installedPath = null,
      version = null,
      sizeBytes = 0,
      fileCount = 0,
      installedAt = null,
      lastVerified = null,
      expectedHash = null,
      objectCount = null,
      annotationPackage = null,
      errors = const [];

  /// Whether there is a data file a reader can open.
  bool get isInstalled => installedPath != null;

  Map<String, Object?> toJson() => {
    'name': catalog.name,
    if (version != null) 'version': version,
    'sizeBytes': sizeBytes,
    'fileCount': fileCount,
    if (installedAt != null) 'installedAt': installedAt!.toIso8601String(),
    if (lastVerified != null) 'lastVerified': lastVerified!.toIso8601String(),
    if (expectedHash != null) 'expectedHash': expectedHash,
    if (objectCount != null) 'objectCount': objectCount,
    'status': state.name,
    if (errors.isNotEmpty) 'errors': errors,
  };
}

/// One step of a running install, as the catalog screens show it.
class DownloadProgress {
  final SkyCatalog catalog;
  final double progress; // 0.0 to 1.0; 0 while the total is unknown
  final int bytesReceived;

  /// 0 when the server sent no `Content-Length`.
  final int totalBytes;
  final String status;
  final bool isComplete;

  /// The user canceled: terminal, but not an error.
  final bool cancelled;
  final String? error;

  const DownloadProgress({
    required this.catalog,
    required this.progress,
    required this.bytesReceived,
    required this.totalBytes,
    required this.status,
    this.isComplete = false,
    this.cancelled = false,
    this.error,
  });

  String get catalogName => catalog.displayName;

  /// Success, cancellation or failure: the install is no longer in flight.
  bool get isTerminal => isComplete || cancelled || error != null;

  const DownloadProgress.starting(this.catalog)
    : progress = 0,
      bytesReceived = 0,
      totalBytes = 0,
      status = 'Starting download...',
      isComplete = false,
      cancelled = false,
      error = null;

  const DownloadProgress.complete(this.catalog, int bytes)
    : progress = 1.0,
      bytesReceived = bytes,
      totalBytes = bytes,
      status = 'Complete',
      isComplete = true,
      cancelled = false,
      error = null;

  const DownloadProgress.cancelled(this.catalog)
    : progress = 0,
      bytesReceived = 0,
      totalBytes = 0,
      status = 'Cancelled',
      isComplete = false,
      cancelled = true,
      error = null;

  const DownloadProgress.failed(this.catalog, String this.error)
    : progress = 0,
      bytesReceived = 0,
      totalBytes = 0,
      status = 'Error',
      isComplete = false,
      cancelled = false;
}

/// Outcome of a successful install.
class CatalogInstallResult {
  final SkyCatalog catalog;

  /// SHA-256 of the installed (decompressed) data file.
  final String sha256;
  final int sizeBytes;
  final int objectCount;
  final String version;
  final DateTime installedAt;

  const CatalogInstallResult({
    required this.catalog,
    required this.sha256,
    required this.sizeBytes,
    required this.objectCount,
    required this.version,
    required this.installedAt,
  });

  Map<String, Object?> toJson() => {
    'name': catalog.name,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    'objectCount': objectCount,
    'version': version,
    'installedAt': installedAt.toIso8601String(),
  };
}

/// Outcome of re-hashing an installed catalog against its recorded hash.
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

/// Structured lifecycle event for the host's WebSocket event stream.
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

  /// [totalBytes] is -1 when unknown.
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

/// The caller's cancellation token fired during an install.
class CatalogCancelled implements Exception {
  const CatalogCancelled();
  @override
  String toString() => 'Download canceled';
}

/// The server stopped sending: no response headers, or no body bytes, for
/// [idleFor].
class CatalogDownloadStalled implements Exception {
  final Duration idleFor;
  final String waitingFor;

  const CatalogDownloadStalled(this.idleFor, {this.waitingFor = 'data'});

  @override
  String toString() =>
      'The server sent no $waitingFor for ${idleFor.inSeconds} s';
}

/// Downloaded or supplied bytes do not hash to the expected SHA-256.
class CatalogHashMismatchException implements Exception {
  final String expected;
  final String actual;
  const CatalogHashMismatchException({
    required this.expected,
    required this.actual,
  });
  @override
  String toString() =>
      'The file does not match its expected checksum '
      '(expected $expected, got $actual)';
}

/// An install failed in [phase] (`http_send`, `decompress`, `verify`,
/// `install_from_file`, `download`).
class CatalogDownloadException implements Exception {
  final String phase;
  final String message;
  const CatalogDownloadException({required this.phase, required this.message});
  @override
  String toString() => message;
}

import 'package:skotiq_remote_protocol/wire.dart';

/// Per-catalog install state surfaced by `GET /api/catalog/status`.
class RemoteCatalogStatus {
  final String name;
  final String? version;
  final int sizeBytes;
  final int fileCount;
  final DateTime? installedAt;
  final DateTime? lastVerified;
  final String? expectedHash;
  final String? actualHash;
  final int? objectCount;

  /// One of `installed`, `partial`, `corrupted`, `missing`.
  final String status;
  final List<String> errors;

  const RemoteCatalogStatus({
    required this.name,
    required this.status,
    this.version,
    this.sizeBytes = 0,
    this.fileCount = 0,
    this.installedAt,
    this.lastVerified,
    this.expectedHash,
    this.actualHash,
    this.objectCount,
    this.errors = const [],
  });

  bool get isInstalled => status == 'installed';

  factory RemoteCatalogStatus.fromJson(Map<String, dynamic> json) {
    final rawErrors = json['errors'];
    return RemoteCatalogStatus(
      name: json['name'] as String? ?? '',
      version: json['version'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      fileCount: (json['fileCount'] as num?)?.toInt() ?? 0,
      installedAt: _parseDateField(json['installedAt']),
      lastVerified: _parseDateField(json['lastVerified']),
      expectedHash: json['expectedHash'] as String?,
      actualHash: json['actualHash'] as String?,
      objectCount: (json['objectCount'] as num?)?.toInt(),
      status: json['status'] as String? ?? 'missing',
      errors: rawErrors is List
          ? rawErrors.map((e) => e.toString()).toList(growable: false)
          : const [],
    );
  }
}

/// Wire response for `GET /api/catalog/status`.
class RemoteCatalogStatusResponse {
  final List<RemoteCatalogStatus> catalogs;
  final int totalBytes;
  final String dataDir;
  final int? availableSpaceBytes;

  const RemoteCatalogStatusResponse({
    required this.catalogs,
    required this.totalBytes,
    required this.dataDir,
    this.availableSpaceBytes,
  });

  factory RemoteCatalogStatusResponse.fromJson(Map<String, dynamic> json) {
    final rawCatalogs = json['catalogs'];
    final catalogs = <RemoteCatalogStatus>[];
    if (rawCatalogs is List) {
      for (final entry in rawCatalogs) {
        if (entry is Map) {
          catalogs.add(
            RemoteCatalogStatus.fromJson(entry.cast<String, dynamic>()),
          );
        }
      }
    }
    return RemoteCatalogStatusResponse(
      catalogs: catalogs,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      dataDir: json['dataDir'] as String? ?? '',
      availableSpaceBytes: (json['availableSpaceBytes'] as num?)?.toInt(),
    );
  }
}

/// One entry in the `GET /api/catalog/available` response.
class RemoteAvailableCatalog {
  final String name;
  final String displayName;
  final String version;
  final String description;
  final String? downloadUrl;
  final int sizeBytes;
  final String? sha256;
  final bool requiredForPlateSolve;

  const RemoteAvailableCatalog({
    required this.name,
    required this.displayName,
    required this.version,
    required this.description,
    this.downloadUrl,
    required this.sizeBytes,
    this.sha256,
    this.requiredForPlateSolve = false,
  });

  factory RemoteAvailableCatalog.fromJson(Map<String, dynamic> json) {
    return RemoteAvailableCatalog(
      name: json['name'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      version: json['version'] as String? ?? '',
      description: json['description'] as String? ?? '',
      downloadUrl: json['downloadUrl'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      sha256: json['sha256'] as String?,
      requiredForPlateSolve: json['requiredForPlateSolve'] as bool? ?? false,
    );
  }
}

/// Result of `POST /api/catalog/upload`.
class RemoteCatalogInstallResult {
  final String name;
  final String sha256;
  final int sizeBytes;
  final int objectCount;
  final String version;
  final DateTime? installedAt;

  const RemoteCatalogInstallResult({
    required this.name,
    required this.sha256,
    required this.sizeBytes,
    required this.objectCount,
    required this.version,
    this.installedAt,
  });

  factory RemoteCatalogInstallResult.fromJson(Map<String, dynamic> json) {
    return RemoteCatalogInstallResult(
      name: json['name'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      objectCount: (json['objectCount'] as num?)?.toInt() ?? 0,
      version: json['version'] as String? ?? '',
      installedAt: _parseDateField(json['installedAt']),
    );
  }
}

/// Per-catalog result of `POST /api/catalog/verify`.
class RemoteCatalogVerifyResult {
  final bool ok;
  final String? expectedHash;
  final String? actualHash;
  final List<String> errors;

  const RemoteCatalogVerifyResult({
    required this.ok,
    this.expectedHash,
    this.actualHash,
    this.errors = const [],
  });

  factory RemoteCatalogVerifyResult.fromJson(Map<String, dynamic> json) {
    final rawErrors = json['errors'];
    return RemoteCatalogVerifyResult(
      ok: json['ok'] as bool? ?? false,
      expectedHash: json['expectedHash'] as String?,
      actualHash: json['actualHash'] as String?,
      errors: rawErrors is List
          ? rawErrors.map((e) => e.toString()).toList(growable: false)
          : const [],
    );
  }
}

DateTime? _parseDateField(Object? raw) {
  if (raw is! String) return null;
  return tryParseWireTime(raw);
}

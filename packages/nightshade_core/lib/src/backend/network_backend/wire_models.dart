part of '../network_backend.dart';

/// Backend connection state.
///
/// Describes WebSocket session liveness, not OS-level connectivity. The
/// connection chip renders each state differently, so `connecting` (first
/// attempt) stays distinct from `reconnecting` (a previously-successful
/// connection dropped), and `error` (stopped attempting) from `disconnected`
/// (idle, backoff timer armed).
enum BackendConnectionState {
  /// Idle — not currently attempting a connection and not connected.
  /// Either disposed, or a backoff timer is armed before the next attempt.
  disconnected,

  /// First-time connect in progress (no prior successful attachment).
  /// Distinct from [reconnecting] so the UI says "Connecting" rather than
  /// "Reconnecting" on the initial handshake.
  connecting,

  /// WebSocket is open and the upgrade handshake completed successfully.
  connected,

  /// A prior connection dropped and the backend is retrying.
  reconnecting,

  /// Terminal failure mode (e.g. API version incompatibility). The backend
  /// stopped attempting; the user must reconfigure or relaunch. Emitting
  /// `error` is rare — most transient failures stay in [reconnecting] until
  /// the backoff window times out.
  error,
}

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
}

/// Wire shape for one entry of `GET /api/logs` — an on-disk log file the
/// host is willing to stream via `GET /api/logs/files/<name>/download`.
///
/// Mirrors `LogHandlers.handleListFiles`. `modifiedAt` is null when the
/// host sent a malformed timestamp; the listing still renders.
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
          ? DateTime.tryParse(json['modifiedAt'] as String)
          : null,
      isCurrent: json['isCurrent'] == true,
    );
  }
}

/// Wire shape for `GET /api/filter-wheel/position`.
///
/// Mirrors the JSON envelope emitted by `DeviceHandlers
/// .handleFilterWheelGetPosition`. `position` is null when the filter
/// wheel is disconnected or the driver has not yet reported a slot,
/// `name` is null when the driver returned a short slot-name array.
class RemoteFilterWheelPosition {
  final int? position;
  final String? name;
  final bool isMoving;

  const RemoteFilterWheelPosition({
    required this.position,
    required this.name,
    required this.isMoving,
  });

  factory RemoteFilterWheelPosition.fromJson(Map<String, dynamic> json) {
    return RemoteFilterWheelPosition(
      position: (json['position'] as num?)?.toInt(),
      name: json['name'] as String?,
      isMoving: json['isMoving'] as bool? ?? false,
    );
  }
}

class RemoteScienceBundle {
  final List<PhotometryMeasurementRow> photometry;
  final List<FramePhotometricCalibrationRow> calibrations;
  final List<TransparencySampleRow> transparency;
  final List<PsfFieldTileRow> psfTiles;
  final List<ScienceFrameQualityMetricsRow> frameQuality;
  final List<ScienceTileMetricRow> tileMetrics;
  final List<AstrometryResidualVectorRow> residuals;
  final List<MovingObjectCandidateRow> movingObjects;
  final List<LineRatioProductRow> lineRatios;

  const RemoteScienceBundle({
    required this.photometry,
    required this.calibrations,
    required this.transparency,
    required this.psfTiles,
    required this.frameQuality,
    required this.tileMetrics,
    required this.residuals,
    required this.movingObjects,
    required this.lineRatios,
  });
}

class RemoteJob {
  final String jobId;
  final String operation;
  final String? deviceId;
  final String? commandId;
  final String state;
  final double? progress;
  final String? progressMessage;
  final Map<String, dynamic>? result;
  final Map<String, dynamic>? error;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const RemoteJob({
    required this.jobId,
    required this.operation,
    required this.state,
    this.deviceId,
    this.commandId,
    this.progress,
    this.progressMessage,
    this.result,
    this.error,
    this.createdAt,
    this.updatedAt,
  });

  bool get isTerminal =>
      state == 'succeeded' || state == 'failed' || state == 'cancelled';

  factory RemoteJob.fromJson(
    Map<String, dynamic> json, {
    String? fallbackOperation,
  }) {
    final jobId = json['jobId'];
    if (jobId is! String || jobId.trim().isEmpty) {
      throw const FormatException('Remote job response is missing `jobId`.');
    }
    final rawOperation = json['operation'];
    final operation = rawOperation is String && rawOperation.trim().isNotEmpty
        ? rawOperation
        : fallbackOperation;
    if (operation == null || operation.trim().isEmpty) {
      throw const FormatException(
        'Remote job response is missing `operation`.',
      );
    }
    // Admission endpoints return `{jobId, status: queued}` while snapshots
    // return `{jobId, operation, state: ...}`. Treat both as the same wire
    // contract instead of turning every newly-started job into `unknown`.
    final rawState = json['state'] ?? json['status'];
    if (rawState is! String || rawState.trim().isEmpty) {
      throw const FormatException('Remote job response is missing job state.');
    }
    return RemoteJob(
      jobId: jobId,
      operation: operation,
      deviceId: json['deviceId'] as String?,
      commandId: json['commandId'] as String?,
      state: rawState,
      progress: (json['progress'] as num?)?.toDouble(),
      progressMessage: json['progressMessage'] as String?,
      result: json['result'] is Map
          ? Map<String, dynamic>.from(json['result'] as Map)
          : null,
      error: json['error'] is Map
          ? Map<String, dynamic>.from(json['error'] as Map)
          : null,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  /// Construct from the `data` map of a job-category NightshadeEvent.
  /// The wire shape there is a subset of [fromJson] (no createdAt /
  /// updatedAt — the event itself carries the timestamp).
  factory RemoteJob.fromEventData(Map<String, dynamic> data) {
    return RemoteJob(
      jobId: data['jobId'] as String? ?? '',
      operation: data['operation'] as String? ?? '',
      deviceId: data['deviceId'] as String?,
      commandId: data['commandId'] as String?,
      state: data['state'] as String? ?? 'unknown',
      progress: (data['progress'] as num?)?.toDouble(),
      progressMessage: data['message'] as String?,
      result: data['result'] is Map
          ? Map<String, dynamic>.from(data['result'] as Map)
          : null,
      error: data['error'] is Map
          ? Map<String, dynamic>.from(data['error'] as Map)
          : null,
    );
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }
}

/// Client-side mirror of `GET /api/system/version`. Carries the
/// running build info plus the last-check / last-applied bookkeeping
/// timestamps. All optional fields tolerate missing keys so a future
/// server that drops one (e.g. when the controller cannot persist the
/// state markers) does not break older clients.
class RemoteVersionInfo {
  final String currentVersion;
  final int buildNumber;

  /// OTA channel the host follows. Null when the host runs without a
  /// provisioned update stack — the always-on `/api/system/version` fallback
  /// (headless hosts, dev builds) reports build info with no channel.
  final String? channel;
  final String platform;
  final String? dataDir;
  final String? updateServerUrl;

  /// Where the host looks for updates, when it has a source at all.
  ///
  /// [updateServerUrl] alone can no longer answer that: a host reading the
  /// project's GitHub releases has no server URL, and treating a null URL as
  /// "OTA is off" told the operator updates were unavailable on a rig that
  /// could update perfectly well. Null only when the host reported no source.
  final String? updateSource;
  final DateTime? lastUpdateCheck;
  final DateTime? lastUpdateApplied;

  const RemoteVersionInfo({
    required this.currentVersion,
    required this.buildNumber,
    this.channel,
    required this.platform,
    this.dataDir,
    this.updateServerUrl,
    this.updateSource,
    this.lastUpdateCheck,
    this.lastUpdateApplied,
  });

  factory RemoteVersionInfo.fromJson(Map<String, dynamic> json) {
    DateTime? parse(Object? raw) {
      if (raw is! String) return null;
      return DateTime.tryParse(raw);
    }

    final rawUpdateServerUrl = json['updateServerUrl'];
    final safeUpdateServerUrl = rawUpdateServerUrl is String
        ? sanitizeEndpointForDisplay(rawUpdateServerUrl)
        : '';

    final currentVersion = json['currentVersion'];
    final buildNumber = json['buildNumber'];
    final channel = json['channel'];
    final platform = json['platform'];
    if (currentVersion is! String || currentVersion.trim().isEmpty) {
      throw const FormatException(
        'System version response is missing `currentVersion`.',
      );
    }
    if (buildNumber is! num ||
        !buildNumber.toDouble().isFinite ||
        buildNumber < 0 ||
        buildNumber.toInt() != buildNumber) {
      throw const FormatException(
        'System version response has an invalid `buildNumber`.',
      );
    }
    // `channel` is absent on hosts without a provisioned update stack (the
    // always-on version fallback) — treat missing/blank as "no channel".
    final safeChannel = channel is String && channel.trim().isNotEmpty
        ? channel
        : null;
    if (platform is! String || platform.trim().isEmpty) {
      throw const FormatException(
        'System version response is missing `platform`.',
      );
    }

    return RemoteVersionInfo(
      currentVersion: currentVersion,
      buildNumber: buildNumber.toInt(),
      channel: safeChannel,
      platform: platform,
      dataDir: json['dataDir'] is String ? json['dataDir'] as String : null,
      updateServerUrl: safeUpdateServerUrl.isEmpty ? null : safeUpdateServerUrl,
      updateSource: switch (json['updateSource']) {
        final String s when s.trim().isNotEmpty => s.trim(),
        // An older host predates this field. It only ever had a server URL,
        // so its presence is the honest answer for those builds.
        _ => safeUpdateServerUrl.isEmpty ? null : safeUpdateServerUrl,
      },
      lastUpdateCheck: parse(json['lastUpdateCheck']),
      lastUpdateApplied: parse(json['lastUpdateApplied']),
    );
  }
}

/// Client-side mirror of `GET /api/system/update/status`. State is
/// kept loose (string, not enum) so a server that adds a new
/// lifecycle phase does not crash older clients — the caller
/// branches on the wire name.
class RemoteUpdateStatus {
  final String state;
  final String? availableVersion;
  final int? availableBuildNumber;
  final bool requiresManualUpgrade;
  final String? stagedVersion;
  final DateTime? stagedAt;
  final double? progressPct;
  final String? message;
  final String? lastError;
  final bool rollbackAvailable;
  final bool canAuthenticateUpdates;

  const RemoteUpdateStatus({
    required this.state,
    this.availableVersion,
    this.availableBuildNumber,
    this.requiresManualUpgrade = false,
    this.stagedVersion,
    this.stagedAt,
    this.progressPct,
    this.message,
    this.lastError,
    this.rollbackAvailable = false,
    this.canAuthenticateUpdates = true,
  });

  bool get hasAvailableUpdate =>
      state == 'available' || availableVersion != null;
  bool get hasStagedUpdate => stagedVersion != null;
  bool get isInFlight =>
      state == 'checking' ||
      state == 'downloading' ||
      state == 'verifying' ||
      state == 'installing';

  factory RemoteUpdateStatus.fromJson(Map<String, dynamic> json) {
    DateTime? parse(Object? raw) {
      if (raw is! String) return null;
      return DateTime.tryParse(raw);
    }

    final state = json['state'];
    if (state is! String || state.trim().isEmpty) {
      throw const FormatException('Update status response is missing `state`.');
    }
    final rawProgress = json['progressPct'];
    final progress = rawProgress is num ? rawProgress.toDouble() : null;
    if (rawProgress != null &&
        (progress == null ||
            !progress.isFinite ||
            progress < 0 ||
            progress > 100)) {
      throw const FormatException(
        'Update status response has invalid `progressPct`.',
      );
    }
    final rawAvailableBuild = json['availableBuildNumber'];
    if (rawAvailableBuild != null &&
        (rawAvailableBuild is! num ||
            !rawAvailableBuild.toDouble().isFinite ||
            rawAvailableBuild < 0 ||
            rawAvailableBuild.toInt() != rawAvailableBuild)) {
      throw const FormatException(
        'Update status response has invalid `availableBuildNumber`.',
      );
    }

    return RemoteUpdateStatus(
      state: state,
      availableVersion: json['availableVersion'] is String
          ? json['availableVersion'] as String
          : null,
      availableBuildNumber: rawAvailableBuild is num
          ? rawAvailableBuild.toInt()
          : null,
      requiresManualUpgrade: json['requiresManualUpgrade'] is bool
          ? json['requiresManualUpgrade'] as bool
          : false,
      stagedVersion: json['stagedVersion'] is String
          ? json['stagedVersion'] as String
          : null,
      stagedAt: parse(json['stagedAt']),
      progressPct: progress,
      message: json['message'] is String ? json['message'] as String : null,
      lastError: json['lastError'] is String
          ? json['lastError'] as String
          : null,
      rollbackAvailable: json['rollbackAvailable'] is bool
          ? json['rollbackAvailable'] as bool
          : false,
      // Older hosts never advertised whether a trusted vendor key was
      // provisioned. Unknown must be fail-closed: let the user check for an
      // update, but never enable a package download on an assumption.
      canAuthenticateUpdates: json['canAuthenticateUpdates'] is bool
          ? json['canAuthenticateUpdates'] as bool
          : false,
    );
  }
}

/// Sanitized durable Stack-and-Share record returned by an imaging host.
///
/// [result.exportedImagePath] is always null: host filesystem paths never cross
/// the remote boundary. [previewAvailable] tells the client whether the
/// authenticated binary preview endpoint can supply pixels.
class RemoteStackedResult {
  final StackAndShareResult result;
  final bool previewAvailable;

  const RemoteStackedResult({
    required this.result,
    required this.previewAvailable,
  });
}

/// Client-side mirror of `GET /api/system/update/staged`. Returned by
/// [NetworkBackend.getStagedUpdate] when a staged update exists.
class RemoteStagedUpdate {
  final String stagedVersion;
  final int stagedBuildNumber;
  final DateTime? stagedAt;
  final String? manifestHash;
  final int fileCount;
  final int totalBytes;
  final String? sourceUrl;
  final Map<String, String> expectedHashes;

  const RemoteStagedUpdate({
    required this.stagedVersion,
    required this.stagedBuildNumber,
    required this.fileCount,
    required this.totalBytes,
    required this.expectedHashes,
    this.stagedAt,
    this.manifestHash,
    this.sourceUrl,
  });

  factory RemoteStagedUpdate.fromJson(Map<String, dynamic> json) {
    final hashesRaw = json['expectedHashes'];
    final hashes = <String, String>{};
    if (hashesRaw is Map) {
      hashesRaw.forEach((k, v) {
        if (k is String && v is String) {
          hashes[k] = v;
        }
      });
    }
    DateTime? parse(Object? raw) {
      if (raw is! String) return null;
      return DateTime.tryParse(raw);
    }

    return RemoteStagedUpdate(
      stagedVersion: json['stagedVersion'] as String? ?? '',
      stagedBuildNumber: (json['stagedBuildNumber'] as num?)?.toInt() ?? 0,
      stagedAt: parse(json['stagedAt']),
      manifestHash: json['manifestHash'] as String?,
      fileCount: (json['fileCount'] as num?)?.toInt() ?? hashes.length,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      sourceUrl: json['sourceUrl'] as String?,
      expectedHashes: hashes,
    );
  }
}

/// Client-side mirror of the headless server's session-status response.
class RemoteSessionStatus {
  final Map<String, dynamic>? owner;
  final bool isYouTheOwner;
  final String mode; // 'operator' | 'viewer' | 'unowned'
  final int heartbeatTimeoutSeconds;

  const RemoteSessionStatus({
    required this.owner,
    required this.isYouTheOwner,
    required this.mode,
    required this.heartbeatTimeoutSeconds,
  });

  factory RemoteSessionStatus.fromJson(Map<String, dynamic> json) {
    return RemoteSessionStatus(
      owner: json['owner'] is Map
          ? Map<String, dynamic>.from(json['owner'] as Map)
          : null,
      isYouTheOwner: json['isYouTheOwner'] as bool? ?? false,
      mode: json['mode'] as String? ?? 'unowned',
      heartbeatTimeoutSeconds:
          (json['heartbeatTimeoutSeconds'] as num?)?.toInt() ?? 0,
    );
  }
}

// Client-side mirrors of the headless server's /api/catalog/... shapes.

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
  return DateTime.tryParse(raw);
}

// Wire types for the read-only DB endpoints. All endpoints use the
// same `{items, total}` envelope, captured by [RemotePage<T>] so callers
// see one consistent paginated shape regardless of underlying table.

/// Generic envelope for paginated `GET` endpoints. `items` is the page
/// content; `total` is the unpaginated row count matching the filter.

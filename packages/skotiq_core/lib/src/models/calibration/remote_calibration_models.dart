// Wire-level model classes for the headless calibration API.
//
// These classes live alongside the existing `dark_library_match_tolerances.dart`
// in the calibration models subdirectory. They mirror the JSON wire shapes
// that `CalibrationHandlers` emits/accepts so the NetworkBackend client can
// decode responses into strongly-typed values rather than raw maps.
//
// Tolerant parsing: each `fromJson` accepts missing fields where it makes
// sense (the wire is treated as forward-compatible) but throws if a
// required field is the wrong type.

/// Wire form of a row in the `dark_library` Drift table, plus an
/// on-disk presence check the server performs at list time.
class RemoteDarkLibraryEntry {
  /// Database primary key.
  final int id;

  /// Absolute path to the raw or master dark FITS/XISF file on the host.
  final String filePath;

  /// Last path segment of [filePath]; convenience for the mobile UI.
  final String fileName;

  /// Exposure duration in seconds.
  final double exposureDuration;

  /// Sensor temperature in degrees Celsius at time of capture. Null when
  /// the host could not read sensor temperature.
  final double? sensorTempC;

  /// Camera gain setting.
  final int gain;

  /// Camera offset setting.
  final int offset;

  /// Horizontal binning.
  final int binX;

  /// Vertical binning.
  final int binY;

  /// Frame type: `dark` or `bias`.
  final String frameType;

  /// Sensor width in pixels (may be null on legacy rows).
  final int? width;

  /// Sensor height in pixels (may be null on legacy rows).
  final int? height;

  /// Path to the master stack file if this row is a master dark, else null.
  final String? masterPath;

  /// Number of raw frames combined into this master. Null for raw rows.
  final int? frameCount;

  /// When this row was inserted.
  final DateTime createdAt;

  /// File size in bytes, computed server-side at list time. Null when the
  /// file is missing or could not be stat'd.
  final int? fileSize;

  /// Whether the server could see the file on disk at list time. False
  /// means the row is orphaned and the operator probably wants to clean it
  /// up via DELETE.
  final bool fileExists;

  const RemoteDarkLibraryEntry({
    required this.id,
    required this.filePath,
    required this.fileName,
    required this.exposureDuration,
    required this.sensorTempC,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
    required this.frameType,
    required this.width,
    required this.height,
    required this.masterPath,
    required this.frameCount,
    required this.createdAt,
    required this.fileSize,
    required this.fileExists,
  });

  factory RemoteDarkLibraryEntry.fromJson(Map<String, dynamic> json) {
    return RemoteDarkLibraryEntry(
      id: (json['id'] as num).toInt(),
      filePath: json['filePath'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      exposureDuration: (json['exposureDuration'] as num?)?.toDouble() ?? 0.0,
      sensorTempC: (json['sensorTempC'] as num?)?.toDouble(),
      gain: (json['gain'] as num?)?.toInt() ?? 0,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      binX: (json['binX'] as num?)?.toInt() ?? 1,
      binY: (json['binY'] as num?)?.toInt() ?? 1,
      frameType: json['frameType'] as String? ?? 'dark',
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      masterPath: json['masterPath'] as String?,
      frameCount: (json['frameCount'] as num?)?.toInt(),
      createdAt: _parseDate(json['createdAt']) ?? DateTime.utc(1970),
      fileSize: (json['fileSize'] as num?)?.toInt(),
      fileExists: json['fileExists'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'filePath': filePath,
    'fileName': fileName,
    'exposureDuration': exposureDuration,
    'sensorTempC': sensorTempC,
    'gain': gain,
    'offset': offset,
    'binX': binX,
    'binY': binY,
    'frameType': frameType,
    'width': width,
    'height': height,
    'masterPath': masterPath,
    'frameCount': frameCount,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'fileSize': fileSize,
    'fileExists': fileExists,
  };
}

/// Wire form of a row in the `flat_history` Drift table.
class RemoteFlatHistoryEntry {
  final int id;
  final String filter;
  final double exposureDuration;
  final double histogramTarget;
  final int adu;
  final int gain;
  final int binning;
  final int? panelBrightness;
  final double? skyAduRate;
  final String? twilightPhase;
  final int? equipmentProfileId;
  final DateTime createdAt;

  const RemoteFlatHistoryEntry({
    required this.id,
    required this.filter,
    required this.exposureDuration,
    required this.histogramTarget,
    required this.adu,
    required this.gain,
    required this.binning,
    required this.panelBrightness,
    required this.skyAduRate,
    required this.twilightPhase,
    required this.equipmentProfileId,
    required this.createdAt,
  });

  factory RemoteFlatHistoryEntry.fromJson(Map<String, dynamic> json) {
    return RemoteFlatHistoryEntry(
      id: (json['id'] as num).toInt(),
      filter: json['filter'] as String? ?? '',
      exposureDuration: (json['exposureDuration'] as num?)?.toDouble() ?? 0.0,
      histogramTarget: (json['histogramTarget'] as num?)?.toDouble() ?? 0.0,
      adu: (json['adu'] as num?)?.toInt() ?? 0,
      gain: (json['gain'] as num?)?.toInt() ?? 0,
      binning: (json['binning'] as num?)?.toInt() ?? 1,
      panelBrightness: (json['panelBrightness'] as num?)?.toInt(),
      skyAduRate: (json['skyAduRate'] as num?)?.toDouble(),
      twilightPhase: json['twilightPhase'] as String?,
      equipmentProfileId: (json['equipmentProfileId'] as num?)?.toInt(),
      createdAt: _parseDate(json['createdAt']) ?? DateTime.utc(1970),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'filter': filter,
    'exposureDuration': exposureDuration,
    'histogramTarget': histogramTarget,
    'adu': adu,
    'gain': gain,
    'binning': binning,
    'panelBrightness': panelBrightness,
    'skyAduRate': skyAduRate,
    'twilightPhase': twilightPhase,
    'equipmentProfileId': equipmentProfileId,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// Wire form of a flat-history-derived exposure recommendation.
class RemoteFlatRecommendation {
  /// Recommended exposure duration in seconds.
  final double exposureDuration;

  /// The id of the flat-history row used as the basis for the
  /// recommendation.
  final int basedOnFlatId;

  /// Age of the underlying row in whole days. Older data is less
  /// trustworthy because flat fields drift as dust accumulates.
  final int ageDays;

  /// Coarse confidence label derived from [ageDays]:
  /// `high` (<=7d), `medium` (<=30d), or `low` otherwise.
  final String confidence;

  const RemoteFlatRecommendation({
    required this.exposureDuration,
    required this.basedOnFlatId,
    required this.ageDays,
    required this.confidence,
  });

  factory RemoteFlatRecommendation.fromJson(Map<String, dynamic> json) {
    return RemoteFlatRecommendation(
      exposureDuration: (json['exposureDuration'] as num?)?.toDouble() ?? 0.0,
      basedOnFlatId: (json['basedOn']?['flatId'] as num?)?.toInt() ?? 0,
      ageDays: (json['basedOn']?['ageDays'] as num?)?.toInt() ?? 0,
      confidence: json['basedOn']?['confidence'] as String? ?? 'low',
    );
  }

  Map<String, dynamic> toJson() => {
    'exposureDuration': exposureDuration,
    'basedOn': {
      'flatId': basedOnFlatId,
      'ageDays': ageDays,
      'confidence': confidence,
    },
  };
}

/// Wire form of a row in the `defect_maps` Drift table — metadata only;
/// the BLOB bitmap is fetched via the dedicated single-defect-map endpoint.
class RemoteDefectMap {
  final int id;
  final String cameraId;
  final int width;
  final int height;
  final int temperatureBucketDecicelsius;
  final int defectivePixelCount;
  final DateTime lastRebuiltAt;
  final String? sourceFilePath;
  final int? fileSize;
  final bool fileExists;

  const RemoteDefectMap({
    required this.id,
    required this.cameraId,
    required this.width,
    required this.height,
    required this.temperatureBucketDecicelsius,
    required this.defectivePixelCount,
    required this.lastRebuiltAt,
    required this.sourceFilePath,
    required this.fileSize,
    required this.fileExists,
  });

  factory RemoteDefectMap.fromJson(Map<String, dynamic> json) {
    return RemoteDefectMap(
      id: (json['id'] as num).toInt(),
      cameraId: json['cameraId'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      temperatureBucketDecicelsius:
          (json['temperatureBucketDecicelsius'] as num?)?.toInt() ?? 0,
      defectivePixelCount: (json['defectivePixelCount'] as num?)?.toInt() ?? 0,
      lastRebuiltAt: _parseDate(json['lastRebuiltAt']) ?? DateTime.utc(1970),
      sourceFilePath: json['sourceFilePath'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      fileExists: json['fileExists'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'cameraId': cameraId,
    'width': width,
    'height': height,
    'temperatureBucketDecicelsius': temperatureBucketDecicelsius,
    'defectivePixelCount': defectivePixelCount,
    'lastRebuiltAt': lastRebuiltAt.toUtc().toIso8601String(),
    'sourceFilePath': sourceFilePath,
    'fileSize': fileSize,
    'fileExists': fileExists,
  };
}

/// Metadata payload that accompanies a multipart dark-frame upload.
///
/// Carries the same fields a manual POST /api/calibration/darks would
/// supply except the file path is computed server-side (the file is
/// stored in `$DATA_DIR/calibration/darks/`).
class DarkUploadMetadata {
  final double exposureDuration;
  final double? sensorTempC;
  final int gain;
  final int offset;
  final int binX;
  final int binY;
  final String frameType;
  final int? width;
  final int? height;
  final int? frameCount;
  final String? masterPath;

  const DarkUploadMetadata({
    required this.exposureDuration,
    this.sensorTempC,
    this.gain = 0,
    this.offset = 0,
    this.binX = 1,
    this.binY = 1,
    this.frameType = 'dark',
    this.width,
    this.height,
    this.frameCount,
    this.masterPath,
  });

  Map<String, dynamic> toJson() => {
    'exposureDuration': exposureDuration,
    if (sensorTempC != null) 'sensorTempC': sensorTempC,
    'gain': gain,
    'offset': offset,
    'binX': binX,
    'binY': binY,
    'frameType': frameType,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (frameCount != null) 'frameCount': frameCount,
    if (masterPath != null) 'masterPath': masterPath,
  };
}

DateTime? _parseDate(Object? raw) {
  if (raw == null) return null;
  if (raw is String) return DateTime.tryParse(raw);
  if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
  return null;
}

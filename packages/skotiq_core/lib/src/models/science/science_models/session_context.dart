part of '../science_models.dart';

class ScienceSessionConfig {
  final int? sessionId;
  final bool photometryEnabled;
  final bool calibrationEnabled;
  final bool transparencyEnabled;
  final bool psfMapEnabled;
  final bool residualsEnabled;
  final bool movingObjectsEnabled;
  final bool narrowbandEnabled;
  final int psfGridRows;
  final int psfGridCols;
  final double transparencyAlertThreshold;

  const ScienceSessionConfig({
    this.sessionId,
    this.photometryEnabled = true,
    this.calibrationEnabled = true,
    this.transparencyEnabled = true,
    this.psfMapEnabled = true,
    this.residualsEnabled = true,
    this.movingObjectsEnabled = false,
    this.narrowbandEnabled = false,
    this.psfGridRows = 4,
    this.psfGridCols = 6,
    this.transparencyAlertThreshold = 70.0,
  });

  ScienceSessionConfig copyWith({
    int? sessionId,
    bool? photometryEnabled,
    bool? calibrationEnabled,
    bool? transparencyEnabled,
    bool? psfMapEnabled,
    bool? residualsEnabled,
    bool? movingObjectsEnabled,
    bool? narrowbandEnabled,
    int? psfGridRows,
    int? psfGridCols,
    double? transparencyAlertThreshold,
  }) {
    return ScienceSessionConfig(
      sessionId: sessionId ?? this.sessionId,
      photometryEnabled: photometryEnabled ?? this.photometryEnabled,
      calibrationEnabled: calibrationEnabled ?? this.calibrationEnabled,
      transparencyEnabled: transparencyEnabled ?? this.transparencyEnabled,
      psfMapEnabled: psfMapEnabled ?? this.psfMapEnabled,
      residualsEnabled: residualsEnabled ?? this.residualsEnabled,
      movingObjectsEnabled: movingObjectsEnabled ?? this.movingObjectsEnabled,
      narrowbandEnabled: narrowbandEnabled ?? this.narrowbandEnabled,
      psfGridRows: psfGridRows ?? this.psfGridRows,
      psfGridCols: psfGridCols ?? this.psfGridCols,
      transparencyAlertThreshold:
          transparencyAlertThreshold ?? this.transparencyAlertThreshold,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'photometryEnabled': photometryEnabled,
      'calibrationEnabled': calibrationEnabled,
      'transparencyEnabled': transparencyEnabled,
      'psfMapEnabled': psfMapEnabled,
      'residualsEnabled': residualsEnabled,
      'movingObjectsEnabled': movingObjectsEnabled,
      'narrowbandEnabled': narrowbandEnabled,
      'psfGridRows': psfGridRows,
      'psfGridCols': psfGridCols,
      'transparencyAlertThreshold': transparencyAlertThreshold,
    };
  }

  factory ScienceSessionConfig.fromJson(Map<String, dynamic> json) {
    return ScienceSessionConfig(
      sessionId: (json['sessionId'] as num?)?.toInt(),
      photometryEnabled: json['photometryEnabled'] as bool? ?? true,
      calibrationEnabled: json['calibrationEnabled'] as bool? ?? true,
      transparencyEnabled: json['transparencyEnabled'] as bool? ?? true,
      psfMapEnabled: json['psfMapEnabled'] as bool? ?? true,
      residualsEnabled: json['residualsEnabled'] as bool? ?? true,
      movingObjectsEnabled: json['movingObjectsEnabled'] as bool? ?? false,
      narrowbandEnabled: json['narrowbandEnabled'] as bool? ?? false,
      psfGridRows: (json['psfGridRows'] as num?)?.toInt() ?? 4,
      psfGridCols: (json['psfGridCols'] as num?)?.toInt() ?? 6,
      transparencyAlertThreshold:
          (json['transparencyAlertThreshold'] as num?)?.toDouble() ?? 70.0,
    );
  }
}

class ScienceDiagnostics {
  final String solverId;
  final SolverCapabilities capabilities;
  final String? lastWarning;
  final DateTime? lastUpdated;

  const ScienceDiagnostics({
    required this.solverId,
    required this.capabilities,
    this.lastWarning,
    this.lastUpdated,
  });
}

class ScienceFrameContext {
  final int? capturedImageId;
  final int? sessionId;
  final DateTime capturedAt;
  final double exposureSeconds;
  final String? filterName;
  final double? airmass;
  final int imageWidth;
  final int imageHeight;

  const ScienceFrameContext({
    required this.capturedImageId,
    required this.sessionId,
    required this.capturedAt,
    required this.exposureSeconds,
    required this.filterName,
    required this.airmass,
    required this.imageWidth,
    required this.imageHeight,
  });
}

class PhotometryAnchor {
  final String objectId;
  final String label;
  final double raDegrees;
  final double decDegrees;

  const PhotometryAnchor({
    required this.objectId,
    required this.label,
    required this.raDegrees,
    required this.decDegrees,
  });

  PhotometryAnchor copyWith({
    String? objectId,
    String? label,
    double? raDegrees,
    double? decDegrees,
  }) {
    return PhotometryAnchor(
      objectId: objectId ?? this.objectId,
      label: label ?? this.label,
      raDegrees: raDegrees ?? this.raDegrees,
      decDegrees: decDegrees ?? this.decDegrees,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'objectId': objectId,
      'label': label,
      'raDegrees': raDegrees,
      'decDegrees': decDegrees,
    };
  }

  factory PhotometryAnchor.fromJson(Map<String, dynamic> json) {
    return PhotometryAnchor(
      objectId: json['objectId']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      raDegrees: (json['raDegrees'] as num?)?.toDouble() ?? 0.0,
      decDegrees: (json['decDegrees'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

part of '../science_models.dart';

class SciencePhotometrySelection {
  final bool differentialEnabled;
  final PhotometryAnchor? target;
  final List<PhotometryAnchor> comparisons;

  const SciencePhotometrySelection({
    this.differentialEnabled = false,
    this.target,
    this.comparisons = const [],
  });

  SciencePhotometrySelection copyWith({
    bool? differentialEnabled,
    PhotometryAnchor? target,
    bool clearTarget = false,
    List<PhotometryAnchor>? comparisons,
  }) {
    return SciencePhotometrySelection(
      differentialEnabled: differentialEnabled ?? this.differentialEnabled,
      target: clearTarget ? null : (target ?? this.target),
      comparisons: comparisons ?? this.comparisons,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'differentialEnabled': differentialEnabled,
      'target': target?.toJson(),
      'comparisons': comparisons.map((entry) => entry.toJson()).toList(),
    };
  }

  factory SciencePhotometrySelection.fromJson(Map<String, dynamic> json) {
    final rawComparisons = json['comparisons'];
    final parsedComparisons = <PhotometryAnchor>[];
    if (rawComparisons is List) {
      for (final raw in rawComparisons) {
        if (raw is Map<String, dynamic>) {
          parsedComparisons.add(PhotometryAnchor.fromJson(raw));
        } else if (raw is Map) {
          parsedComparisons.add(
            PhotometryAnchor.fromJson(raw.cast<String, dynamic>()),
          );
        }
      }
    }

    final rawTarget = json['target'];
    PhotometryAnchor? parsedTarget;
    if (rawTarget is Map<String, dynamic>) {
      parsedTarget = PhotometryAnchor.fromJson(rawTarget);
    } else if (rawTarget is Map) {
      parsedTarget = PhotometryAnchor.fromJson(
        rawTarget.cast<String, dynamic>(),
      );
    }

    return SciencePhotometrySelection(
      differentialEnabled: json['differentialEnabled'] == true,
      target: parsedTarget,
      comparisons: parsedComparisons,
    );
  }
}

/// A single star match used for computing photometric transform coefficients.
class TransformStarMatch {
  final double catalogMag;
  final double instrumentalMag;
  final double colorIndex;
  final double airmass;
  final double residual;

  const TransformStarMatch({
    required this.catalogMag,
    required this.instrumentalMag,
    required this.colorIndex,
    required this.airmass,
    required this.residual,
  });

  Map<String, dynamic> toJson() {
    return {
      'catalogMag': catalogMag,
      'instrumentalMag': instrumentalMag,
      'colorIndex': colorIndex,
      'airmass': airmass,
      'residual': residual,
    };
  }

  factory TransformStarMatch.fromJson(Map<String, dynamic> json) {
    return TransformStarMatch(
      catalogMag: (json['catalogMag'] as num?)?.toDouble() ?? 0.0,
      instrumentalMag: (json['instrumentalMag'] as num?)?.toDouble() ?? 0.0,
      colorIndex: (json['colorIndex'] as num?)?.toDouble() ?? 0.0,
      airmass: (json['airmass'] as num?)?.toDouble() ?? 1.0,
      residual: (json['residual'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Photometric transformation coefficients for converting instrumental
/// magnitudes to standard magnitudes using the equation:
///   M_std = m_inst - k*X + T*(B-V) + zp
/// where:
///   m_inst = instrumental magnitude (-2.5 * log10(flux))
///   k = extinction coefficient (mags per airmass)
///   X = airmass
///   T = color term (transform coefficient)
///   (B-V) = color index of the star
///   zp = zero point
class PhotometricTransformCoefficients {
  final int? id;
  final int? equipmentProfileId;
  final String filterName;
  final double colorTerm;
  final double extinctionCoefficient;
  final double zeroPoint;
  final double rmsResidual;
  final int matchedStarCount;
  final String catalogSource;
  final List<TransformStarMatch> fitData;
  final DateTime dateComputed;

  const PhotometricTransformCoefficients({
    this.id,
    this.equipmentProfileId,
    required this.filterName,
    required this.colorTerm,
    required this.extinctionCoefficient,
    required this.zeroPoint,
    required this.rmsResidual,
    required this.matchedStarCount,
    this.catalogSource = 'auto',
    this.fitData = const [],
    required this.dateComputed,
  });

  /// Apply this transform to convert instrumental magnitude to standard.
  double applyTransform({
    required double instrumentalMag,
    required double airmass,
    required double colorIndex,
  }) {
    return instrumentalMag -
        extinctionCoefficient * airmass +
        colorTerm * colorIndex +
        zeroPoint;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'equipmentProfileId': equipmentProfileId,
      'filterName': filterName,
      'colorTerm': colorTerm,
      'extinctionCoefficient': extinctionCoefficient,
      'zeroPoint': zeroPoint,
      'rmsResidual': rmsResidual,
      'matchedStarCount': matchedStarCount,
      'catalogSource': catalogSource,
      'fitData': fitData.map((match) => match.toJson()).toList(),
      'dateComputed': dateComputed.toIso8601String(),
    };
  }

  factory PhotometricTransformCoefficients.fromJson(Map<String, dynamic> json) {
    final rawFitData = json['fitData'] as List? ?? const [];
    return PhotometricTransformCoefficients(
      id: (json['id'] as num?)?.toInt(),
      equipmentProfileId: (json['equipmentProfileId'] as num?)?.toInt(),
      filterName: json['filterName']?.toString() ?? '',
      colorTerm: (json['colorTerm'] as num?)?.toDouble() ?? 0.0,
      extinctionCoefficient:
          (json['extinctionCoefficient'] as num?)?.toDouble() ?? 0.0,
      zeroPoint: (json['zeroPoint'] as num?)?.toDouble() ?? 0.0,
      rmsResidual: (json['rmsResidual'] as num?)?.toDouble() ?? 0.0,
      matchedStarCount: (json['matchedStarCount'] as num?)?.toInt() ?? 0,
      catalogSource: json['catalogSource']?.toString() ?? 'auto',
      fitData: rawFitData
          .whereType<Map>()
          .map(
            (entry) =>
                TransformStarMatch.fromJson(entry.cast<String, dynamic>()),
          )
          .toList(growable: false),
      dateComputed:
          DateTime.tryParse(json['dateComputed']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

/// Input data for the calibration wizard — catalog star with known magnitudes
/// matched to a detected source in the image.
class CatalogStarMatch {
  final double x;
  final double y;
  final double raDegrees;
  final double decDegrees;
  final double catalogMagV;
  final double catalogMagB;
  final double instrumentalFlux;
  final double snr;
  final double airmass;

  const CatalogStarMatch({
    required this.x,
    required this.y,
    required this.raDegrees,
    required this.decDegrees,
    required this.catalogMagV,
    required this.catalogMagB,
    required this.instrumentalFlux,
    required this.snr,
    required this.airmass,
  });

  double get colorIndex => catalogMagB - catalogMagV;

  double get instrumentalMag {
    if (instrumentalFlux <= 0) {
      return 99.0;
    }
    return -2.5 *
        math.log(instrumentalFlux.clamp(1e-30, double.infinity)) /
        math.ln10;
  }

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'y': y,
      'raDegrees': raDegrees,
      'decDegrees': decDegrees,
      'catalogMagV': catalogMagV,
      'catalogMagB': catalogMagB,
      'instrumentalFlux': instrumentalFlux,
      'snr': snr,
      'airmass': airmass,
    };
  }

  factory CatalogStarMatch.fromJson(Map<String, dynamic> json) {
    return CatalogStarMatch(
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      raDegrees: (json['raDegrees'] as num?)?.toDouble() ?? 0.0,
      decDegrees: (json['decDegrees'] as num?)?.toDouble() ?? 0.0,
      catalogMagV: (json['catalogMagV'] as num?)?.toDouble() ?? 0.0,
      catalogMagB: (json['catalogMagB'] as num?)?.toDouble() ?? 0.0,
      instrumentalFlux: (json['instrumentalFlux'] as num?)?.toDouble() ?? 0.0,
      snr: (json['snr'] as num?)?.toDouble() ?? 0.0,
      airmass: (json['airmass'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

part of '../imaging_models.dart';

class NamingPattern extends Equatable {
  final String pattern;
  final String baseDir;
  final ImageFileFormat format;
  final bool createSubdirs;

  const NamingPattern({
    this.pattern = r'$TARGET/$FRAMETYPE/$TARGET_$FILTER_$EXPTIME_$FRAMENUM',
    this.baseDir = '.',
    this.format = ImageFileFormat.fits,
    this.createSubdirs = true,
  });

  NamingPattern copyWith({
    String? pattern,
    String? baseDir,
    ImageFileFormat? format,
    bool? createSubdirs,
  }) {
    return NamingPattern(
      pattern: pattern ?? this.pattern,
      baseDir: baseDir ?? this.baseDir,
      format: format ?? this.format,
      createSubdirs: createSubdirs ?? this.createSubdirs,
    );
  }

  @override
  List<Object?> get props => [pattern, baseDir, format, createSubdirs];

  /// Available pattern variables
  static const List<String> availableVariables = [
    r'$TARGET',
    r'$FILTER',
    r'$EXPTIME',
    r'$DATE',
    r'$TIME',
    r'$DATETIME',
    r'$FRAMETYPE',
    r'$FRAMENUM',
    r'$GAIN',
    r'$OFFSET',
    r'$TEMP',
    r'$BINNING',
    r'$CAMERA',
    r'$TELESCOPE',
    r'$SEQUENCE',
    r'$SESSION',
  ];
}

/// Star detection configuration
class StarDetectionConfig extends Equatable {
  final double detectionSigma;
  final int minArea;
  final int maxArea;
  final double maxEccentricity;
  final int saturationLimit;
  final int hfrRadius;

  const StarDetectionConfig({
    this.detectionSigma = 3.0,
    this.minArea = 5,
    this.maxArea = 10000,
    this.maxEccentricity = 0.8,
    this.saturationLimit = 60000,
    this.hfrRadius = 20,
  });

  @override
  List<Object?> get props => [
    detectionSigma,
    minArea,
    maxArea,
    maxEccentricity,
    saturationLimit,
    hfrRadius,
  ];
}

/// Per-filter autofocus configuration
///
/// Stores autofocus overrides for a specific filter. This allows different
/// filters to have their own AF exposure times, binning, gain/offset, and
/// focus offset values.
class FilterAutofocusConfig extends Equatable {
  /// Absolute focus offset for this filter (in focuser steps)
  final int focusOffset;

  /// Override AF exposure time for this filter (null = use default from settings)
  final double? afExposureTime;

  /// Which filter to actually use for AF when this filter is active
  /// (null = use the designated autofocus filter from settings)
  final String? afFilterName;

  /// AF binning for this filter
  final int binning;

  /// AF gain override (null = use camera default)
  final int? gain;

  /// AF offset override (null = use camera default)
  final int? offset;

  const FilterAutofocusConfig({
    this.focusOffset = 0,
    this.afExposureTime,
    this.afFilterName,
    this.binning = 1,
    this.gain,
    this.offset,
  });

  FilterAutofocusConfig copyWith({
    int? focusOffset,
    double? afExposureTime,
    bool clearAfExposureTime = false,
    String? afFilterName,
    bool clearAfFilterName = false,
    int? binning,
    int? gain,
    bool clearGain = false,
    int? offset,
    bool clearOffset = false,
  }) {
    return FilterAutofocusConfig(
      focusOffset: focusOffset ?? this.focusOffset,
      afExposureTime: clearAfExposureTime
          ? null
          : (afExposureTime ?? this.afExposureTime),
      afFilterName: clearAfFilterName
          ? null
          : (afFilterName ?? this.afFilterName),
      binning: binning ?? this.binning,
      gain: clearGain ? null : (gain ?? this.gain),
      offset: clearOffset ? null : (offset ?? this.offset),
    );
  }

  Map<String, dynamic> toJson() => {
    'focusOffset': focusOffset,
    'afExposureTime': afExposureTime,
    'afFilterName': afFilterName,
    'binning': binning,
    'gain': gain,
    'offset': offset,
  };

  factory FilterAutofocusConfig.fromJson(Map<String, dynamic> json) =>
      FilterAutofocusConfig(
        focusOffset: json['focusOffset'] as int? ?? 0,
        afExposureTime: (json['afExposureTime'] as num?)?.toDouble(),
        afFilterName: json['afFilterName'] as String?,
        binning: json['binning'] as int? ?? 1,
        gain: json['gain'] as int?,
        offset: json['offset'] as int?,
      );

  @override
  List<Object?> get props => [
    focusOffset,
    afExposureTime,
    afFilterName,
    binning,
    gain,
    offset,
  ];
}

/// Comprehensive autofocus settings grouped into a single typed object.
///
/// This is derived from AppSettings autofocus fields and provides a
/// convenient, typed view for the autofocus subsystem.
class AutofocusSettings extends Equatable {
  // General AF parameters
  final String method;
  final String curveFitting;
  final int stepSize;
  final double exposureTime;
  final int initialOffsetSteps;
  final int numberOfAttempts;
  final int useBrightestNStars;
  final double outerCropRatio;
  final double innerCropRatio;
  final int binning;
  final double rSquaredThreshold;

  /// Multiple of the reference HFR that a failed autofocus may leave the
  /// frames at and still be called usable in the operator's notice. A failed
  /// autofocus never parks or ends the run, whatever this says.
  final double failureHfrToleranceRatio;
  final bool disableGuidingDuringAf;
  final int focuserSettleTimeMs;
  final int exposuresPerPoint;

  // Backlash compensation
  final String backlashCompMethod;
  final int backlashIn;
  final int backlashOut;

  // Filter-specific
  final String autofocusFilterName;
  final Map<String, FilterAutofocusConfig> filterSettings;

  /// The curve-fitting strategies the app can solve a sweep with, and the
  /// single source of truth for every surface that offers the choice (the
  /// Settings > Autofocus row, the imaging Focus panel) — a surface with its
  /// own vocabulary renders blank for a valid saved value.
  ///
  /// These strings are the persisted values of `AppSettings.afCurveFitting`
  /// and are mapped onto the native curve enum by
  /// `autofocusCurveMethodForNativeBridge`.
  static const List<String> curveFittingOptions = [
    'Hyperbolic',
    'Parabolic',
    'Trend Lines',
  ];

  const AutofocusSettings({
    this.method = 'Star HFR',
    this.curveFitting = 'Hyperbolic',
    this.stepSize = 50,
    this.exposureTime = 4.0,
    this.initialOffsetSteps = 4,
    this.numberOfAttempts = 2,
    this.useBrightestNStars = 10,
    this.outerCropRatio = 1.0,
    this.innerCropRatio = 0.0,
    this.binning = 1,
    this.rSquaredThreshold = 0.7,
    this.failureHfrToleranceRatio = 1.6,
    this.disableGuidingDuringAf = false,
    this.focuserSettleTimeMs = 500,
    this.exposuresPerPoint = 1,
    this.backlashCompMethod = 'Overshoot',
    this.backlashIn = 350,
    this.backlashOut = 0,
    this.autofocusFilterName = '',
    this.filterSettings = const {},
  });

  AutofocusSettings copyWith({
    String? method,
    String? curveFitting,
    int? stepSize,
    double? exposureTime,
    int? initialOffsetSteps,
    int? numberOfAttempts,
    int? useBrightestNStars,
    double? outerCropRatio,
    double? innerCropRatio,
    int? binning,
    double? rSquaredThreshold,
    double? failureHfrToleranceRatio,
    bool? disableGuidingDuringAf,
    int? focuserSettleTimeMs,
    int? exposuresPerPoint,
    String? backlashCompMethod,
    int? backlashIn,
    int? backlashOut,
    String? autofocusFilterName,
    Map<String, FilterAutofocusConfig>? filterSettings,
  }) {
    return AutofocusSettings(
      method: method ?? this.method,
      curveFitting: curveFitting ?? this.curveFitting,
      stepSize: stepSize ?? this.stepSize,
      exposureTime: exposureTime ?? this.exposureTime,
      initialOffsetSteps: initialOffsetSteps ?? this.initialOffsetSteps,
      numberOfAttempts: numberOfAttempts ?? this.numberOfAttempts,
      useBrightestNStars: useBrightestNStars ?? this.useBrightestNStars,
      outerCropRatio: outerCropRatio ?? this.outerCropRatio,
      innerCropRatio: innerCropRatio ?? this.innerCropRatio,
      binning: binning ?? this.binning,
      rSquaredThreshold: rSquaredThreshold ?? this.rSquaredThreshold,
      failureHfrToleranceRatio:
          failureHfrToleranceRatio ?? this.failureHfrToleranceRatio,
      disableGuidingDuringAf:
          disableGuidingDuringAf ?? this.disableGuidingDuringAf,
      focuserSettleTimeMs: focuserSettleTimeMs ?? this.focuserSettleTimeMs,
      exposuresPerPoint: exposuresPerPoint ?? this.exposuresPerPoint,
      backlashCompMethod: backlashCompMethod ?? this.backlashCompMethod,
      backlashIn: backlashIn ?? this.backlashIn,
      backlashOut: backlashOut ?? this.backlashOut,
      autofocusFilterName: autofocusFilterName ?? this.autofocusFilterName,
      filterSettings: filterSettings ?? this.filterSettings,
    );
  }

  /// Parse filter settings from a JSON string stored in the database.
  ///
  /// Returns an empty map if the JSON is malformed rather than crashing,
  /// but logs a warning so the corruption is visible.
  static Map<String, FilterAutofocusConfig> parseFilterSettingsJson(
    String jsonStr,
  ) {
    if (jsonStr.isEmpty || jsonStr == '{}') return {};
    try {
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final result = <String, FilterAutofocusConfig>{};
      for (final entry in decoded.entries) {
        try {
          result[entry.key] = FilterAutofocusConfig.fromJson(
            entry.value as Map<String, dynamic>,
          );
        } catch (e) {
          // Skip malformed individual filter entries rather than losing all data
          assert(() {
            developer.log(
              'Skipping malformed filter config for "${entry.key}": $e',
              name: 'ImagingModels',
              level: 900,
            );
            return true;
          }());
        }
      }
      return result;
    } catch (e) {
      // Corrupted JSON in DB — return empty rather than crashing the app.
      // The next save will overwrite the corrupt data with valid JSON.
      assert(() {
        developer.log(
          'Failed to parse af_filter_settings JSON: $e',
          name: 'ImagingModels',
          level: 900,
        );
        return true;
      }());
      return {};
    }
  }

  /// Serialize filter settings to a JSON string for database storage.
  static String encodeFilterSettingsJson(
    Map<String, FilterAutofocusConfig> settings,
  ) {
    if (settings.isEmpty) return '{}';
    final map = settings.map((key, value) => MapEntry(key, value.toJson()));
    return jsonEncode(map);
  }

  @override
  List<Object?> get props => [
    method,
    curveFitting,
    stepSize,
    exposureTime,
    initialOffsetSteps,
    numberOfAttempts,
    useBrightestNStars,
    outerCropRatio,
    innerCropRatio,
    binning,
    rSquaredThreshold,
    failureHfrToleranceRatio,
    disableGuidingDuringAf,
    focuserSettleTimeMs,
    exposuresPerPoint,
    backlashCompMethod,
    backlashIn,
    backlashOut,
    autofocusFilterName,
    filterSettings,
  ];
}

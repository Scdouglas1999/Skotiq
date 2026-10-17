/// DepthLock goal models shared by every backend implementation.
///
/// These mirror the native `api_depthlock_*` contract but stay plain Dart so
/// the network backend can build them from JSON and the UI never sees
/// bridge-only types (`BigInt` revisions, `PlatformInt64` timestamps). The
/// JSON shape here is the headless wire shape: camelCase keys, revisions as
/// integers, timestamps as Unix milliseconds.
///
/// Units follow the native contract: sky positions in ICRS degrees, sizes in
/// arcseconds, intensities in ADU, scores dimensionless.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// Where a goal revision stands. `unreliable` describes the current
/// evidence, not the goal: more or cleaner data can move it back.
enum DepthLockState {
  insufficientEvidence,
  collecting,
  confirmationPending,
  achieved,
  unreliable;

  static DepthLockState fromWire(String value) => switch (value) {
    'insufficientEvidence' => DepthLockState.insufficientEvidence,
    'collecting' => DepthLockState.collecting,
    'confirmationPending' => DepthLockState.confirmationPending,
    'achieved' => DepthLockState.achieved,
    'unreliable' => DepthLockState.unreliable,
    _ => throw FormatException('Unknown DepthLock state: $value'),
  };

  String get wire => name;
}

/// A tangent-plane rectangle on the sky. Center in ICRS degrees, sides in
/// arcseconds, rotation = position angle of the height axis in degrees.
@immutable
class SkyRectangle {
  const SkyRectangle({
    required this.raDeg,
    required this.decDeg,
    required this.widthArcsec,
    required this.heightArcsec,
    required this.rotationDeg,
  });

  factory SkyRectangle.fromJson(Map<String, dynamic> json) => SkyRectangle(
    raDeg: (json['raDeg'] as num).toDouble(),
    decDeg: (json['decDeg'] as num).toDouble(),
    widthArcsec: (json['widthArcsec'] as num).toDouble(),
    heightArcsec: (json['heightArcsec'] as num).toDouble(),
    rotationDeg: (json['rotationDeg'] as num).toDouble(),
  );

  final double raDeg;
  final double decDeg;
  final double widthArcsec;
  final double heightArcsec;
  final double rotationDeg;

  Map<String, dynamic> toJson() => {
    'raDeg': raDeg,
    'decDeg': decDeg,
    'widthArcsec': widthArcsec,
    'heightArcsec': heightArcsec,
    'rotationDeg': rotationDeg,
  };

  @override
  bool operator ==(Object other) =>
      other is SkyRectangle &&
      other.raDeg == raDeg &&
      other.decDeg == decDeg &&
      other.widthArcsec == widthArcsec &&
      other.heightArcsec == heightArcsec &&
      other.rotationDeg == rotationDeg;

  @override
  int get hashCode =>
      Object.hash(raDeg, decDeg, widthArcsec, heightArcsec, rotationDeg);
}

/// The fixed measurement definition of a goal revision.
///
/// `scaleArcsec` is the aperture side; `threshold` the required
/// lower-quartile depth score (3–100); `minCoverage` the fraction of
/// apertures that must be measurable (0.9–1.0); `systematicFloorAdu` the
/// documented calibration error that is never averaged down, with
/// `systematicFloorSource` saying where that number came from.
@immutable
class DepthLockMeasurement {
  const DepthLockMeasurement({
    required this.region,
    required this.background,
    required this.scaleArcsec,
    required this.threshold,
    required this.minCoverage,
    required this.systematicFloorAdu,
    required this.systematicFloorSource,
  });

  factory DepthLockMeasurement.fromJson(Map<String, dynamic> json) =>
      DepthLockMeasurement(
        region: SkyRectangle.fromJson(json['region'] as Map<String, dynamic>),
        background: SkyRectangle.fromJson(
          json['background'] as Map<String, dynamic>,
        ),
        scaleArcsec: (json['scaleArcsec'] as num).toDouble(),
        threshold: (json['threshold'] as num).toDouble(),
        minCoverage: (json['minCoverage'] as num).toDouble(),
        systematicFloorAdu: (json['systematicFloorAdu'] as num).toDouble(),
        systematicFloorSource: json['systematicFloorSource'] as String,
      );

  final SkyRectangle region;
  final SkyRectangle background;
  final double scaleArcsec;
  final double threshold;
  final double minCoverage;
  final double systematicFloorAdu;
  final String systematicFloorSource;

  DepthLockMeasurement copyWith({
    SkyRectangle? region,
    SkyRectangle? background,
    double? scaleArcsec,
    double? threshold,
    double? minCoverage,
    double? systematicFloorAdu,
    String? systematicFloorSource,
  }) => DepthLockMeasurement(
    region: region ?? this.region,
    background: background ?? this.background,
    scaleArcsec: scaleArcsec ?? this.scaleArcsec,
    threshold: threshold ?? this.threshold,
    minCoverage: minCoverage ?? this.minCoverage,
    systematicFloorAdu: systematicFloorAdu ?? this.systematicFloorAdu,
    systematicFloorSource: systematicFloorSource ?? this.systematicFloorSource,
  );

  Map<String, dynamic> toJson() => {
    'region': region.toJson(),
    'background': background.toJson(),
    'scaleArcsec': scaleArcsec,
    'threshold': threshold,
    'minCoverage': minCoverage,
    'systematicFloorAdu': systematicFloorAdu,
    'systematicFloorSource': systematicFloorSource,
  };
}

/// A reference frame's frozen TAN geometry: FITS 1-based CRPIX, CD matrix
/// in degrees per pixel.
@immutable
class ReferenceGeometry {
  const ReferenceGeometry({
    required this.width,
    required this.height,
    required this.crval1,
    required this.crval2,
    required this.crpix1,
    required this.crpix2,
    required this.cd1_1,
    required this.cd1_2,
    required this.cd2_1,
    required this.cd2_2,
  });

  factory ReferenceGeometry.fromJson(Map<String, dynamic> json) =>
      ReferenceGeometry(
        width: json['width'] as int,
        height: json['height'] as int,
        crval1: (json['crval1'] as num).toDouble(),
        crval2: (json['crval2'] as num).toDouble(),
        crpix1: (json['crpix1'] as num).toDouble(),
        crpix2: (json['crpix2'] as num).toDouble(),
        cd1_1: (json['cd1_1'] as num).toDouble(),
        cd1_2: (json['cd1_2'] as num).toDouble(),
        cd2_1: (json['cd2_1'] as num).toDouble(),
        cd2_2: (json['cd2_2'] as num).toDouble(),
      );

  final int width;
  final int height;
  final double crval1;
  final double crval2;
  final double crpix1;
  final double crpix2;
  final double cd1_1;
  final double cd1_2;
  final double cd2_1;
  final double cd2_2;

  /// Native pixel scale in arcseconds per pixel (geometric mean).
  double get pixelScaleArcsec =>
      math.sqrt((cd1_1 * cd2_2 - cd1_2 * cd2_1).abs()) * 3600.0;

  @override
  bool operator ==(Object other) =>
      other is ReferenceGeometry &&
      other.width == width &&
      other.height == height &&
      other.crval1 == crval1 &&
      other.crval2 == crval2 &&
      other.crpix1 == crpix1 &&
      other.crpix2 == crpix2 &&
      other.cd1_1 == cd1_1 &&
      other.cd1_2 == cd1_2 &&
      other.cd2_1 == cd2_1 &&
      other.cd2_2 == cd2_2;

  @override
  int get hashCode => Object.hash(
    width,
    height,
    crval1,
    crval2,
    crpix1,
    crpix2,
    cd1_1,
    cd1_2,
    cd2_1,
    cd2_2,
  );

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'crval1': crval1,
    'crval2': crval2,
    'crpix1': crpix1,
    'crpix2': crpix2,
    'cd1_1': cd1_1,
    'cd1_2': cd1_2,
    'cd2_1': cd2_1,
    'cd2_2': cd2_2,
  };
}

/// The acquisition every contributing light must match.
@immutable
class AcquisitionSettings {
  const AcquisitionSettings({
    required this.instrument,
    required this.filter,
    required this.exposureSecs,
    required this.binX,
    required this.binY,
    this.gain,
    this.offset,
    this.ccdTempC,
  });

  factory AcquisitionSettings.fromJson(Map<String, dynamic> json) =>
      AcquisitionSettings(
        instrument: json['instrument'] as String,
        filter: json['filter'] as String,
        exposureSecs: (json['exposureSecs'] as num).toDouble(),
        gain: json['gain'] as int?,
        offset: json['offset'] as int?,
        binX: json['binX'] as int,
        binY: json['binY'] as int,
        ccdTempC: (json['ccdTempC'] as num?)?.toDouble(),
      );

  final String instrument;
  final String filter;
  final double exposureSecs;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;
  final double? ccdTempC;

  Map<String, dynamic> toJson() => {
    'instrument': instrument,
    'filter': filter,
    'exposureSecs': exposureSecs,
    'gain': gain,
    'offset': offset,
    'binX': binX,
    'binY': binY,
    'ccdTempC': ccdTempC,
  };
}

/// What a goal is, independent of any evidence gathered for it. Changing
/// anything but [enabled] and [automaticCompletion] is a new revision.
@immutable
class DepthLockGoalDefinition {
  const DepthLockGoalDefinition({
    required this.label,
    required this.projectId,
    required this.targetId,
    required this.profileId,
    required this.filterName,
    required this.filterIndex,
    required this.referencePath,
    required this.reference,
    required this.acquisition,
    required this.temperatureToleranceC,
    required this.darkPath,
    required this.flatPath,
    required this.measurement,
    required this.enabled,
    required this.automaticCompletion,
  });

  factory DepthLockGoalDefinition.fromJson(Map<String, dynamic> json) =>
      DepthLockGoalDefinition(
        label: json['label'] as String,
        projectId: json['projectId'] as String,
        targetId: json['targetId'] as String,
        profileId: json['profileId'] as String,
        filterName: json['filterName'] as String,
        filterIndex: json['filterIndex'] as int?,
        referencePath: json['referencePath'] as String,
        reference: ReferenceGeometry.fromJson(
          json['reference'] as Map<String, dynamic>,
        ),
        acquisition: AcquisitionSettings.fromJson(
          json['acquisition'] as Map<String, dynamic>,
        ),
        temperatureToleranceC: (json['temperatureToleranceC'] as num)
            .toDouble(),
        darkPath: json['darkPath'] as String,
        flatPath: json['flatPath'] as String,
        measurement: DepthLockMeasurement.fromJson(
          json['measurement'] as Map<String, dynamic>,
        ),
        enabled: json['enabled'] as bool,
        automaticCompletion: json['automaticCompletion'] as bool,
      );

  final String label;
  final String projectId;
  final String targetId;
  final String profileId;
  final String filterName;

  /// 0-based filter wheel slot when known.
  final int? filterIndex;
  final String referencePath;
  final ReferenceGeometry reference;
  final AcquisitionSettings acquisition;

  /// Accepted `CCD-TEMP` difference in °C when both sides carry it.
  final double temperatureToleranceC;
  final String darkPath;
  final String flatPath;
  final DepthLockMeasurement measurement;
  final bool enabled;
  final bool automaticCompletion;

  DepthLockGoalDefinition copyWith({
    String? label,
    String? filterName,
    int? filterIndex,
    DepthLockMeasurement? measurement,
    bool? enabled,
    bool? automaticCompletion,
    String? darkPath,
    String? flatPath,
    double? temperatureToleranceC,
  }) => DepthLockGoalDefinition(
    label: label ?? this.label,
    projectId: projectId,
    targetId: targetId,
    profileId: profileId,
    filterName: filterName ?? this.filterName,
    filterIndex: filterIndex ?? this.filterIndex,
    referencePath: referencePath,
    reference: reference,
    acquisition: acquisition,
    temperatureToleranceC: temperatureToleranceC ?? this.temperatureToleranceC,
    darkPath: darkPath ?? this.darkPath,
    flatPath: flatPath ?? this.flatPath,
    measurement: measurement ?? this.measurement,
    enabled: enabled ?? this.enabled,
    automaticCompletion: automaticCompletion ?? this.automaticCompletion,
  );

  Map<String, dynamic> toJson() => {
    'label': label,
    'projectId': projectId,
    'targetId': targetId,
    'profileId': profileId,
    'filterName': filterName,
    'filterIndex': filterIndex,
    'referencePath': referencePath,
    'reference': reference.toJson(),
    'acquisition': acquisition.toJson(),
    'temperatureToleranceC': temperatureToleranceC,
    'darkPath': darkPath,
    'flatPath': flatPath,
    'measurement': measurement.toJson(),
    'enabled': enabled,
    'automaticCompletion': automaticCompletion,
  };
}

/// What reaching the goal is expected to cost, projected from the same noise
/// model the score uses. Frames, not hours: multiply by the goal's exposure.
/// A projection that assumes the sky stays as it has been, not a promise.
@immutable
class DepthLockForecast {
  const DepthLockForecast({
    required this.framesToThreshold,
    required this.framesToConfirm,
    required this.reachable,
    required this.ceilingScore,
    required this.perFrameNoiseAdu,
    required this.recentFrameNoiseAdu,
    required this.bestFrameNoiseAdu,
  });

  factory DepthLockForecast.fromJson(Map<String, dynamic> json) =>
      DepthLockForecast(
        framesToThreshold: json['framesToThreshold'] as int,
        framesToConfirm: json['framesToConfirm'] as int,
        reachable: json['reachable'] as bool,
        ceilingScore: (json['ceilingScore'] as num).toDouble(),
        perFrameNoiseAdu: (json['perFrameNoiseAdu'] as num).toDouble(),
        recentFrameNoiseAdu: (json['recentFrameNoiseAdu'] as num).toDouble(),
        bestFrameNoiseAdu: (json['bestFrameNoiseAdu'] as num).toDouble(),
      );

  /// Exposures still needed to cross the threshold; zero once crossed.
  final int framesToThreshold;

  /// Exposures still needed after the crossing for confirmation.
  final int framesToConfirm;

  /// False when the calibration floor caps the score below the threshold.
  final bool reachable;

  /// The lower-quartile score the floor allows with unlimited exposures.
  final double ceilingScore;

  /// Median per-cell noise one exposure adds, ADU.
  final double perFrameNoiseAdu;

  /// Background scatter of the newest exposures, ADU per cell.
  final double recentFrameNoiseAdu;

  /// The quietest stretch the goal has seen, ADU per cell.
  final double bestFrameNoiseAdu;

  int get framesRemaining => framesToThreshold + framesToConfirm;

  /// How much one of the newest exposures moves the goal, relative to one
  /// from the best stretch: noise variance ratio, so 0.5 means two of
  /// tonight's frames are worth one good one.
  double get recentYield {
    if (!(recentFrameNoiseAdu > 0) || !(bestFrameNoiseAdu > 0)) return 1.0;
    final ratio = bestFrameNoiseAdu / recentFrameNoiseAdu;
    return (ratio * ratio).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    'framesToThreshold': framesToThreshold,
    'framesToConfirm': framesToConfirm,
    'reachable': reachable,
    'ceilingScore': ceilingScore,
    'perFrameNoiseAdu': perFrameNoiseAdu,
    'recentFrameNoiseAdu': recentFrameNoiseAdu,
    'bestFrameNoiseAdu': bestFrameNoiseAdu,
  };
}

/// One point of a goal's score history, or of its projection.
@immutable
class DepthLockCurvePoint {
  const DepthLockCurvePoint({
    required this.frames,
    required this.score,
    required this.conservativeScore,
    required this.projected,
  });

  factory DepthLockCurvePoint.fromJson(Map<String, dynamic> json) =>
      DepthLockCurvePoint(
        frames: json['frames'] as int,
        score: (json['score'] as num).toDouble(),
        conservativeScore: (json['conservativeScore'] as num).toDouble(),
        projected: json['projected'] as bool,
      );

  final int frames;
  final double score;
  final double conservativeScore;
  final bool projected;

  Map<String, dynamic> toJson() => {
    'frames': frames,
    'score': score,
    'conservativeScore': conservativeScore,
    'projected': projected,
  };
}

/// One committed evaluation. [score] is the lower-quartile depth score,
/// [conservativeScore] the same minus the repeated-look margin (what the
/// threshold is compared against), [uncertaintyAdu] the median per-cell
/// uncertainty — a summary, not an interval on the score.
@immutable
class DepthLockReport {
  const DepthLockReport({
    required this.state,
    required this.coverage,
    required this.evidenceFrames,
    required this.confirmationFrames,
    required this.reason,
    this.score,
    this.conservativeScore,
    this.uncertaintyAdu,
    this.forecast,
  });

  factory DepthLockReport.fromJson(Map<String, dynamic> json) =>
      DepthLockReport(
        state: DepthLockState.fromWire(json['state'] as String),
        score: (json['score'] as num?)?.toDouble(),
        conservativeScore: (json['conservativeScore'] as num?)?.toDouble(),
        uncertaintyAdu: (json['uncertaintyAdu'] as num?)?.toDouble(),
        coverage: (json['coverage'] as num).toDouble(),
        evidenceFrames: json['evidenceFrames'] as int,
        confirmationFrames: json['confirmationFrames'] as int,
        reason: json['reason'] as String,
        forecast: json['forecast'] == null
            ? null
            : DepthLockForecast.fromJson(
                json['forecast'] as Map<String, dynamic>,
              ),
      );

  final DepthLockState state;
  final double? score;
  final double? conservativeScore;
  final double? uncertaintyAdu;
  final double coverage;
  final int evidenceFrames;
  final int confirmationFrames;
  final String reason;
  final DepthLockForecast? forecast;

  Map<String, dynamic> toJson() => {
    'state': state.wire,
    'score': score,
    'conservativeScore': conservativeScore,
    'uncertaintyAdu': uncertaintyAdu,
    'coverage': coverage,
    'evidenceFrames': evidenceFrames,
    'confirmationFrames': confirmationFrames,
    'reason': reason,
    'forecast': forecast?.toJson(),
  };
}

/// A persistent goal as the store holds it.
@immutable
class DepthLockGoal {
  const DepthLockGoal({
    required this.id,
    required this.revision,
    required this.definition,
    required this.selectedAtMs,
    required this.evidenceFrames,
    required this.evidenceRevision,
    required this.analysisCurrent,
    required this.candidateFrames,
    required this.archivedRevisions,
    required this.estimatorVersion,
    this.report,
    this.lastIssue,
  });

  factory DepthLockGoal.fromJson(Map<String, dynamic> json) => DepthLockGoal(
    id: json['id'] as String,
    revision: json['revision'] as int,
    definition: DepthLockGoalDefinition.fromJson(
      json['definition'] as Map<String, dynamic>,
    ),
    selectedAtMs: json['selectedAtMs'] as int,
    evidenceFrames: json['evidenceFrames'] as int,
    evidenceRevision: json['evidenceRevision'] as int,
    analysisCurrent: json['analysisCurrent'] as bool,
    report: json['report'] == null
        ? null
        : DepthLockReport.fromJson(json['report'] as Map<String, dynamic>),
    candidateFrames: json['candidateFrames'] as int,
    lastIssue: json['lastIssue'] as String?,
    archivedRevisions: json['archivedRevisions'] as int,
    estimatorVersion: json['estimatorVersion'] as int,
  );

  final String id;
  final int revision;
  final DepthLockGoalDefinition definition;

  /// When this revision was selected (Unix ms); only later exposures count.
  final int selectedAtMs;
  final int evidenceFrames;
  final int evidenceRevision;

  /// True when [report] was computed over exactly the current evidence.
  final bool analysisCurrent;
  final DepthLockReport? report;

  /// Exposures frozen in a provisional candidate awaiting confirmation.
  final int candidateFrames;
  final String? lastIssue;
  final int archivedRevisions;
  final int estimatorVersion;

  DepthLockState get state =>
      report?.state ?? DepthLockState.insufficientEvidence;

  Map<String, dynamic> toJson() => {
    'id': id,
    'revision': revision,
    'definition': definition.toJson(),
    'selectedAtMs': selectedAtMs,
    'evidenceFrames': evidenceFrames,
    'evidenceRevision': evidenceRevision,
    'analysisCurrent': analysisCurrent,
    'report': report?.toJson(),
    'candidateFrames': candidateFrames,
    'lastIssue': lastIssue,
    'archivedRevisions': archivedRevisions,
    'estimatorVersion': estimatorVersion,
  };
}

/// What a candidate reference file offers; geometry and acquisition each
/// come with their own refusal reason so the UI can say what is missing.
@immutable
class DepthLockReferenceInfo {
  const DepthLockReferenceInfo({
    required this.width,
    required this.height,
    required this.pixelType,
    required this.monochrome,
    this.geometry,
    this.geometryIssue,
    this.pixelScaleArcsec,
    this.acquisition,
    this.acquisitionIssue,
  });

  factory DepthLockReferenceInfo.fromJson(Map<String, dynamic> json) =>
      DepthLockReferenceInfo(
        width: json['width'] as int,
        height: json['height'] as int,
        pixelType: json['pixelType'] as String,
        monochrome: json['monochrome'] as bool,
        geometry: json['geometry'] == null
            ? null
            : ReferenceGeometry.fromJson(
                json['geometry'] as Map<String, dynamic>,
              ),
        geometryIssue: json['geometryIssue'] as String?,
        pixelScaleArcsec: (json['pixelScaleArcsec'] as num?)?.toDouble(),
        acquisition: json['acquisition'] == null
            ? null
            : AcquisitionSettings.fromJson(
                json['acquisition'] as Map<String, dynamic>,
              ),
        acquisitionIssue: json['acquisitionIssue'] as String?,
      );

  final int width;
  final int height;
  final String pixelType;
  final bool monochrome;
  final ReferenceGeometry? geometry;
  final String? geometryIssue;
  final double? pixelScaleArcsec;
  final AcquisitionSettings? acquisition;
  final String? acquisitionIssue;

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'pixelType': pixelType,
    'monochrome': monochrome,
    'geometry': geometry?.toJson(),
    'geometryIssue': geometryIssue,
    'pixelScaleArcsec': pixelScaleArcsec,
    'acquisition': acquisition?.toJson(),
    'acquisitionIssue': acquisitionIssue,
  };
}

/// Analysis-queue health for the status surface.
@immutable
class DepthLockStatus {
  const DepthLockStatus({
    required this.available,
    required this.goals,
    required this.queueCapacity,
    required this.queued,
    required this.processed,
    required this.dropped,
    required this.evidenceAdded,
    required this.evidenceRejected,
    required this.lastFrameMs,
    required this.maxFrameMs,
  });

  factory DepthLockStatus.fromJson(Map<String, dynamic> json) =>
      DepthLockStatus(
        available: json['available'] as bool,
        goals: json['goals'] as int,
        queueCapacity: json['queueCapacity'] as int,
        queued: json['queued'] as int,
        processed: json['processed'] as int,
        dropped: json['dropped'] as int,
        evidenceAdded: json['evidenceAdded'] as int,
        evidenceRejected: json['evidenceRejected'] as int,
        lastFrameMs: json['lastFrameMs'] as int,
        maxFrameMs: json['maxFrameMs'] as int,
      );

  final bool available;
  final int goals;
  final int queueCapacity;
  final int queued;
  final int processed;
  final int dropped;
  final int evidenceAdded;
  final int evidenceRejected;
  final int lastFrameMs;
  final int maxFrameMs;

  Map<String, dynamic> toJson() => {
    'available': available,
    'goals': goals,
    'queueCapacity': queueCapacity,
    'queued': queued,
    'processed': processed,
    'dropped': dropped,
    'evidenceAdded': evidenceAdded,
    'evidenceRejected': evidenceRejected,
    'lastFrameMs': lastFrameMs,
    'maxFrameMs': maxFrameMs,
  };
}

/// What became of one frame offered to one goal. [outcome] is one of
/// `added`, `duplicate`, `alreadyAchieved`, `preSelection`, `rejected`.
@immutable
class DepthLockIngestOutcome {
  const DepthLockIngestOutcome({
    required this.outcome,
    this.state,
    this.reason,
  });

  factory DepthLockIngestOutcome.fromJson(Map<String, dynamic> json) =>
      DepthLockIngestOutcome(
        outcome: json['outcome'] as String,
        state: json['state'] == null
            ? null
            : DepthLockState.fromWire(json['state'] as String),
        reason: json['reason'] as String?,
      );

  final String outcome;
  final DepthLockState? state;
  final String? reason;

  Map<String, dynamic> toJson() => {
    'outcome': outcome,
    'state': state?.wire,
    'reason': reason,
  };
}

/// A calibration error floor derived from the goal's own master frames: the
/// masters' pixel noise averaged over the aperture. [source] is the
/// derivation in words, ready to be stored as `systematicFloorSource`.
@immutable
class DepthLockFloorSuggestion {
  const DepthLockFloorSuggestion({
    required this.floorAdu,
    required this.darkNoiseAdu,
    required this.flatRelativeNoise,
    required this.skyAdu,
    required this.aperturePixels,
    required this.source,
  });

  factory DepthLockFloorSuggestion.fromJson(Map<String, dynamic> json) =>
      DepthLockFloorSuggestion(
        floorAdu: (json['floorAdu'] as num).toDouble(),
        darkNoiseAdu: (json['darkNoiseAdu'] as num).toDouble(),
        flatRelativeNoise: (json['flatRelativeNoise'] as num).toDouble(),
        skyAdu: (json['skyAdu'] as num).toDouble(),
        aperturePixels: (json['aperturePixels'] as num).toDouble(),
        source: json['source'] as String,
      );

  final double floorAdu;
  final double darkNoiseAdu;
  final double flatRelativeNoise;
  final double skyAdu;
  final double aperturePixels;
  final String source;

  Map<String, dynamic> toJson() => {
    'floorAdu': floorAdu,
    'darkNoiseAdu': darkNoiseAdu,
    'flatRelativeNoise': flatRelativeNoise,
    'skyAdu': skyAdu,
    'aperturePixels': aperturePixels,
    'source': source,
  };
}

/// Value types for the Calibration Library Manager.
///
/// The library presents one unified view over the three existing master
/// stores — `dark_library` (darks + biases), `flat_library` (master flats),
/// and `defect_maps` — plus the v46 `calibration_tags` annotation table.
/// [CalibrationMasterRecord] is that unified row; [LightFrameContext] +
/// [CalibrationMatch] are the transparent auto-matching surface consumed by
/// the post-session integration pipeline and the matching-preview UI.
library;

import '../collaboration/collaboration_models.dart';
import 'dark_library_match_tolerances.dart';

/// The master-calibration artifact kinds the library manages.
enum CalibrationMasterType { dark, bias, flat, defectMap }

/// Stable wire name for a [CalibrationMasterType] (used by the headless API
/// and the `calibration_tags.master_type` column).
String calibrationMasterTypeWireName(CalibrationMasterType type) {
  return switch (type) {
    CalibrationMasterType.dark => 'dark',
    CalibrationMasterType.bias => 'bias',
    CalibrationMasterType.flat => 'flat',
    CalibrationMasterType.defectMap => 'defectMap',
  };
}

/// Parse a wire name back to a [CalibrationMasterType]; null when unknown.
CalibrationMasterType? calibrationMasterTypeFromWire(String raw) {
  return switch (raw.trim()) {
    'dark' => CalibrationMasterType.dark,
    'bias' => CalibrationMasterType.bias,
    'flat' => CalibrationMasterType.flat,
    'defectMap' ||
    'defect_map' ||
    'defect-map' => CalibrationMasterType.defectMap,
    _ => null,
  };
}

/// Age classification of a master, derived from per-type thresholds.
enum CalibrationFreshness { fresh, aging, stale }

/// Per-type staleness thresholds in days. A master is `stale` past its
/// threshold and `aging` past half of it.
///
/// Defaults follow the practical guidance baked into the rest of the app:
/// darks drift with sensor aging (~90 days), flats go bad as soon as dust or
/// the optical train moves (~7 days), biases are extremely stable (~180
/// days), and defect maps track dark health (~90 days).
class CalibrationStalenessThresholds {
  final int darkStaleDays;
  final int biasStaleDays;
  final int flatStaleDays;
  final int defectMapStaleDays;

  const CalibrationStalenessThresholds({
    this.darkStaleDays = 90,
    this.biasStaleDays = 180,
    this.flatStaleDays = 7,
    this.defectMapStaleDays = 90,
  });

  static const CalibrationStalenessThresholds defaults =
      CalibrationStalenessThresholds();

  int staleDaysFor(CalibrationMasterType type) {
    return switch (type) {
      CalibrationMasterType.dark => darkStaleDays,
      CalibrationMasterType.bias => biasStaleDays,
      CalibrationMasterType.flat => flatStaleDays,
      CalibrationMasterType.defectMap => defectMapStaleDays,
    };
  }
}

/// One master artifact in the unified calibration library view.
///
/// `id` is the row id in the artifact's *source* table (`dark_library`,
/// `flat_library`, or `defect_maps`), so `(type, id)` is the library-wide
/// identity — the same key the `calibration_tags` table uses.
class CalibrationMasterRecord {
  final CalibrationMasterType type;
  final int id;

  /// On-disk artifact path. Nullable because a defect map row may exist with
  /// only its DB-blob mirror (no `.ndm` file recorded).
  final String? filePath;

  /// False for raw (un-stacked) `dark_library` frames; true for every other
  /// kind, which are masters by construction.
  final bool isMaster;

  /// Number of raw frames combined into this master (when known).
  final int? frameCount;

  final double? exposureSeconds;
  final double? temperature;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;
  final String? filter;

  /// `'sky'` | `'panel'` | `'dome'` for flats; null otherwise.
  final String? flatKind;
  final int? width;
  final int? height;

  /// Camera identity. Stored natively only for defect maps; for darks/flats
  /// it is enriched from the FITS `INSTRUME` header and cached in
  /// `calibration_tags.camera_id`.
  final String? cameraId;
  final String? opticalTrainId;
  final DateTime createdAt;

  /// User tags + notes from `calibration_tags` (empty when untagged).
  final List<String> tags;
  final String? notes;

  /// Shared-library provenance (null for purely local masters):
  ///  * [remoteId] — the hub master id; non-null marks a REMOTE candidate that
  ///    has not (yet) been downloaded into the local library ([isRemote]).
  ///  * [sourceHubKey] — the hub the candidate came from (`scheme://host:port`).
  ///  * [provenance] — who/what produced it (frame count, dark current, sensor
  ///    dims, authoritative producer) — the trust surface the matcher exposes.
  ///  * [license] — the consented reuse license the producer published under.
  ///  * [sharedBy] — the authoritative display-name credit string (when known).
  ///  * [publishedRemoteId] — set on a LOCAL master the user has PUBLISHED to a
  ///    hub: the hub master id to retract (un-share) by. Distinct from
  ///    [remoteId], which marks an inbound REMOTE candidate.
  final String? remoteId;
  final String? sourceHubKey;
  final Provenance? provenance;
  final ContributionLicense? license;
  final String? sharedBy;
  final String? publishedRemoteId;

  const CalibrationMasterRecord({
    required this.type,
    required this.id,
    required this.filePath,
    required this.isMaster,
    this.frameCount,
    this.exposureSeconds,
    this.temperature,
    this.gain,
    this.offset,
    this.binX = 1,
    this.binY = 1,
    this.filter,
    this.flatKind,
    this.width,
    this.height,
    this.cameraId,
    this.opticalTrainId,
    required this.createdAt,
    this.tags = const [],
    this.notes,
    this.remoteId,
    this.sourceHubKey,
    this.provenance,
    this.license,
    this.sharedBy,
    this.publishedRemoteId,
  });

  /// True when this record is a REMOTE shared-library candidate (a hub master id
  /// is set) rather than a master already present in the local library.
  bool get isRemote => remoteId != null;

  /// True when this LOCAL master has been published to a hub and can be
  /// retracted (un-shared) — i.e. it carries a [publishedRemoteId].
  bool get isPublished =>
      publishedRemoteId != null && publishedRemoteId!.isNotEmpty;

  int ageDays(DateTime now) {
    final age = now.difference(createdAt).inDays;
    return age < 0 ? 0 : age;
  }

  CalibrationFreshness freshness(
    DateTime now, {
    CalibrationStalenessThresholds thresholds =
        CalibrationStalenessThresholds.defaults,
  }) {
    final staleDays = thresholds.staleDaysFor(type);
    final age = ageDays(now);
    if (age > staleDays) return CalibrationFreshness.stale;
    if (age * 2 >= staleDays) return CalibrationFreshness.aging;
    return CalibrationFreshness.fresh;
  }

  CalibrationMasterRecord copyWith({
    String? filePath,
    double? exposureSeconds,
    double? temperature,
    int? gain,
    int? offset,
    String? filter,
    String? cameraId,
    List<String>? tags,
    String? notes,
  }) {
    return CalibrationMasterRecord(
      type: type,
      id: id,
      filePath: filePath ?? this.filePath,
      isMaster: isMaster,
      frameCount: frameCount,
      exposureSeconds: exposureSeconds ?? this.exposureSeconds,
      temperature: temperature ?? this.temperature,
      gain: gain ?? this.gain,
      offset: offset ?? this.offset,
      binX: binX,
      binY: binY,
      filter: filter ?? this.filter,
      flatKind: flatKind,
      width: width,
      height: height,
      cameraId: cameraId ?? this.cameraId,
      opticalTrainId: opticalTrainId,
      createdAt: createdAt,
      tags: tags ?? this.tags,
      notes: notes ?? this.notes,
      remoteId: remoteId,
      sourceHubKey: sourceHubKey,
      provenance: provenance,
      license: license,
      sharedBy: sharedBy,
      publishedRemoteId: publishedRemoteId,
    );
  }

  /// Reconstruct a record from the headless API's [toJson] envelope. The
  /// server-only `ageDays`/`freshness` fields are recomputed locally from
  /// [createdAt], so they are ignored here.
  factory CalibrationMasterRecord.fromJson(Map<String, dynamic> json) {
    final type =
        calibrationMasterTypeFromWire('${json['type']}') ??
        CalibrationMasterType.dark;
    return CalibrationMasterRecord(
      type: type,
      id: (json['id'] as num).toInt(),
      filePath: json['filePath'] as String?,
      isMaster: json['isMaster'] as bool? ?? false,
      frameCount: (json['frameCount'] as num?)?.toInt(),
      exposureSeconds: (json['exposureSeconds'] as num?)?.toDouble(),
      temperature: (json['temperature'] as num?)?.toDouble(),
      gain: (json['gain'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
      binX: (json['binX'] as num?)?.toInt() ?? 1,
      binY: (json['binY'] as num?)?.toInt() ?? 1,
      filter: json['filter'] as String?,
      flatKind: json['flatKind'] as String?,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      cameraId: json['cameraId'] as String?,
      opticalTrainId: json['opticalTrainId'] as String?,
      createdAt:
          DateTime.tryParse('${json['createdAt']}')?.toLocal() ??
          DateTime.now(),
      tags: [for (final t in (json['tags'] as List? ?? const [])) t.toString()],
      notes: json['notes'] as String?,
      remoteId: json['remoteId'] as String?,
      sourceHubKey: json['sourceHubKey'] as String?,
      provenance: json['provenance'] is Map
          ? Provenance.fromJson(
              (json['provenance'] as Map).cast<String, dynamic>(),
            )
          : null,
      license: json['license'] is String
          ? ContributionLicense.fromWire(json['license'] as String)
          : null,
      sharedBy: json['sharedBy'] as String?,
      publishedRemoteId: json['publishedRemoteId'] as String?,
    );
  }

  Map<String, dynamic> toJson({DateTime? now}) {
    final at = now ?? DateTime.now();
    return {
      'type': calibrationMasterTypeWireName(type),
      'id': id,
      if (filePath != null) 'filePath': filePath,
      'isMaster': isMaster,
      if (frameCount != null) 'frameCount': frameCount,
      if (exposureSeconds != null) 'exposureSeconds': exposureSeconds,
      if (temperature != null) 'temperature': temperature,
      if (gain != null) 'gain': gain,
      if (offset != null) 'offset': offset,
      'binX': binX,
      'binY': binY,
      if (filter != null) 'filter': filter,
      if (flatKind != null) 'flatKind': flatKind,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (cameraId != null) 'cameraId': cameraId,
      if (opticalTrainId != null) 'opticalTrainId': opticalTrainId,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'ageDays': ageDays(at),
      'freshness': freshness(at).name,
      'tags': tags,
      if (notes != null) 'notes': notes,
      if (remoteId != null) 'remoteId': remoteId,
      if (sourceHubKey != null) 'sourceHubKey': sourceHubKey,
      if (provenance != null) 'provenance': provenance!.toJson(),
      if (license != null) 'license': license!.wireName,
      if (sharedBy != null) 'sharedBy': sharedBy,
      if (publishedRemoteId != null) 'publishedRemoteId': publishedRemoteId,
    };
  }
}

/// Independent filters for listing the library. Null means "do not filter on
/// this dimension".
class CalibrationLibraryFilter {
  final CalibrationMasterType? type;
  final String? cameraId;
  final int? gain;
  final double? temperatureMin;
  final double? temperatureMax;
  final double? exposureSeconds;
  final double exposureToleranceSecs;
  final String? filter;
  final int? binX;
  final int? binY;

  /// When true, raw (un-stacked) `dark_library` frames are excluded.
  final bool mastersOnly;

  const CalibrationLibraryFilter({
    this.type,
    this.cameraId,
    this.gain,
    this.temperatureMin,
    this.temperatureMax,
    this.exposureSeconds,
    this.exposureToleranceSecs = 0.5,
    this.filter,
    this.binX,
    this.binY,
    this.mastersOnly = true,
  });
}

/// Capture parameters of the light frames a calibration set is matched for.
class LightFrameContext {
  final String? cameraId;

  /// Sensor gain / read offset the lights were captured at, or null when the
  /// capture metadata never recorded them (`captured_images.gain` and
  /// `.offset` are both nullable, and a driver that does not report them
  /// leaves the column empty).
  ///
  /// Both are HARD match requirements when known — a master shot at another
  /// gain has a different dark-current scale, and one at another offset a
  /// different read pedestal. When null the matcher cannot compare the
  /// dimension at all: it drops out of the candidate filter, the pick reports
  /// it as unverified, and no number is invented for it. Substituting 0 here
  /// would either hand the lights the masters of a gain-0 library or reject
  /// every candidate the camera actually produced.
  final int? gain;
  final int? offset;
  final double exposureSeconds;
  final double? temperature;
  final String? filter;
  final int binX;
  final int binY;
  final String? opticalTrainId;

  /// Sensor dimensions of the light frames in pixels, when known. The quality
  /// gate refuses a REMOTE master whose recorded sensor dimensions do not match
  /// these (a master from a different sensor geometry can never calibrate this
  /// frame, no matter how well the tuple matches).
  final int? sensorWidth;
  final int? sensorHeight;

  const LightFrameContext({
    this.cameraId,
    required this.gain,
    required this.offset,
    required this.exposureSeconds,
    this.temperature,
    this.filter,
    this.binX = 1,
    this.binY = 1,
    this.opticalTrainId,
    this.sensorWidth,
    this.sensorHeight,
  });

  factory LightFrameContext.fromJson(Map<String, dynamic> json) =>
      LightFrameContext(
        cameraId: json['cameraId'] as String?,
        // An absent gain/offset stays absent across the wire: the sender is
        // saying it does not know, and the matcher reports that dimension
        // unverified rather than matching against a number nobody measured.
        gain: (json['gain'] as num?)?.toInt(),
        offset: (json['offset'] as num?)?.toInt(),
        exposureSeconds: (json['exposureSeconds'] as num?)?.toDouble() ?? 0.0,
        temperature: (json['temperature'] as num?)?.toDouble(),
        filter: json['filter'] as String?,
        binX: (json['binX'] as num?)?.toInt() ?? 1,
        binY: (json['binY'] as num?)?.toInt() ?? 1,
        opticalTrainId: json['opticalTrainId'] as String?,
        sensorWidth: (json['sensorWidth'] as num?)?.toInt(),
        sensorHeight: (json['sensorHeight'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
    if (cameraId != null) 'cameraId': cameraId,
    if (gain != null) 'gain': gain,
    if (offset != null) 'offset': offset,
    'exposureSeconds': exposureSeconds,
    if (temperature != null) 'temperature': temperature,
    if (filter != null) 'filter': filter,
    'binX': binX,
    'binY': binY,
    if (opticalTrainId != null) 'opticalTrainId': opticalTrainId,
    if (sensorWidth != null) 'sensorWidth': sensorWidth,
    if (sensorHeight != null) 'sensorHeight': sensorHeight,
  };
}

/// Tolerances consulted by [CalibrationLibraryService.match]. Dark exposure /
/// temperature tolerances reuse the unified
/// [DarkLibraryMatchTolerances] so the library manager can never disagree
/// with the coverage UI or the runtime DAO matcher.
class CalibrationMatchTolerances {
  final DarkLibraryMatchTolerances dark;

  /// Flats tolerate a wider temperature window than darks (vignetting/dust
  /// geometry is temperature-insensitive; only amp glow in flat-darks cares).
  final double flatTemperatureC;

  const CalibrationMatchTolerances({
    this.dark = DarkLibraryMatchTolerances.defaults,
    this.flatTemperatureC = 5.0,
  });

  static const CalibrationMatchTolerances defaults =
      CalibrationMatchTolerances();
}

/// One per-type auto-match result with a transparent score.
///
/// `score` is 0..100: 100 is a perfect exact match; every deviation
/// (temperature delta, exposure scaling, staleness, unknown metadata)
/// subtracts a documented penalty and appends a human-readable line to
/// [reasons] (why it was picked) or [warnings] (what to double-check).
class CalibrationMatch {
  final CalibrationMasterRecord record;
  final double score;
  final List<String> reasons;
  final List<String> warnings;

  /// True when the chosen dark's exposure differs from the light exposure by
  /// more than the exact-match tolerance and must be optimally scaled during
  /// calibration. [exposureScaleFactor] is `lightExposure / darkExposure`.
  final bool exposureScaled;
  final double? exposureScaleFactor;

  const CalibrationMatch({
    required this.record,
    required this.score,
    this.reasons = const [],
    this.warnings = const [],
    this.exposureScaled = false,
    this.exposureScaleFactor,
  });

  /// Reconstruct a per-type match from the headless API envelope.
  factory CalibrationMatch.fromJson(Map<String, dynamic> json) =>
      CalibrationMatch(
        record: CalibrationMasterRecord.fromJson(
          (json['record'] as Map).cast<String, dynamic>(),
        ),
        score: (json['score'] as num?)?.toDouble() ?? 0.0,
        reasons: [
          for (final r in (json['reasons'] as List? ?? const [])) r.toString(),
        ],
        warnings: [
          for (final w in (json['warnings'] as List? ?? const [])) w.toString(),
        ],
        exposureScaled: json['exposureScaled'] as bool? ?? false,
        exposureScaleFactor: (json['exposureScaleFactor'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson({DateTime? now}) => {
    'record': record.toJson(now: now),
    'score': score,
    'reasons': reasons,
    'warnings': warnings,
    'exposureScaled': exposureScaled,
    if (exposureScaleFactor != null) 'exposureScaleFactor': exposureScaleFactor,
  };
}

/// The best master per type for one [LightFrameContext], plus the warnings
/// for types that found nothing.
class CalibrationMatchSet {
  final LightFrameContext context;
  final CalibrationMatch? dark;
  final CalibrationMatch? bias;
  final CalibrationMatch? flat;
  final CalibrationMatch? defectMap;

  /// Set-level warnings (e.g. "No master dark matches gain 100 / offset 30").
  final List<String> warnings;

  const CalibrationMatchSet({
    required this.context,
    this.dark,
    this.bias,
    this.flat,
    this.defectMap,
    this.warnings = const [],
  });

  /// Every warning in the set: per-match warnings plus the set-level ones.
  List<String> get allWarnings => [
    ...warnings,
    ...?dark?.warnings,
    ...?bias?.warnings,
    ...?flat?.warnings,
    ...?defectMap?.warnings,
  ];

  /// Reconstruct a match set from the headless API's [toJson] envelope.
  factory CalibrationMatchSet.fromJson(Map<String, dynamic> json) {
    CalibrationMatch? matchAt(String key) {
      final raw = json[key];
      return raw is Map
          ? CalibrationMatch.fromJson(raw.cast<String, dynamic>())
          : null;
    }

    return CalibrationMatchSet(
      context: LightFrameContext.fromJson(
        (json['context'] as Map? ?? const {}).cast<String, dynamic>(),
      ),
      dark: matchAt('dark'),
      bias: matchAt('bias'),
      flat: matchAt('flat'),
      defectMap: matchAt('defectMap'),
      warnings: [
        for (final w in (json['warnings'] as List? ?? const [])) w.toString(),
      ],
    );
  }

  Map<String, dynamic> toJson({DateTime? now}) => {
    'context': context.toJson(),
    if (dark != null) 'dark': dark!.toJson(now: now),
    if (bias != null) 'bias': bias!.toJson(now: now),
    if (flat != null) 'flat': flat!.toJson(now: now),
    if (defectMap != null) 'defectMap': defectMap!.toJson(now: now),
    'warnings': warnings,
  };
}

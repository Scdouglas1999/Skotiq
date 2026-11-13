import '../../database/database.dart';
import '../../models/calibration/calibration_library_models.dart';
import '../../models/calibration/dark_library_match_tolerances.dart';
import '../../models/imaging/integrated_master.dart';

/// The dark chosen for a set of lights, and how far it is from an exact match.
class DarkSelection {
  const DarkSelection({
    required this.record,
    required this.exposureScaled,
    required this.temperatureFellBack,
  });

  final CalibrationMasterRecord record;

  /// No dark is within the exposure tolerance, so [record] is the nearest
  /// exposure and only calibrates correctly when its dark current is scaled to
  /// the lights' exposure (which needs a bias).
  final bool exposureScaled;

  /// The lights state a temperature and no candidate is within the temperature
  /// tolerance, so [record] is the nearest one outside it.
  final bool temperatureFellBack;
}

extension DarkLibraryEntryFile on DarkLibraryEntry {
  /// The file to subtract: the stacked master when the row has one.
  String get calibrationPath => masterDarkPath ?? filePath;
}

/// A `dark_library` row (dark or bias) as a library record.
CalibrationMasterRecord darkLibraryRecord(DarkLibraryEntry row) =>
    CalibrationMasterRecord(
      type: row.frameType == 'bias'
          ? CalibrationMasterType.bias
          : CalibrationMasterType.dark,
      id: row.id,
      filePath: row.calibrationPath,
      isMaster: row.masterDarkPath != null,
      frameCount: row.masterFrameCount,
      exposureSeconds: row.exposureTime,
      temperature: row.temperature,
      gain: row.gain,
      offset: row.offset,
      binX: row.binX,
      binY: row.binY,
      width: row.width,
      height: row.height,
      createdAt: row.createdAt,
    );

/// Whether [r] agrees with [ctx] on every capture dimension the lights
/// recorded: gain and offset when the lights state them, binning always, and
/// the camera when both sides name one.
///
/// A gain or offset missing on the lights is not compared. One missing on the
/// record cannot satisfy a value the lights state.
bool calibrationTupleMatches(CalibrationMasterRecord r, LightFrameContext ctx) {
  final camera = ctx.cameraId?.trim();
  final cameraAgrees =
      camera == null ||
      camera.isEmpty ||
      r.cameraId == null ||
      r.cameraId == camera;
  return (ctx.gain == null || r.gain == ctx.gain) &&
      (ctx.offset == null || r.offset == ctx.offset) &&
      r.binX == ctx.binX &&
      r.binY == ctx.binY &&
      cameraAgrees;
}

/// [candidates] narrowed to those that state the lights' gain and offset
/// exactly (a missing value included) when any does. A camera without gain or
/// offset control records neither on its lights or its masters, and two such
/// frames agree.
List<CalibrationMasterRecord> preferExactCalibrationTuple(
  List<CalibrationMasterRecord> candidates,
  LightFrameContext ctx,
) {
  final exact = candidates
      .where((r) => r.gain == ctx.gain && r.offset == ctx.offset)
      .toList();
  return exact.isEmpty ? candidates : exact;
}

/// The records that pass [calibrationTupleMatches], narrowed by
/// [preferExactCalibrationTuple].
List<CalibrationMasterRecord> calibrationTupleCandidates(
  Iterable<CalibrationMasterRecord> records,
  LightFrameContext ctx,
) => preferExactCalibrationTuple(
  records.where((r) => calibrationTupleMatches(r, ctx)).toList(),
  ctx,
);

double _exposureDelta(CalibrationMasterRecord r, LightFrameContext ctx) =>
    r.exposureSeconds == null
    ? double.maxFinite
    : (r.exposureSeconds! - ctx.exposureSeconds).abs();

/// Distance in °C between [r] and the lights; unknown on either side sorts
/// last.
double calibrationTemperatureDelta(
  CalibrationMasterRecord r,
  LightFrameContext ctx,
) => (ctx.temperature == null || r.temperature == null)
    ? double.maxFinite
    : (r.temperature! - ctx.temperature!).abs();

bool _withinTemperature(
  CalibrationMasterRecord r,
  LightFrameContext ctx,
  double toleranceC,
) =>
    ctx.temperature == null ||
    r.temperature == null ||
    (r.temperature! - ctx.temperature!).abs() <= toleranceC;

/// The darks that calibrate [ctx] with no caveat: same tuple, exposure and
/// temperature both within [tolerances]. A dark with no recorded temperature
/// counts as within.
List<CalibrationMasterRecord> darksWithinTolerance(
  Iterable<CalibrationMasterRecord> darks,
  LightFrameContext ctx,
  DarkLibraryMatchTolerances tolerances,
) => [
  for (final r in calibrationTupleCandidates(darks, ctx))
    if (_exposureDelta(r, ctx) <= tolerances.exposureSecs &&
        _withinTemperature(r, ctx, tolerances.temperatureC))
      r,
];

/// The one rule for which dark calibrates a light.
///
/// Gain, offset, binning and camera are requirements
/// ([calibrationTupleCandidates]). Among those, a dark within the exposure
/// tolerance is used as it is; with none, the nearest exposure is returned
/// flagged [DarkSelection.exposureScaled]. Temperature is a preference, as in
/// PixInsight's WeightedBatchPreprocessing, which pairs darks by binning and
/// exposure and never refuses one for its temperature: candidates within the
/// temperature tolerance win, and with none the nearest is returned flagged
/// [DarkSelection.temperatureFellBack]. A stacked master beats a raw frame,
/// then nearest exposure (only when scaling), nearest temperature, a local
/// record over a shared one, newest.
DarkSelection? selectDark(
  Iterable<CalibrationMasterRecord> darks,
  LightFrameContext ctx,
  DarkLibraryMatchTolerances tolerances,
) {
  final candidates = calibrationTupleCandidates(darks, ctx);
  if (candidates.isEmpty) return null;

  final exact = candidates
      .where((r) => _exposureDelta(r, ctx) <= tolerances.exposureSecs)
      .toList();
  final scaled = exact.isEmpty;
  var pool = scaled ? candidates : exact;

  final within = pool
      .where((r) => _withinTemperature(r, ctx, tolerances.temperatureC))
      .toList();
  final fellBack = within.isEmpty;
  if (!fellBack) pool = within;

  pool.sort((a, b) {
    if (a.isMaster != b.isMaster) return a.isMaster ? -1 : 1;
    if (scaled) {
      final byExposure = _exposureDelta(
        a,
        ctx,
      ).compareTo(_exposureDelta(b, ctx));
      if (byExposure != 0) return byExposure;
    }
    final byTemperature = calibrationTemperatureDelta(
      a,
      ctx,
    ).compareTo(calibrationTemperatureDelta(b, ctx));
    if (byTemperature != 0) return byTemperature;
    if (a.isRemote != b.isRemote) return a.isRemote ? 1 : -1;
    return b.createdAt.compareTo(a.createdAt);
  });
  return DarkSelection(
    record: pool.first,
    exposureScaled: scaled,
    temperatureFellBack: fellBack,
  );
}

/// The flat chosen for a set of lights.
class FlatSelection {
  const FlatSelection({
    required this.record,
    required this.qualifyingCount,
    required this.temperatureFellBack,
  });

  final CalibrationMasterRecord record;

  /// How many flats met every requirement; [record] is the newest of them.
  final int qualifyingCount;

  /// The lights state a temperature and no candidate is within the
  /// temperature tolerance, so [record] is the newest one outside it.
  final bool temperatureFellBack;
}

/// A `flat_library` row as a library record.
CalibrationMasterRecord flatLibraryRecord(FlatLibraryEntry row) =>
    CalibrationMasterRecord(
      type: CalibrationMasterType.flat,
      id: row.id,
      filePath: row.filePath,
      isMaster: true,
      frameCount: row.masterFrameCount,
      temperature: row.temperature,
      gain: row.gain,
      offset: row.offset,
      binX: row.binX,
      binY: row.binY,
      filter: row.filter,
      flatKind: row.flatKind,
      width: row.width,
      height: row.height,
      opticalTrainId: row.opticalTrainId,
      createdAt: row.createdAt,
    );

/// The one rule for which flat calibrates a light.
///
/// Requirements: the capture tuple as for darks ([calibrationTupleMatches],
/// so a gain or offset the lights never recorded is not compared and an exact
/// tuple is preferred), the lights' filter when they name one, and the lights'
/// optical train when they name one (a flat with no train tag also passes).
/// Temperature is a preference, as in PixInsight's
/// WeightedBatchPreprocessing, which pairs flats by filter and binning only:
/// flats within [temperatureToleranceC] win, and with none every qualifying
/// flat stays and the pick is flagged [FlatSelection.temperatureFellBack].
/// Dust and the optical train change from night to night, so the newest flat
/// wins, a local record over a shared one on the same instant.
FlatSelection? selectFlat(
  Iterable<CalibrationMasterRecord> flats,
  LightFrameContext ctx, {
  required double temperatureToleranceC,
}) {
  final filter = ctx.filter?.trim() ?? '';
  final train = ctx.opticalTrainId?.trim() ?? '';
  var pool = preferExactCalibrationTuple([
    for (final r in flats)
      if (calibrationTupleMatches(r, ctx) &&
          (filter.isEmpty || r.filter?.trim() == filter) &&
          (train.isEmpty ||
              r.opticalTrainId == null ||
              r.opticalTrainId!.trim() == train))
        r,
  ], ctx);
  if (pool.isEmpty) return null;

  final within = pool
      .where((r) => _withinTemperature(r, ctx, temperatureToleranceC))
      .toList();
  final fellBack = within.isEmpty;
  if (!fellBack) pool = within;

  pool.sort((a, b) {
    final byDate = b.createdAt.compareTo(a.createdAt);
    if (byDate != 0) return byDate;
    if (a.isRemote != b.isRemote) return a.isRemote ? 1 : -1;
    return 0;
  });
  return FlatSelection(
    record: pool.first,
    qualifyingCount: pool.length,
    temperatureFellBack: fellBack,
  );
}

/// The one rule for which bias calibrates a light: same tuple
/// ([calibrationTupleCandidates]), a stacked master over a raw frame, a local
/// record over a shared one, newest. Returns the ranked candidates, best
/// first.
List<CalibrationMasterRecord> rankBiases(
  Iterable<CalibrationMasterRecord> biases,
  LightFrameContext ctx,
) {
  final pool = calibrationTupleCandidates(biases, ctx);
  pool.sort((a, b) {
    if (a.isMaster != b.isMaster) return a.isMaster ? -1 : 1;
    if (a.isRemote != b.isRemote) return a.isRemote ? 1 : -1;
    return b.createdAt.compareTo(a.createdAt);
  });
  return pool;
}

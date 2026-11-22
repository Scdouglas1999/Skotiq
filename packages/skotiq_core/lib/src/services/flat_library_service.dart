import 'dart:io';

import '../database/daos/flat_library_dao.dart';
import '../models/calibration/calibration_library_models.dart';
import '../models/imaging/integrated_master.dart';
import 'calibration/calibration_selection.dart';
import 'frame_header.dart';
import 'post_session_seam.dart';

/// Service for the master-flat artifact library — the counterpart to
/// [DarkLibraryService] for flats.
///
/// It builds unit-mean master flats from raw flat frames via the native
/// `api_build_master_flat` ([PostSessionSeam.buildMasterFlat]) — which
/// bias/dark-flat-subtracts, sigma-clip-combines (reusing the tested
/// `combine_master_frames`), and normalizes to mean 1.0 so the existing
/// `divide_flat` calibration applies correctly — then registers the result in
/// the `flat_library` table for auto-matching by filter / optics / temperature.
///
class FlatLibraryService {
  FlatLibraryService({
    required FlatLibraryDao dao,
    required PostSessionSeam seam,
    FrameHeaderReader readHeader = readFrameHeader,
  }) : _dao = dao,
       _seam = seam,
       _readFrameHeader = readHeader;

  final FlatLibraryDao _dao;
  final PostSessionSeam _seam;
  final FrameHeaderReader _readFrameHeader;

  /// Build a master flat from [flatPaths], write it to [outputPath], and
  /// register it in the library.
  ///
  /// [biasOrDarkFlatPath] is the optional pedestal: a master bias (for short
  /// flats) or master dark-flat (for long flats). [method] is `'sigmaClip'`
  /// (default), `'median'`, or `'mean'`. [outputBitDepth] is `'f32'` (default,
  /// lossless unit-mean) or `'u16'`.
  ///
  /// The library row carries the acquisition settings the flats were taken
  /// with, because the matcher pairs a flat with lights by filter, gain,
  /// offset and binning. Any of those the caller leaves null is read from the
  /// first flat's FITS header, so a registered flat is never filed under a
  /// gain of 0 that no light frame would match.
  ///
  /// Throws [ArgumentError] for an empty input list, and propagates any native
  /// build error (never registers a flat that failed to build).
  Future<FlatMasterBuild> buildMasterFlat({
    required List<String> flatPaths,
    required String outputPath,
    String? biasOrDarkFlatPath,
    String? filter,
    int? equipmentProfileId,
    String? opticalTrainId,
    double? temperature,
    int? gain,
    int? offset,
    int? binX,
    int? binY,
    String flatKind = 'sky',
    String method = 'sigmaClip',
    double sigmaKappa = 3.0,
    int sigmaIterations = 5,
    String outputBitDepth = 'f32',
  }) async {
    if (flatPaths.isEmpty) {
      throw ArgumentError.value(flatPaths, 'flatPaths', 'must not be empty');
    }
    if (outputPath.trim().isEmpty) {
      throw ArgumentError.value(outputPath, 'outputPath', 'must not be empty');
    }

    final result = await _seam.buildMasterFlat({
      'flatPaths': flatPaths,
      if (biasOrDarkFlatPath != null && biasOrDarkFlatPath.trim().isNotEmpty)
        'biasOrDarkFlat': biasOrDarkFlatPath,
      'outputBitDepth': outputBitDepth,
      'method': method,
      'sigmaKappa': sigmaKappa,
      'sigmaIterations': sigmaIterations,
      'outputPath': outputPath,
    });

    final needsHeader =
        filter == null ||
        temperature == null ||
        gain == null ||
        offset == null ||
        binX == null ||
        binY == null;
    final header = needsHeader
        ? await _readHeader(flatPaths.first)
        : FrameHeader(const {});

    final id = await _dao.addEntry(
      filePath: result.outputPath,
      filter: filter ?? header.string('FILTER'),
      equipmentProfileId: equipmentProfileId,
      opticalTrainId: opticalTrainId,
      temperature: temperature ?? header.libraryTempC,
      // A flat without the cards is from a camera with no such control.
      gain: gain ?? header.integer('GAIN'),
      offset: offset ?? header.integer('OFFSET'),
      binX: binX ?? header.integer('XBINNING') ?? 1,
      binY: binY ?? header.integer('YBINNING') ?? 1,
      width: result.width,
      height: result.height,
      flatKind: flatKind,
      masterFrameCount: result.frameCount,
    );
    return FlatMasterBuild(libraryId: id, result: result);
  }

  /// The header of [path]; an unreadable one tells nothing, and the caller's
  /// own values stand.
  Future<FrameHeader> _readHeader(String path) async {
    try {
      return await _readFrameHeader(path);
    } on Exception {
      return FrameHeader(const {});
    }
  }

  /// The master flat for lights of [context], picked by [selectFlat] at the
  /// Darkroom's flat temperature tolerance. Null when none qualifies.
  Future<FlatLibraryEntry?> findBestMatch(LightFrameContext context) async {
    final rows = await _dao.getAllEntries();
    final selection = selectFlat(
      rows.map(flatLibraryRecord),
      context,
      temperatureToleranceC:
          CalibrationMatchTolerances.defaults.flatTemperatureC,
    );
    if (selection == null) return null;
    return rows.firstWhere((row) => row.id == selection.record.id);
  }

  /// The master flat for a light being calibrated as it is captured
  /// ([liveFlatFor] over this library).
  Future<FlatLibraryEntry?> findLiveFlat({
    required String? filter,
    required int? gain,
    required int? offset,
    int binX = 1,
    int binY = 1,
    double? temperature,
  }) async => liveFlatFor(
    await _dao.getAllEntries(),
    filter: filter,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
    temperature: temperature,
  );

  /// All registered master flats, newest first.
  Future<List<FlatLibraryEntry>> getAllEntries() => _dao.getAllEntries();

  Future<void> deleteEntry(int id, {bool deleteFile = false}) async {
    if (deleteFile) {
      final entry = await _dao.getEntryById(id);
      if (entry != null) {
        final file = File(entry.filePath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    await _dao.deleteEntry(id);
  }
}

/// A master flat the library built and registered.
class FlatMasterBuild {
  const FlatMasterBuild({required this.libraryId, required this.result});

  final int libraryId;
  final BuildMasterFlatResult result;
}

/// The master flat of [rows] for a light being calibrated as it is captured:
/// a flat of exactly the light's [filter] (the same name ignoring case and
/// surrounding space; no filter takes a flat recorded with none), then
/// [selectFlat] over the capture tuple, binning and temperature. Null when
/// none qualifies: a light never takes another filter's flat.
FlatLibraryEntry? liveFlatFor(
  List<FlatLibraryEntry> rows, {
  required String? filter,
  required int? gain,
  required int? offset,
  int binX = 1,
  int binY = 1,
  double? temperature,
}) {
  final candidates = [
    for (final row in rows)
      if (_sameFilterName(row.filter, filter)) row,
  ];
  final selection = selectFlat(
    candidates.map(flatLibraryRecord),
    LightFrameContext(
      gain: gain,
      offset: offset,
      exposureSeconds: 0,
      temperature: temperature,
      filter: filter,
      binX: binX,
      binY: binY,
    ),
    temperatureToleranceC: CalibrationMatchTolerances.defaults.flatTemperatureC,
  );
  if (selection == null) return null;
  return candidates.firstWhere((row) => row.id == selection.record.id);
}

/// Whether a flat recorded with filter [flat] is the light's [light] filter
/// by name: the same text ignoring case and surrounding space, or both none.
bool _sameFilterName(String? flat, String? light) {
  final a = flat?.trim().toLowerCase();
  final b = light?.trim().toLowerCase();
  final aNone = a == null || a.isEmpty;
  final bNone = b == null || b.isEmpty;
  return aNone || bNone ? aNone && bNone : a == b;
}

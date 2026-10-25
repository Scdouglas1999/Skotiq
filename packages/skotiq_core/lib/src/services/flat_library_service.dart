import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/flat_library_dao.dart';
import '../models/imaging/integrated_master.dart';
import 'calibration/fits_header_reader.dart';
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
/// This closes the "no master-flat / no flat auto-match" gap: before this, the
/// app had a `dark_library` + `createMasterDark` but no flat equivalent.
class FlatLibraryService {
  FlatLibraryService({
    required FlatLibraryDao dao,
    required PostSessionSeam seam,
    FitsHeaderReader headerReader = const FitsHeaderReader(),
  }) : _dao = dao,
       _seam = seam,
       _headerReader = headerReader;

  final FlatLibraryDao _dao;
  final PostSessionSeam _seam;
  final FitsHeaderReader _headerReader;

  /// Build a master flat from [flatPaths], write it to [outputPath], and
  /// register it in the library. Returns the new `flat_library` row id.
  ///
  /// See [buildMasterFlat] for the arguments.
  Future<int> createMasterFlat({
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
  }) async => (await buildMasterFlat(
    flatPaths: flatPaths,
    outputPath: outputPath,
    biasOrDarkFlatPath: biasOrDarkFlatPath,
    filter: filter,
    equipmentProfileId: equipmentProfileId,
    opticalTrainId: opticalTrainId,
    temperature: temperature,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
    flatKind: flatKind,
    method: method,
    sigmaKappa: sigmaKappa,
    sigmaIterations: sigmaIterations,
    outputBitDepth: outputBitDepth,
  )).libraryId;

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
  /// placeholder gain of 0 that no light frame would match.
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
        : const <String, String>{};
    int? headerInt(String key) =>
        FitsHeaderReader.doubleValue(header, key)?.round();

    final id = await _dao.addEntry(
      filePath: result.outputPath,
      filter: filter ?? FitsHeaderReader.stringValue(header, 'FILTER'),
      equipmentProfileId: equipmentProfileId,
      opticalTrainId: opticalTrainId,
      temperature:
          temperature ??
          FitsHeaderReader.firstDouble(header, const [
            'CCD-TEMP',
            'CCD_TEMP',
            'SET-TEMP',
          ]),
      gain: gain ?? headerInt('GAIN') ?? 0,
      offset: offset ?? headerInt('OFFSET') ?? 0,
      binX: binX ?? headerInt('XBINNING') ?? 1,
      binY: binY ?? headerInt('YBINNING') ?? 1,
      width: result.width,
      height: result.height,
      flatKind: flatKind,
      masterFrameCount: result.frameCount,
    );
    return FlatMasterBuild(libraryId: id, result: result);
  }

  Future<Map<String, String>> _readHeader(String path) async {
    try {
      return await _headerReader.readPrimaryHeader(path);
    } on Object {
      return const <String, String>{};
    }
  }

  /// Find the best master flat for a light frame's parameters (delegates to
  /// [FlatLibraryDao.findBestMatch]).
  Future<FlatLibraryEntry?> findBestMatch({
    String? filter,
    int gain = 0,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    String? opticalTrainId,
    double? temperature,
    double temperatureToleranceC = 5.0,
  }) {
    return _dao.findBestMatch(
      filter: filter,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      opticalTrainId: opticalTrainId,
      temperature: temperature,
      temperatureToleranceC: temperatureToleranceC,
    );
  }

  /// All registered master flats, newest first.
  Future<List<FlatLibraryEntry>> getAllEntries() => _dao.getAllEntries();

  /// Delete an entry and optionally remove the FITS file from disk.
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

/// Provider for the [FlatLibraryService].
final flatLibraryServiceProvider = Provider<FlatLibraryService>((ref) {
  return FlatLibraryService(
    dao: ref.watch(flatLibraryDaoProvider),
    seam: ref.watch(postSessionSeamProvider),
  );
});

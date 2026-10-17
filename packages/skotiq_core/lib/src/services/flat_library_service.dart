import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/flat_library_dao.dart';
import '../models/imaging/integrated_master.dart';
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
  }) : _dao = dao,
       _seam = seam;

  final FlatLibraryDao _dao;
  final PostSessionSeam _seam;

  /// Build a master flat from [flatPaths], write it to [outputPath], and
  /// register it in the library.
  ///
  /// [biasOrDarkFlatPath] is the optional pedestal: a master bias (for short
  /// flats) or master dark-flat (for long flats). [method] is `'sigmaClip'`
  /// (default), `'median'`, or `'mean'`. [outputBitDepth] is `'f32'` (default,
  /// lossless unit-mean) or `'u16'`.
  ///
  /// Returns the new `flat_library` row id. Throws [ArgumentError] for an empty
  /// input list, and propagates any native build error (never registers a flat
  /// that failed to build).
  Future<int> createMasterFlat({
    required List<String> flatPaths,
    required String outputPath,
    String? biasOrDarkFlatPath,
    String? filter,
    int? equipmentProfileId,
    String? opticalTrainId,
    double? temperature,
    int gain = 0,
    int offset = 0,
    int binX = 1,
    int binY = 1,
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

    return _dao.addEntry(
      filePath: result.outputPath,
      filter: filter,
      equipmentProfileId: equipmentProfileId,
      opticalTrainId: opticalTrainId,
      temperature: temperature,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      width: result.width,
      height: result.height,
      flatKind: flatKind,
      masterFrameCount: result.frameCount,
    );
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

/// Provider for the [FlatLibraryService].
final flatLibraryServiceProvider = Provider<FlatLibraryService>((ref) {
  return FlatLibraryService(
    dao: ref.watch(flatLibraryDaoProvider),
    seam: ref.watch(postSessionSeamProvider),
  );
});

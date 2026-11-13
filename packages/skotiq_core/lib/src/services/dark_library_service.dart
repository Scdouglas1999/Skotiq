import 'dart:io';

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../database/daos/dark_library_dao.dart';
import '../models/calibration/calibration_library_models.dart';
import '../models/calibration/dark_library_match_tolerances.dart';
import 'calibration/dark_selection.dart';
import 'calibration_master_builder.dart';

/// Service for managing dark frame library operations.
///
/// Handles registering captured darks/biases, finding the best match for
/// auto-subtraction, building master darks with the native builder, and
/// cleaning orphaned entries.
class DarkLibraryService {
  final DarkLibraryDao _dao;

  /// The native master builder, which streams the frames from disk a band at
  /// a time.
  final CalibrationMasterBuild _buildMaster;

  DarkLibraryService(
    this._dao, {
    CalibrationMasterBuild buildMaster = buildCalibrationMasterNative,
  }) : _buildMaster = buildMaster;

  /// Register a captured dark or bias frame in the library.
  ///
  /// [filePath] must point to an existing FITS/XISF file on disk.
  /// Returns the database ID of the new entry.
  Future<int> addDarkFrame({
    required String filePath,
    required double exposureTime,
    required String frameType,
    double? temperature,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? width,
    int? height,
  }) {
    if (frameType != 'dark' && frameType != 'bias') {
      throw ArgumentError(
        'frameType must be "dark" or "bias", got "$frameType"',
      );
    }
    return _dao.addEntry(
      DarkLibraryCompanion.insert(
        filePath: filePath,
        exposureTime: exposureTime,
        frameType: Value(frameType),
        temperature: Value(temperature),
        gain: Value(gain),
        offset: Value(offset),
        binX: Value(binX),
        binY: Value(binY),
        width: Value(width),
        height: Value(height),
      ),
    );
  }

  /// The dark or bias to subtract from a light frame as it is, or null.
  ///
  /// The pick is [selectDark]'s (or [rankBiases]' for a bias), the same rule
  /// the Darkroom uses. A dark that would need exposure scaling is not
  /// returned, because these callers subtract the file unscaled. A dark
  /// outside the temperature tolerance is returned when none is within it.
  Future<DarkLibraryEntry?> findMatchingDark({
    required double exposureTime,
    required int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    double? temperature,
    DarkLibraryMatchTolerances tolerances = DarkLibraryMatchTolerances.defaults,
    String frameType = 'dark',
  }) async {
    final rows = await _dao.getEntriesByFrameType(frameType);
    final records = rows.map(darkLibraryRecord);
    final context = LightFrameContext(
      gain: gain,
      offset: offset,
      exposureSeconds: exposureTime,
      temperature: temperature,
      binX: binX,
      binY: binY,
    );
    final int? id;
    if (frameType == 'bias') {
      id = rankBiases(records, context).firstOrNull?.id;
    } else {
      final selection = selectDark(records, context, tolerances);
      id = selection == null || selection.exposureScaled
          ? null
          : selection.record.id;
    }
    if (id == null) return null;
    return rows.firstWhere((row) => row.id == id);
  }

  /// Build a master dark (or bias) from a list of raw frames.
  ///
  /// The input frames must all share the same exposure, gain, binning, and
  /// dimensions. The result is written to [outputPath] and registered in the
  /// library.
  ///
  /// Returns the database ID of the new master dark entry.
  Future<int> createMasterDark({
    required List<DarkLibraryEntry> frames,
    required String outputPath,
  }) async {
    if (frames.isEmpty) {
      throw ArgumentError('frames must not be empty');
    }
    if (frames.length < 2) {
      throw ArgumentError('Need at least 2 frames to create a master dark');
    }

    // Validate all frames share matching parameters
    final first = frames.first;
    for (final frame in frames.skip(1)) {
      if (frame.exposureTime != first.exposureTime ||
          frame.gain != first.gain ||
          frame.offset != first.offset ||
          frame.binX != first.binX ||
          frame.binY != first.binY ||
          frame.frameType != first.frameType) {
        throw ArgumentError(
          'All frames must have matching exposure, gain, offset, binning, '
          'and frame type. Mismatch found: '
          '${frame.exposureTime}s/gain${frame.gain}/offset${frame.offset}/'
          '${frame.binX}x${frame.binY}/${frame.frameType} vs '
          '${first.exposureTime}s/gain${first.gain}/offset${first.offset}/'
          '${first.binX}x${first.binY}/${first.frameType}',
        );
      }
    }

    final built = await _buildMaster(
      CalibrationMasterBuildRequest(
        kind: first.frameType == 'bias' ? 'bias' : 'dark',
        framePaths: [for (final f in frames) f.filePath],
        outputPath: outputPath,
      ),
    );
    return registerMaster(built, frameType: first.frameType);
  }

  /// Register a master the native builder wrote as a library master row.
  ///
  /// Exposure, gain, offset and binning come from the master's own header, so
  /// the row and the file cannot disagree; the temperature is the mean sensor
  /// temperature of the frames it combined.
  Future<int> registerMaster(
    CalibrationMasterBuildResult built, {
    required String frameType,
  }) {
    return _dao.addEntry(
      DarkLibraryCompanion.insert(
        filePath: built.outputPath,
        exposureTime: built.exposureSecs ?? 0,
        frameType: Value(frameType),
        temperature: Value(built.ccdTempMean ?? built.setTemp),
        gain: Value(built.gain),
        offset: Value(built.offset),
        binX: Value(built.binX ?? 1),
        binY: Value(built.binY ?? 1),
        width: Value(built.width),
        height: Value(built.height),
        masterDarkPath: Value(built.outputPath),
        masterFrameCount: Value(built.frameCount),
      ),
    );
  }

  Future<List<DarkLibraryEntry>> getAllEntries() => _dao.getAllEntries();

  Stream<List<DarkLibraryEntry>> watchAllEntries() => _dao.watchAllEntries();

  Future<List<DarkGroupKey>> getDistinctGroups() => _dao.getDistinctGroups();

  /// Get all raw frames matching specific parameters (for master dark creation).
  Future<List<DarkLibraryEntry>> getMatchingFrames({
    required double exposureTime,
    required int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    String frameType = 'dark',
  }) {
    return _dao.getMatchingFrames(
      exposureTime: exposureTime,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      frameType: frameType,
    );
  }

  /// Get all raw and master entries in one exact library group.
  Future<List<DarkLibraryEntry>> getEntriesForGroup(DarkGroupKey group) =>
      _dao.getEntriesForGroup(group);

  Future<void> deleteEntry(int id, {bool deleteFile = false}) async {
    if (deleteFile) {
      final entry = await _dao.getEntryById(id);
      if (entry != null) {
        await _deleteFileIfExists(entry.filePath);
        if (entry.masterDarkPath != null) {
          await _deleteFileIfExists(entry.masterDarkPath!);
        }
      }
    }
    await _dao.deleteEntry(id);
  }

  Future<void> deleteEntries(List<int> ids, {bool deleteFile = false}) async {
    if (deleteFile) {
      for (final id in ids) {
        final entry = await _dao.getEntryById(id);
        if (entry != null) {
          await _deleteFileIfExists(entry.filePath);
          if (entry.masterDarkPath != null) {
            await _deleteFileIfExists(entry.masterDarkPath!);
          }
        }
      }
    }
    await _dao.deleteEntries(ids);
  }

  Future<void> clearLibrary({bool deleteFiles = false}) async {
    if (deleteFiles) {
      final entries = await _dao.getAllEntries();
      for (final entry in entries) {
        await _deleteFileIfExists(entry.filePath);
        if (entry.masterDarkPath != null) {
          await _deleteFileIfExists(entry.masterDarkPath!);
        }
      }
    }
    await _dao.deleteAll();
  }

  /// Remove entries whose files no longer exist on disk.
  ///
  /// Returns the number of orphaned entries removed.
  Future<int> cleanOrphanedEntries() async {
    final entries = await _dao.getAllEntries();
    final orphanIds = <int>[];

    for (final entry in entries) {
      final fileExists = await File(entry.filePath).exists();
      if (!fileExists) {
        orphanIds.add(entry.id);
      }
    }

    if (orphanIds.isNotEmpty) {
      await _dao.deleteEntries(orphanIds);
    }

    return orphanIds.length;
  }

  Future<void> _deleteFileIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

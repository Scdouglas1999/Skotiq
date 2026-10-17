import 'dart:io';

import 'package:drift/drift.dart';

import '../../models/calibration/dark_library_match_tolerances.dart';
import '../../services/logging_service.dart';
import '../database.dart';
import '../tables/dark_library.dart';

part 'dark_library_dao.g.dart';

@DriftAccessor(tables: [DarkLibrary])
class DarkLibraryDao extends DatabaseAccessor<SkotiqDatabase>
    with _$DarkLibraryDaoMixin {
  DarkLibraryDao(super.db);

  /// Insert a new dark frame entry and return its ID.
  Future<int> addEntry(DarkLibraryCompanion entry) {
    return transaction(() async {
      final filePath = entry.filePath.present ? entry.filePath.value : null;
      if (filePath == null) {
        throw ArgumentError('Dark library entries require a filePath');
      }

      final existing = await (select(
        darkLibrary,
      )..where((t) => t.filePath.equals(filePath))).getSingleOrNull();

      if (existing != null) {
        await (update(darkLibrary)..where((t) => t.id.equals(existing.id)))
            .write(entry.copyWith(id: Value(existing.id)));
        return existing.id;
      }

      return into(darkLibrary).insert(entry);
    });
  }

  /// Get all entries, newest first.
  Future<List<DarkLibraryEntry>> getAllEntries() {
    return (select(
      darkLibrary,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
  }

  /// Watch all entries, newest first.
  Stream<List<DarkLibraryEntry>> watchAllEntries() {
    return (select(
      darkLibrary,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();
  }

  /// Get entries by frame type ('dark' or 'bias').
  Future<List<DarkLibraryEntry>> getEntriesByFrameType(String type) {
    return (select(darkLibrary)
          ..where((t) => t.frameType.equals(type))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  /// Watch entries by frame type.
  Stream<List<DarkLibraryEntry>> watchEntriesByFrameType(String type) {
    return (select(darkLibrary)
          ..where((t) => t.frameType.equals(type))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Find the best matching dark/bias for a given light frame's parameters.
  ///
  /// Matching rules:
  /// - Exposure time must be within [tolerances.exposureSecs] (default ±0.5s)
  /// - Gain, offset, and binning must match exactly
  /// - Temperature must be within [tolerances.temperatureC] (default ±1.0°C)
  /// - Prefers master darks over individual raws
  /// - Among matches, picks the one closest in temperature
  ///
  /// The tolerances argument is the SAME value object consulted by
  /// `DarkLibraryCoverageService.evaluate`. Before unification, the coverage
  /// UI used ±1.0s while this DAO used ±0.001s, so the UI happily showed
  /// "all darks present" while this method returned null at runtime.
  Future<DarkLibraryEntry?> findBestMatch({
    required double exposureTime,
    required int gain,
    required int offset,
    required int binX,
    required int binY,
    double? temperature,
    DarkLibraryMatchTolerances tolerances = DarkLibraryMatchTolerances.defaults,
    String frameType = 'dark',
  }) async {
    // Build query: tolerance match on exposure, exact on gain/offset/binning/frame type.
    final exposureTol = tolerances.exposureSecs;
    var query = select(darkLibrary)
      ..where(
        (t) =>
            t.exposureTime.isBiggerOrEqualValue(exposureTime - exposureTol) &
            t.exposureTime.isSmallerOrEqualValue(exposureTime + exposureTol) &
            t.gain.equals(gain) &
            t.offset.equals(offset) &
            t.binX.equals(binX) &
            t.binY.equals(binY) &
            t.frameType.equals(frameType),
      );

    final candidates = await query.get();
    if (candidates.isEmpty) return null;

    // Filter by temperature tolerance if temperature is available
    List<DarkLibraryEntry> filtered;
    if (temperature != null) {
      filtered = candidates.where((c) {
        if (c.temperature == null) {
          return true; // Accept frames without temp data
        }
        return (c.temperature! - temperature).abs() <= tolerances.temperatureC;
      }).toList();
    } else {
      filtered = candidates;
    }

    if (filtered.isEmpty) return null;

    // Prefer master darks over raw frames
    final masters = filtered.where((c) => c.masterDarkPath != null).toList();
    final pool = masters.isNotEmpty ? masters : filtered;

    if (temperature == null) {
      // No temperature to sort by; return the newest entry
      pool.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return pool.first;
    }

    // Sort by closest temperature match
    pool.sort((a, b) {
      final aDelta = a.temperature != null
          ? (a.temperature! - temperature).abs()
          : double.maxFinite;
      final bDelta = b.temperature != null
          ? (b.temperature! - temperature).abs()
          : double.maxFinite;
      return aDelta.compareTo(bDelta);
    });

    return pool.first;
  }

  /// Get all entries that match a specific exposure/gain/binning combo.
  /// Useful for selecting frames to combine into a master dark.
  ///
  /// Uses the same exposure tolerance as [findBestMatch] (default ±0.5s) so
  /// master-dark grouping cannot disagree with what calibration matches at
  /// runtime.
  Future<List<DarkLibraryEntry>> getMatchingFrames({
    required double exposureTime,
    required int gain,
    required int offset,
    required int binX,
    required int binY,
    String frameType = 'dark',
    DarkLibraryMatchTolerances tolerances = DarkLibraryMatchTolerances.defaults,
  }) {
    final exposureTol = tolerances.exposureSecs;
    return (select(darkLibrary)
          ..where(
            (t) =>
                t.exposureTime.isBiggerOrEqualValue(
                  exposureTime - exposureTol,
                ) &
                t.exposureTime.isSmallerOrEqualValue(
                  exposureTime + exposureTol,
                ) &
                t.gain.equals(gain) &
                t.offset.equals(offset) &
                t.binX.equals(binX) &
                t.binY.equals(binY) &
                t.frameType.equals(frameType) &
                t.masterDarkPath.isNull(),
          ) // Only raw frames
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  /// Get every entry belonging to one exact operator-visible group.
  ///
  /// Administrative actions such as "Delete Group" must not use
  /// [getMatchingFrames]: that query intentionally applies calibration
  /// tolerance and excludes masters. Here the values are exact because the
  /// group itself came from SQL `GROUP BY`, and both raw and master rows are
  /// part of what the user asked to administer.
  Future<List<DarkLibraryEntry>> getEntriesForGroup(DarkGroupKey group) {
    return (select(darkLibrary)
          ..where(
            (t) =>
                t.exposureTime.equals(group.exposureTime) &
                t.gain.equals(group.gain) &
                t.offset.equals(group.offset) &
                t.binX.equals(group.binX) &
                t.binY.equals(group.binY) &
                t.frameType.equals(group.frameType),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  /// Get a single entry by ID.
  Future<DarkLibraryEntry?> getEntryById(int id) {
    return (select(
      darkLibrary,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Delete an entry by ID.
  Future<int> deleteEntry(int id) {
    return (delete(darkLibrary)..where((t) => t.id.equals(id))).go();
  }

  /// Delete multiple entries by IDs.
  Future<int> deleteEntries(List<int> ids) {
    return (delete(darkLibrary)..where((t) => t.id.isIn(ids))).go();
  }

  /// Delete all entries.
  Future<int> deleteAll() {
    return delete(darkLibrary).go();
  }

  /// Update an existing entry (e.g. to set masterDarkPath after stacking).
  Future<bool> updateEntry(DarkLibraryEntry entry) {
    return update(darkLibrary).replace(entry);
  }

  /// Get summary statistics: count per frame type, total disk usage estimate.
  ///
  /// Uses SQL COUNT queries instead of loading the entire table into memory.
  Future<DarkLibraryStats> getStats() async {
    final totalExp = darkLibrary.id.count();

    // Count master darks (masterDarkPath IS NOT NULL)
    final masterQuery = selectOnly(darkLibrary)
      ..addColumns([totalExp])
      ..where(darkLibrary.masterDarkPath.isNotNull());
    final masterResult = await masterQuery.getSingle();
    final masterCount = masterResult.read(totalExp) ?? 0;

    // Count bias frames (non-master)
    final biasQuery = selectOnly(darkLibrary)
      ..addColumns([totalExp])
      ..where(
        darkLibrary.frameType.equals('bias') &
            darkLibrary.masterDarkPath.isNull(),
      );
    final biasResult = await biasQuery.getSingle();
    final biasCount = biasResult.read(totalExp) ?? 0;

    // Count dark frames (non-master, non-bias)
    final darkQuery = selectOnly(darkLibrary)
      ..addColumns([totalExp])
      ..where(
        darkLibrary.frameType.equals('dark') &
            darkLibrary.masterDarkPath.isNull(),
      );
    final darkResult = await darkQuery.getSingle();
    final darkCount = darkResult.read(totalExp) ?? 0;

    // Total entries
    final totalQuery = selectOnly(darkLibrary)..addColumns([totalExp]);
    final totalResult = await totalQuery.getSingle();
    final totalEntries = totalResult.read(totalExp) ?? 0;

    return DarkLibraryStats(
      totalEntries: totalEntries,
      darkCount: darkCount,
      biasCount: biasCount,
      masterCount: masterCount,
    );
  }

  /// Filtered listing for the remote calibration API.
  ///
  /// Arguments are independent filters; nulls mean "do not filter on this
  /// dimension". Exposure tolerance is fractional (±10% of [exposureSeconds]
  /// by default — matches the operator-facing UI behaviour for "find me
  /// darks roughly like this"). Temperature tolerance is ±[temperatureWindow]
  /// degrees C.
  ///
  /// Returns the newest-first slice up to [limit] rows. We deliberately do
  /// NOT silently clamp [limit]; callers must validate and clamp at the
  /// handler layer.
  Future<List<DarkLibraryEntry>> listFiltered({
    double? exposureSeconds,
    double exposureSecondsRatio = 0.10,
    int? gain,
    double? temperatureCelsius,
    double temperatureWindow = 5.0,
    int limit = 100,
  }) {
    var query = select(darkLibrary)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(limit);

    if (gain != null) {
      query = query..where((t) => t.gain.equals(gain));
    }
    if (exposureSeconds != null) {
      final tol = exposureSeconds * exposureSecondsRatio;
      query = query
        ..where(
          (t) =>
              t.exposureTime.isBiggerOrEqualValue(exposureSeconds - tol) &
              t.exposureTime.isSmallerOrEqualValue(exposureSeconds + tol),
        );
    }
    if (temperatureCelsius != null) {
      query = query
        ..where(
          (t) =>
              t.temperature.isBiggerOrEqualValue(
                temperatureCelsius - temperatureWindow,
              ) &
              t.temperature.isSmallerOrEqualValue(
                temperatureCelsius + temperatureWindow,
              ),
        );
    }
    return query.get();
  }

  /// Scan every dark-library row and verify the on-disk
  /// FITS still exists. Counts how many rows refer to a file that has gone
  /// missing (likely because the operator deleted the file directly), the
  /// total disk bytes the library currently occupies, and how many rows
  /// could not be stat'd.
  ///
  /// Why this replaces a `fileSize` backfill: unlike `captured_images`, the
  /// `dark_library` schema does NOT store a `file_size` column. We don't
  /// want to bump the schema version just for a remote-management nicety,
  /// so the equivalent operator-facing endpoint becomes a real-time stat
  /// scan returning the counts that the file-size backfill on the image
  /// table provides.
  Future<Map<String, int>> verifyOnDiskState({LoggingService? logger}) async {
    final entries = await getAllEntries();
    int present = 0;
    int missing = 0;
    int errors = 0;
    int totalBytes = 0;

    for (final entry in entries) {
      final file = File(entry.filePath);
      try {
        if (await file.exists()) {
          present++;
          totalBytes += await file.length();
        } else {
          missing++;
          logger?.warning(
            'verifyOnDiskState: dark library entry ${entry.id} '
            'references missing file: ${entry.filePath}',
            source: 'DarkLibraryDao',
          );
        }
      } catch (e) {
        errors++;
        logger?.warning(
          'verifyOnDiskState: failed to stat dark library entry '
          '${entry.id} (${entry.filePath}): $e',
          source: 'DarkLibraryDao',
        );
      }
    }

    return {
      'total': entries.length,
      'present': present,
      'missing': missing,
      'errors': errors,
      'totalBytes': totalBytes,
    };
  }

  /// Paginated listing for the remote read API. Supports the same
  /// independent filters as [listFiltered] plus an offset for pagination
  /// and a separate `gain` range (callers passing `gainMin`/`gainMax`).
  /// Newest-first by `createdAt`. Caller MUST validate and clamp
  /// [limit] / [offset] before delegating.
  Future<List<DarkLibraryEntry>> listPaginated({
    int? gainMin,
    int? gainMax,
    double? temperatureCelsius,
    double temperatureWindow = 5.0,
    double? exposureSeconds,
    double exposureSecondsRatio = 0.10,
    int limit = 200,
    int offset = 0,
  }) {
    var query = select(darkLibrary)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(limit, offset: offset);
    if (gainMin != null) {
      query = query..where((t) => t.gain.isBiggerOrEqualValue(gainMin));
    }
    if (gainMax != null) {
      query = query..where((t) => t.gain.isSmallerOrEqualValue(gainMax));
    }
    if (exposureSeconds != null) {
      final tol = exposureSeconds * exposureSecondsRatio;
      query = query
        ..where(
          (t) =>
              t.exposureTime.isBiggerOrEqualValue(exposureSeconds - tol) &
              t.exposureTime.isSmallerOrEqualValue(exposureSeconds + tol),
        );
    }
    if (temperatureCelsius != null) {
      query = query
        ..where(
          (t) =>
              t.temperature.isBiggerOrEqualValue(
                temperatureCelsius - temperatureWindow,
              ) &
              t.temperature.isSmallerOrEqualValue(
                temperatureCelsius + temperatureWindow,
              ),
        );
    }
    return query.get();
  }

  /// Row count matching [listPaginated]'s filters.
  Future<int> countFilteredForRemote({
    int? gainMin,
    int? gainMax,
    double? temperatureCelsius,
    double temperatureWindow = 5.0,
    double? exposureSeconds,
    double exposureSecondsRatio = 0.10,
  }) async {
    final countExpr = darkLibrary.id.count();
    final query = selectOnly(darkLibrary)..addColumns([countExpr]);
    if (gainMin != null) {
      query.where(darkLibrary.gain.isBiggerOrEqualValue(gainMin));
    }
    if (gainMax != null) {
      query.where(darkLibrary.gain.isSmallerOrEqualValue(gainMax));
    }
    if (exposureSeconds != null) {
      final tol = exposureSeconds * exposureSecondsRatio;
      query.where(
        darkLibrary.exposureTime.isBiggerOrEqualValue(exposureSeconds - tol) &
            darkLibrary.exposureTime.isSmallerOrEqualValue(
              exposureSeconds + tol,
            ),
      );
    }
    if (temperatureCelsius != null) {
      query.where(
        darkLibrary.temperature.isBiggerOrEqualValue(
              temperatureCelsius - temperatureWindow,
            ) &
            darkLibrary.temperature.isSmallerOrEqualValue(
              temperatureCelsius + temperatureWindow,
            ),
      );
    }
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }

  /// Get distinct exposure/gain/binning combinations present in the library.
  ///
  /// Uses SQL GROUP BY instead of loading the entire table into memory.
  Future<List<DarkGroupKey>> getDistinctGroups() async {
    final query = selectOnly(darkLibrary)
      ..addColumns([
        darkLibrary.frameType,
        darkLibrary.exposureTime,
        darkLibrary.gain,
        darkLibrary.offset,
        darkLibrary.binX,
        darkLibrary.binY,
      ])
      ..groupBy([
        darkLibrary.frameType,
        darkLibrary.exposureTime,
        darkLibrary.gain,
        darkLibrary.offset,
        darkLibrary.binX,
        darkLibrary.binY,
      ]);

    final rows = await query.get();
    return rows.map((row) {
      return DarkGroupKey(
        frameType: row.read(darkLibrary.frameType)!,
        exposureTime: row.read(darkLibrary.exposureTime)!,
        gain: row.read(darkLibrary.gain)!,
        offset: row.read(darkLibrary.offset)!,
        binX: row.read(darkLibrary.binX)!,
        binY: row.read(darkLibrary.binY)!,
      );
    }).toList();
  }
}

/// Summary statistics for the dark library.
class DarkLibraryStats {
  final int totalEntries;
  final int darkCount;
  final int biasCount;
  final int masterCount;

  const DarkLibraryStats({
    required this.totalEntries,
    required this.darkCount,
    required this.biasCount,
    required this.masterCount,
  });
}

/// Identifies a unique group of dark frames by their capture parameters.
class DarkGroupKey {
  final String frameType;
  final double exposureTime;
  final int gain;
  final int offset;
  final int binX;
  final int binY;

  const DarkGroupKey({
    required this.frameType,
    required this.exposureTime,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DarkGroupKey &&
          frameType == other.frameType &&
          exposureTime == other.exposureTime &&
          gain == other.gain &&
          offset == other.offset &&
          binX == other.binX &&
          binY == other.binY;

  @override
  int get hashCode =>
      Object.hash(frameType, exposureTime, gain, offset, binX, binY);

  @override
  String toString() =>
      'DarkGroupKey($frameType, ${exposureTime}s, gain=$gain, offset=$offset, '
      '${binX}x$binY)';
}

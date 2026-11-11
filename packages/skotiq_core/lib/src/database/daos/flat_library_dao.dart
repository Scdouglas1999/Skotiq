import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/integrated_master.dart';
import '../../providers/database_provider.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'flat_library_dao.g.dart';

/// Reads and writes for `flat_library`: the master-flat artifact library, the
/// counterpart to `dark_library`.
///
/// Its match API ([findBestMatch]) deliberately mirrors
/// `DarkLibraryDao.findBestMatch`: exact gain/offset/binning + filter,
/// temperature within tolerance, preferring the closest temperature then the
/// newest.
@DriftAccessor(include: {'../schema/post_session.drift'})
class FlatLibraryDao extends DatabaseAccessor<SkotiqDatabase>
    with _$FlatLibraryDaoMixin {
  FlatLibraryDao(super.db);

  /// Insert (or replace on duplicate file path) a master-flat entry; returns id.
  Future<int> addEntry({
    required String filePath,
    String? filter,
    int? equipmentProfileId,
    String? opticalTrainId,
    double? temperature,
    int gain = 0,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    int? width,
    int? height,
    String flatKind = 'sky',
    int masterFrameCount = 0,
    DateTime? createdAt,
  }) async {
    // Dedup by file path (a master flat is rebuilt to the same path on rerun).
    final existing =
        await (selectOnly(flatLibrary)
              ..addColumns([flatLibrary.id])
              ..where(flatLibrary.filePath.equals(filePath))
              ..limit(1))
            .map((row) => row.read(flatLibrary.id)!)
            .getSingleOrNull();
    final entry = FlatLibraryCompanion(
      filter: Value(filter),
      equipmentProfileId: Value(equipmentProfileId),
      opticalTrainId: Value(opticalTrainId),
      temperature: Value(temperature),
      gain: Value(gain),
      offset: Value(offset),
      binX: Value(binX),
      binY: Value(binY),
      width: Value(width),
      height: Value(height),
      flatKind: Value(flatKind),
      masterFrameCount: Value(masterFrameCount),
      createdAt: Value(toEpochSeconds((createdAt ?? DateTime.now()).toUtc())),
    );

    if (existing != null) {
      await (update(
        flatLibrary,
      )..where((f) => f.id.equals(existing))).write(entry);
      return existing;
    }
    return into(flatLibrary).insert(entry.copyWith(filePath: Value(filePath)));
  }

  /// All entries, newest first.
  Future<List<FlatLibraryEntry>> getAllEntries() async {
    final rows =
        await (select(flatLibrary)..orderBy([
              (f) => OrderingTerm.desc(f.createdAt),
              (f) => OrderingTerm.desc(f.id),
            ]))
            .get();
    return rows.map(_mapRow).toList();
  }

  /// Fetch one entry by id, or null.
  Future<FlatLibraryEntry?> getEntryById(int id) async {
    final row = await (select(
      flatLibrary,
    )..where((f) => f.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  /// Find the best master flat for a light frame's parameters.
  ///
  /// Matching rules (mirrors [DarkLibraryDao.findBestMatch]):
  /// - `filter` must match exactly (a flat is filter-specific) when provided.
  /// - `gain`, `offset`, and binning must match exactly.
  /// - Optical-train tag must match exactly when both sides provide one.
  /// - Temperature must be within [temperatureToleranceC] when both are known.
  /// - Among matches, the closest-temperature entry wins; ties break newest.
  ///
  /// Returns null when nothing qualifies.
  Future<FlatLibraryEntry?> findBestMatch({
    String? filter,
    int gain = 0,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    String? opticalTrainId,
    double? temperature,
    double temperatureToleranceC = 5.0,
  }) async {
    final train = opticalTrainId?.trim();
    final rows =
        await (select(flatLibrary)..where((f) {
              var matches =
                  f.gain.equals(gain) &
                  f.offset.equals(offset) &
                  f.binX.equals(binX) &
                  f.binY.equals(binY);
              if (filter != null && filter.trim().isNotEmpty) {
                matches = matches & f.filter.equals(filter.trim());
              }
              if (train != null && train.isNotEmpty) {
                // Accept rows with a matching tag OR no tag at all (a generic
                // flat).
                matches =
                    matches &
                    (f.opticalTrainId.equals(train) |
                        f.opticalTrainId.isNull());
              }
              return matches;
            }))
            .get();
    if (rows.isEmpty) return null;

    var candidates = rows.map(_mapRow).toList();

    // Temperature gate (only when both sides know the temperature).
    if (temperature != null) {
      candidates = candidates.where((c) {
        if (c.temperature == null) return true; // accept temp-less flats
        return (c.temperature! - temperature).abs() <= temperatureToleranceC;
      }).toList();
    }
    if (candidates.isEmpty) return null;

    if (temperature == null) {
      candidates.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return candidates.first;
    }
    candidates.sort((a, b) {
      final aD = a.temperature != null
          ? (a.temperature! - temperature).abs()
          : double.maxFinite;
      final bD = b.temperature != null
          ? (b.temperature! - temperature).abs()
          : double.maxFinite;
      final byTemp = aD.compareTo(bD);
      if (byTemp != 0) return byTemp;
      return b.createdAt.compareTo(a.createdAt);
    });
    return candidates.first;
  }

  /// Delete one entry by id.
  Future<int> deleteEntry(int id) =>
      (delete(flatLibrary)..where((f) => f.id.equals(id))).go();

  FlatLibraryEntry _mapRow(FlatLibraryRow row) {
    return FlatLibraryEntry(
      id: row.id,
      filePath: row.filePath,
      filter: row.filter,
      equipmentProfileId: row.equipmentProfileId,
      opticalTrainId: row.opticalTrainId,
      temperature: row.temperature,
      gain: row.gain,
      offset: row.offset,
      binX: row.binX,
      binY: row.binY,
      width: row.width,
      height: row.height,
      flatKind: row.flatKind,
      masterFrameCount: row.masterFrameCount,
      createdAt: fromEpochSeconds(row.createdAt),
    );
  }
}

/// Riverpod provider for [FlatLibraryDao].
final flatLibraryDaoProvider = Provider<FlatLibraryDao>((ref) {
  return FlatLibraryDao(ref.watch(databaseProvider));
});

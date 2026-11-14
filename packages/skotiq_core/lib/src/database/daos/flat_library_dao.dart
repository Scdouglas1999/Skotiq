import 'package:drift/drift.dart';

import '../../models/imaging/integrated_master.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'flat_library_dao.g.dart';

/// Reads and writes for `flat_library`: the master-flat artifact library, the
/// counterpart to `dark_library`. Which flat calibrates a light is
/// `selectFlat`'s rule, not a query here.
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
    int? gain,
    int? offset,
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

  Future<FlatLibraryEntry?> getEntryById(int id) async {
    final row = await (select(
      flatLibrary,
    )..where((f) => f.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

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

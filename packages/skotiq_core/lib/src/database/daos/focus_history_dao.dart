import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/focus_history.dart';

part 'focus_history_dao.g.dart';

/// Every profile's focus history, temperature line, reference filter and
/// filter offsets. A profile is written whole, so its rows always agree.
@DriftAccessor(
  tables: [FocusHistoryPoints, FocusProfileModels, FocusFilterOffsets],
)
class FocusHistoryDao extends DatabaseAccessor<SkotiqDatabase>
    with _$FocusHistoryDaoMixin {
  FocusHistoryDao(super.db);

  Future<List<FocusHistoryEntry>> allPoints() => (select(
    focusHistoryPoints,
  )..orderBy([(p) => OrderingTerm.asc(p.recordedAt)])).get();

  Future<List<FocusProfileModelEntry>> allModels() =>
      select(focusProfileModels).get();

  Future<List<FocusFilterOffsetEntry>> allOffsets() =>
      select(focusFilterOffsets).get();

  /// Replaces everything stored for [profileId] with the given rows.
  Future<void> replaceProfile(
    String profileId, {
    required List<FocusHistoryPointsCompanion> points,
    required FocusProfileModelsCompanion model,
    required List<FocusFilterOffsetsCompanion> offsets,
  }) => transaction(() async {
    await deleteProfile(profileId);
    await batch((b) {
      b.insertAll(focusHistoryPoints, points);
      b.insert(focusProfileModels, model);
      b.insertAll(focusFilterOffsets, offsets);
    });
  });

  Future<void> deleteProfile(String profileId) => transaction(() async {
    await (delete(
      focusHistoryPoints,
    )..where((p) => p.profileId.equals(profileId))).go();
    await (delete(
      focusProfileModels,
    )..where((m) => m.profileId.equals(profileId))).go();
    await (delete(
      focusFilterOffsets,
    )..where((o) => o.profileId.equals(profileId))).go();
  });
}

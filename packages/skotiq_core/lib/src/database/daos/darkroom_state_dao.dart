import 'package:drift/drift.dart';

import '../database.dart';

part 'darkroom_state_dao.g.dart';

/// Reads and writes for `darkroom_state`: one text value per key.
@DriftAccessor(include: {'../schema/darkroom.drift'})
class DarkroomStateDao extends DatabaseAccessor<SkotiqDatabase>
    with _$DarkroomStateDaoMixin {
  DarkroomStateDao(super.db);

  Future<String?> valueOf(String key) async {
    final row = await (select(
      darkroomState,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// Stores [value] under [key], replacing what was there.
  Future<void> put(String key, String value, {required String updatedAt}) =>
      into(darkroomState).insertOnConflictUpdate(
        DarkroomStateCompanion.insert(
          key: key,
          value: value,
          updatedAt: updatedAt,
        ),
      );
}

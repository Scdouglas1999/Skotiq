import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/narrowband_composite.dart';
import '../../providers/database_provider.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'narrowband_composites_dao.g.dart';

/// Reads and writes for `narrowband_composites`: one row per applied
/// SHO/HOO/etc. palette combine.
@DriftAccessor(include: {'../schema/post_session.drift'})
class NarrowbandCompositesDao extends DatabaseAccessor<SkotiqDatabase>
    with _$NarrowbandCompositesDaoMixin {
  NarrowbandCompositesDao(super.db);

  /// Insert a composite row and return its id. [createdAt] defaults to "now"
  /// (UTC seconds) when omitted; [componentMasterIds] is JSON-encoded into the
  /// `component_master_ids` column.
  Future<int> insertComposite({
    int? targetId,
    required String palette,
    required List<int> componentMasterIds,
    required String outputPath,
    int width = 0,
    int height = 0,
    DateTime? createdAt,
  }) {
    final composite = NarrowbandComposite(
      targetId: targetId,
      palette: palette,
      componentMasterIds: componentMasterIds,
      outputPath: outputPath,
      width: width,
      height: height,
      createdAt: createdAt ?? DateTime.now().toUtc(),
    );
    return into(narrowbandComposites).insert(
      NarrowbandCompositesCompanion.insert(
        targetId: Value(composite.targetId),
        palette: Value(composite.palette),
        componentMasterIds: Value(composite.componentMasterIdsJson),
        outputPath: composite.outputPath,
        width: Value(composite.width),
        height: Value(composite.height),
        createdAt: toEpochSeconds(composite.createdAt),
      ),
    );
  }

  /// Fetch a composite by id, or null when absent.
  Future<NarrowbandComposite?> getById(int id) async {
    final row = await (select(
      narrowbandComposites,
    )..where((c) => c.id.equals(id))).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// All composites, newest first.
  Future<List<NarrowbandComposite>> getAll() async {
    final rows = await (select(
      narrowbandComposites,
    )..orderBy(_newestFirst)).get();
    return rows.map(_map).toList();
  }

  /// Composites for a given target, newest first.
  Future<List<NarrowbandComposite>> getForTarget(int targetId) async {
    final rows =
        await (select(narrowbandComposites)
              ..where((c) => c.targetId.equals(targetId))
              ..orderBy(_newestFirst))
            .get();
    return rows.map(_map).toList();
  }

  /// Delete a composite by id.
  Future<int> deleteComposite(int id) =>
      (delete(narrowbandComposites)..where((c) => c.id.equals(id))).go();

  static final List<OrderingTerm Function(NarrowbandComposites)> _newestFirst =
      [(c) => OrderingTerm.desc(c.createdAt), (c) => OrderingTerm.desc(c.id)];

  NarrowbandComposite _map(NarrowbandCompositeRow row) {
    return NarrowbandComposite(
      id: row.id,
      targetId: row.targetId,
      palette: row.palette,
      componentMasterIds: NarrowbandComposite.decodeComponentMasterIds(
        row.componentMasterIds,
      ),
      outputPath: row.outputPath,
      width: row.width,
      height: row.height,
      createdAt: fromEpochSeconds(row.createdAt),
    );
  }
}

/// Riverpod provider for [NarrowbandCompositesDao].
final narrowbandCompositesDaoProvider = Provider<NarrowbandCompositesDao>((
  ref,
) {
  return NarrowbandCompositesDao(ref.watch(databaseProvider));
});

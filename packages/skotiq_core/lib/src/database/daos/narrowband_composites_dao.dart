import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/narrowband_composite.dart';
import '../../providers/database_provider.dart';
import '../database.dart';

/// Data-access object for the v44 `narrowband_composites` table — one row per
/// applied SHO/HOO/etc. palette combine.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createNarrowbandCompositesTable]) rather than a drift
/// `Table` class, so this DAO is a plain class that reads/writes through the
/// database's `customSelect`/`customInsert`/`customStatement` APIs — mirroring
/// [CampaignsDao] and [NightReportsDao]. It is deliberately NOT a
/// `@DriftAccessor`.
///
/// SQLite errors propagate; reads map nullable columns to the model's nullable
/// fields.
class NarrowbandCompositesDao {
  NarrowbandCompositesDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, target_id, palette, component_master_ids, output_path, '
      'width, height, created_at';

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
    final at = _toEpochSeconds(createdAt ?? DateTime.now().toUtc());
    return _db.customInsert(
      'INSERT INTO narrowband_composites('
      'target_id, palette, component_master_ids, output_path, '
      'width, height, created_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(targetId),
        Variable<String>(palette),
        Variable<String>(
          NarrowbandComposite(
            palette: palette,
            componentMasterIds: componentMasterIds,
            outputPath: outputPath,
            createdAt: DateTime.now().toUtc(),
          ).componentMasterIdsJson,
        ),
        Variable<String>(outputPath),
        Variable<int>(width),
        Variable<int>(height),
        Variable<int>(at),
      ],
    );
  }

  /// Fetch a composite by id, or null when absent.
  Future<NarrowbandComposite?> getById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM narrowband_composites WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _map(rows.first);
  }

  /// All composites, newest first.
  Future<List<NarrowbandComposite>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM narrowband_composites '
          'ORDER BY created_at DESC, id DESC',
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Composites for a given target, newest first.
  Future<List<NarrowbandComposite>> getForTarget(int targetId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM narrowband_composites '
          'WHERE target_id = ? ORDER BY created_at DESC, id DESC',
          variables: [Variable<int>(targetId)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Delete a composite by id.
  Future<int> deleteComposite(int id) {
    return _db.customUpdate(
      'DELETE FROM narrowband_composites WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
  }

  NarrowbandComposite _map(QueryRow row) {
    return NarrowbandComposite(
      id: row.read<int>('id'),
      targetId: row.readNullable<int>('target_id'),
      palette: row.read<String>('palette'),
      componentMasterIds: NarrowbandComposite.decodeComponentMasterIds(
        row.read<String>('component_master_ids'),
      ),
      outputPath: row.read<String>('output_path'),
      width: row.read<int>('width'),
      height: row.read<int>('height'),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [NarrowbandCompositesDao].
final narrowbandCompositesDaoProvider = Provider<NarrowbandCompositesDao>((
  ref,
) {
  return NarrowbandCompositesDao(ref.watch(databaseProvider));
});

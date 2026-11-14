import 'package:drift/drift.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show MosaicStartCorner;

import '../../models/imaging/mosaic_project.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'mosaic_projects_dao.g.dart';

/// Reads and writes for `mosaic_projects`: the durable record that makes a
/// mosaic a first-class entity linking grid config → per-panel targets →
/// per-panel masters → the stitched output.
///
/// SQLite errors propagate; reads map nullable columns to the model's nullable
/// fields.
@DriftAccessor(include: {'../schema/mosaic.drift'})
class MosaicProjectsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$MosaicProjectsDaoMixin {
  MosaicProjectsDao(super.db);

  /// Insert a mosaic project row and return its id. [createdAt]/[updatedAt]
  /// default to "now" (UTC seconds) when omitted.
  Future<int> create({
    int? targetId,
    required String name,
    required int rows,
    required int cols,
    double overlapPct = 15.0,
    double positionAngleDeg = 0.0,
    MosaicStartCorner startCorner = MosaicStartCorner.topLeft,
    bool serpentine = true,
    MosaicProjectStatus status = MosaicProjectStatus.planning,
    int? outputMasterId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    final created = toEpochSeconds(createdAt ?? DateTime.now());
    final updated = updatedAt == null ? created : toEpochSeconds(updatedAt);
    return into(mosaicProjects).insert(
      MosaicProjectsCompanion.insert(
        targetId: Value(targetId),
        name: name,
        rows: rows,
        cols: cols,
        overlapPct: Value(overlapPct),
        positionAngleDeg: Value(positionAngleDeg),
        startCorner: Value(startCorner.name),
        serpentine: Value(serpentine),
        status: Value(status.wire),
        outputMasterId: Value(outputMasterId),
        createdAt: created,
        updatedAt: updated,
      ),
    );
  }

  Future<MosaicProject?> getById(int id) async {
    final row = await (select(
      mosaicProjects,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// All projects, newest first.
  Future<List<MosaicProject>> listAll() => _newestFirst();

  /// Collaborative projects the unattended owner/participant poller still has
  /// work to drive: published to a hub (`hub_mosaic_id` set) and not yet
  /// `complete`. Scopes the poll sweep to the handful of in-flight collaborative
  /// mosaics rather than every local project. Newest first.
  Future<List<MosaicProject>> listActiveCollaborative() => _newestFirst(
    where: (p) =>
        p.hubMosaicId.isNotNull() &
        p.hubMosaicId.equals('').not() &
        (p.collabStatus.isNull() | p.collabStatus.equals('complete').not()),
  );

  /// Fetch the local project linked to [hubMosaicId], or null when this
  /// device has not joined/published that hub mosaic. Used by the join flow to
  /// reuse an existing local mirror instead of creating a duplicate project.
  Future<MosaicProject?> getByHubMosaicId(String hubMosaicId) async {
    if (hubMosaicId.isEmpty) return null;
    final row =
        await (select(mosaicProjects)
              ..where((p) => p.hubMosaicId.equals(hubMosaicId))
              ..orderBy([(p) => OrderingTerm.asc(p.id)])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// Projects with the given lifecycle [status], newest first.
  Future<List<MosaicProject>> listByStatus(MosaicProjectStatus status) =>
      _newestFirst(where: (p) => p.status.equals(status.wire));

  /// Update a project's lifecycle [status] (and `updated_at`). Returns the
  /// number of rows changed.
  Future<int> updateStatus(
    int id,
    MosaicProjectStatus status, {
    DateTime? now,
  }) => _write(id, now, MosaicProjectsCompanion(status: Value(status.wire)));

  /// Attach the stitched output's `integrated_masters.id` to the project and
  /// mark it [MosaicProjectStatus.complete] (and bump `updated_at`). Returns the
  /// number of rows changed.
  Future<int> setOutputMaster(int id, int outputMasterId, {DateTime? now}) =>
      _write(
        id,
        now,
        MosaicProjectsCompanion(
          outputMasterId: Value(outputMasterId),
          status: Value(MosaicProjectStatus.complete.wire),
        ),
      );

  /// Record that this project was published to the hub as a collaborative
  /// mosaic: persist the hub mosaic id, the collaborative [role]
  /// (`owner`|`participant`), and set `collab_status = 'published'`. Returns the
  /// number of rows changed.
  Future<int> setHubMosaic(
    int id,
    String hubMosaicId,
    String role, {
    DateTime? now,
  }) => _write(
    id,
    now,
    MosaicProjectsCompanion(
      hubMosaicId: Value(hubMosaicId),
      collabRole: Value(role),
      collabStatus: const Value('published'),
    ),
  );

  /// Update a published project's hub-side collaborative lifecycle
  /// (`published`|`assembling`|`complete`). Returns the number of rows changed.
  Future<int> setCollabStatus(int id, String collabStatus, {DateTime? now}) =>
      _write(
        id,
        now,
        MosaicProjectsCompanion(collabStatus: Value(collabStatus)),
      );

  /// Delete a project by id. `mosaic_panels` rows cascade
  /// (`ON DELETE CASCADE`). Returns the number of rows changed.
  Future<int> deleteProject(int id) =>
      (delete(mosaicProjects)..where((p) => p.id.equals(id))).go();

  Future<List<MosaicProject>> _newestFirst({
    Expression<bool> Function(MosaicProjects p)? where,
  }) async {
    final query = select(mosaicProjects)
      ..orderBy([
        (p) => OrderingTerm.desc(p.createdAt),
        (p) => OrderingTerm.desc(p.id),
      ]);
    if (where != null) query.where(where);
    final rows = await query.get();
    return rows.map(_map).toList();
  }

  /// Writes [changes] to project [id] and bumps `updated_at` to [now].
  Future<int> _write(int id, DateTime? now, MosaicProjectsCompanion changes) {
    return (update(mosaicProjects)..where((p) => p.id.equals(id))).write(
      changes.copyWith(updatedAt: Value(toEpochSeconds(now ?? DateTime.now()))),
    );
  }

  MosaicProject _map(MosaicProjectRow row) {
    return MosaicProject(
      id: row.id,
      targetId: row.targetId,
      name: row.name,
      rows: row.rows,
      cols: row.cols,
      overlapPct: row.overlapPct,
      positionAngleDeg: row.positionAngleDeg,
      startCorner: MosaicStartCorner.values.byName(row.startCorner),
      serpentine: row.serpentine,
      status: MosaicProjectStatus.fromWire(row.status),
      outputMasterId: row.outputMasterId,
      createdAt: fromEpochSeconds(row.createdAt),
      updatedAt: fromEpochSeconds(row.updatedAt),
      hubMosaicId: row.hubMosaicId,
      collabRole: row.collabRole,
      collabStatus: row.collabStatus,
    );
  }
}

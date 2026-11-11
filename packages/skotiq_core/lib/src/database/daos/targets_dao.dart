import 'package:drift/drift.dart';

import 'package:skotiq_astro/skotiq_astro.dart';
import '../../backend/roles/host_data/host_records.dart';
import '../database.dart';
import '../tables/targets.dart';

part 'targets_dao.g.dart';

@DriftAccessor(tables: [Targets])
class TargetsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$TargetsDaoMixin
    implements TargetLibrary {
  TargetsDao(super.db);

  /// Predicate identifying "untracked" library targets that are safe to remove
  /// in the Analytics → Projects cleanup. A target is untracked only when it has
  /// NO integration goal, is NOT a favorite, has NO captured data, and is NOT
  /// referenced by any imaging session. This deliberately preserves every target
  /// the user has invested in (favorites, goals, captures, sessions).
  Expression<bool> _untrackedPredicate($TargetsTable t) {
    final sessions = attachedDatabase.imagingSessions;
    final referencedBySession = existsQuery(
      selectOnly(sessions)
        ..addColumns([sessions.id])
        ..where(
          sessions.targetId.equalsExp(t.id) & sessions.targetId.isNotNull(),
        ),
    );
    return t.goalIntegrationSecs.isSmallerOrEqualValue(0.0) &
        t.isFavorite.equals(false) &
        t.capturedSubs.equals(0) &
        t.totalIntegrationSecs.equals(0.0) &
        referencedBySession.not();
  }

  /// Counts library targets matching [_untrackedPredicate]. Drives the opt-in
  /// "Remove untracked targets" affordance (button is hidden when this is 0).
  Future<int> countUntrackedTargets() async {
    final count = targets.id.count();
    final query = selectOnly(targets)
      ..addColumns([count])
      ..where(_untrackedPredicate(targets));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// Permanently deletes every library target matching [_untrackedPredicate].
  /// Returns the number of rows removed. Favorites, goal-tracked targets,
  /// targets with captured data, and session-referenced targets are never
  /// touched. This is irreversible — callers must confirm with the user first.
  Future<int> deleteUntrackedTargets() {
    return (delete(targets)..where(_untrackedPredicate)).go();
  }

  Future<List<Target>> getAllTargets() => select(targets).get();

  @override
  Stream<List<Target>> watchAllTargets() => select(targets).watch();

  Future<List<Target>> getFavoriteTargets() {
    return (select(targets)..where((t) => t.isFavorite.equals(true))).get();
  }

  @override
  Stream<List<Target>> watchFavoriteTargets() {
    return (select(targets)..where((t) => t.isFavorite.equals(true))).watch();
  }

  Future<Target?> getTargetById(int id) {
    return (select(targets)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Get target by catalog ID (e.g., M42, NGC7000)
  Future<Target?> getTargetByCatalogId(String catalogId) {
    return (select(
      targets,
    )..where((t) => t.catalogId.equals(catalogId))).getSingleOrNull();
  }

  /// Search targets by name
  Future<List<Target>> searchTargets(String query) {
    return (select(
          targets,
        )..where((t) => t.name.like('%$query%') | t.catalogId.like('%$query%')))
        .get();
  }

  Future<List<Target>> getTargetsByType(String objectType) {
    return (select(
      targets,
    )..where((t) => t.objectType.equals(objectType))).get();
  }

  Future<int> createTarget(TargetsCompanion target) {
    return into(targets).insert(target);
  }

  /// `targets.id` for the object a sequence's Target node images, creating the
  /// row the first time that object is actually imaged.
  ///
  /// A Target node built by hand in the sequencer carries no `catalogTargetId`,
  /// so every frame it produced was written with `target_id` NULL: the Session
  /// Report filed a whole night under "Untargeted", per-target integration
  /// goals could never complete, and project tracking counted nothing —
  /// while the FITS `OBJECT` card and the file name both named the target.
  ///
  /// Matched on trimmed, case-insensitive name so re-running the same sequence
  /// keeps accumulating against one row instead of forking a new one per night.
  /// Coordinates are only used when the row has to be created; an existing
  /// row's coordinates are left alone (the library entry, or the planner, owns
  /// them).
  Future<int> findOrCreateByName({
    required String name,
    required double raHours,
    required double decDegrees,
  }) async {
    final trimmed = name.trim();
    final existing =
        await (select(targets)
              ..where((t) => t.name.lower().equals(trimmed.toLowerCase()))
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return existing.id;

    return createTarget(
      TargetsCompanion.insert(name: trimmed, ra: raHours, dec: decDegrees),
    );
  }

  Future<bool> updateTarget(Target target) {
    return update(targets).replace(target);
  }

  Future<int> deleteTarget(int id) {
    return (delete(targets)..where((t) => t.id.equals(id))).go();
  }

  Future<void> toggleFavorite(int id) async {
    await (update(targets)..where((t) => t.id.equals(id))).write(
      TargetsCompanion.custom(
        isFavorite: targets.isFavorite.caseMatch(
          when: {const Constant(true): const Constant(false)},
          orElse: const Constant(true),
        ),
        updatedAt: Variable(DateTime.now()),
      ),
    );
  }

  Future<void> updateProgress(
    int id, {
    int? capturedSubs,
    double? totalIntegrationSecs,
    double? goalIntegrationSecs,
    String? filterProgress,
  }) async {
    final updates = TargetsCompanion(
      capturedSubs: capturedSubs != null
          ? Value(capturedSubs)
          : const Value.absent(),
      totalIntegrationSecs: totalIntegrationSecs != null
          ? Value(totalIntegrationSecs)
          : const Value.absent(),
      goalIntegrationSecs: goalIntegrationSecs != null
          ? Value(goalIntegrationSecs)
          : const Value.absent(),
      filterProgress: filterProgress != null
          ? Value(filterProgress)
          : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    );

    await (update(targets)..where((t) => t.id.equals(id))).write(updates);
  }

  /// Set the target's multi-night integration goal in seconds.
  Future<void> setGoalIntegrationSecs(
    int id,
    double goalIntegrationSecs,
  ) async {
    await (update(targets)..where((t) => t.id.equals(id))).write(
      TargetsCompanion(
        goalIntegrationSecs: Value(goalIntegrationSecs),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<List<Target>> getTargetsByPriority() {
    return (select(
      targets,
    )..orderBy([(t) => OrderingTerm.desc(t.priority)])).get();
  }

  /// Get targets that are observable tonight
  Future<List<Target>> getObservableTargets(
    double latitude,
    double longitude,
  ) async {
    final allTargets = await getAllTargets();
    final nowUtc = DateTime.now().toUtc();

    final observable = allTargets.where((target) {
      final altitudeDeg = _calculateAltitudeDegrees(
        latitudeDeg: latitude,
        longitudeDeg: longitude,
        raHours: target.ra,
        decDeg: target.dec,
        atUtc: nowUtc,
      );
      return altitudeDeg >= target.minAltitude;
    }).toList();

    observable.sort((a, b) => b.priority.compareTo(a.priority));
    return observable;
  }

  double _calculateAltitudeDegrees({
    required double latitudeDeg,
    required double longitudeDeg,
    required double raHours,
    required double decDeg,
    required DateTime atUtc,
  }) {
    final (altitude, _) = AstronomyCalculations.objectAltAz(
      raDeg: raHours * 15.0,
      decDeg: decDeg,
      dt: atUtc,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
    return altitude;
  }
}

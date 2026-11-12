import 'package:drift/drift.dart';

import '../../models/campaign.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'campaigns_dao.g.dart';

/// Reads and writes for `campaigns`: the durable NINA-style multi-night
/// `(target, filter, accepted, desired, last_date)` campaign counter.
///
/// This DAO is ADDITIVE bookkeeping: it never feeds the live `SchedulerEngine`
/// goals-complete reject (which stays a read-only derivation over
/// `integration_goals` + `captured_images.is_accepted=1`). [recordAccepted] is
/// the only write driven by the acceptance path, and it only ever raises a
/// denormalized counter.
@DriftAccessor(include: {'../schema/planning.drift'})
class CampaignsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$CampaignsDaoMixin {
  CampaignsDao(super.db);

  /// Create (or update) the desired accepted-frame goal for a `(target, filter)`
  /// campaign. Filter matching is case-insensitive, mirroring how captured
  /// frames are counted; the stored `filter` keeps the first-written casing.
  ///
  /// When a campaign already exists for the pair, only `desired_count` (and
  /// `updated_at`) change — the running `accepted_count` and `last_date` are
  /// preserved so re-tuning the goal mid-campaign never resets progress.
  /// Returns the campaign row id.
  Future<int> upsertDesired({
    required int targetId,
    required String filter,
    required int desiredCount,
    DateTime? now,
  }) async {
    final at = toEpochSeconds(now ?? DateTime.now());
    final existing = await _findRow(targetId, filter);
    if (existing != null) {
      final id = existing.read<int>('id');
      await _updateRow(
        id,
        CampaignsCompanion(
          desiredCount: Value(desiredCount),
          updatedAt: Value(at),
        ),
      );
      return id;
    }
    return into(campaigns).insert(
      CampaignsCompanion.insert(
        targetId: targetId,
        filter: filter,
        acceptedCount: const Value(0),
        desiredCount: Value(desiredCount),
        lastDate: const Value(null),
        createdAt: at,
        updatedAt: at,
      ),
    );
  }

  /// Credit [delta] accepted frames to the `(target, filter)` campaign and
  /// stamp `last_date` with [capturedAt] (defaults to now).
  ///
  /// This is the additive acceptance hook. When no campaign row exists yet the
  /// pair is auto-created with `desired_count = 0` so the credit is never lost
  /// (the operator may set a desired count later via [upsertDesired] without
  /// resetting the accumulated count). Returns the campaign row id, or null when
  /// [delta] is <= 0 (a rejected/no-op frame must never advance the counter).
  Future<int?> recordAccepted({
    required int targetId,
    required String filter,
    int delta = 1,
    DateTime? capturedAt,
  }) async {
    if (delta <= 0) return null;
    final at = toEpochSeconds(capturedAt ?? DateTime.now());
    final existing = await _findRow(targetId, filter);
    if (existing != null) {
      final id = existing.read<int>('id');
      await _updateRow(
        id,
        CampaignsCompanion.custom(
          acceptedCount: campaigns.acceptedCount + Variable(delta),
          lastDate: Variable(at),
          updatedAt: Variable(at),
        ),
      );
      return id;
    }
    return into(campaigns).insert(
      CampaignsCompanion.insert(
        targetId: targetId,
        filter: filter,
        acceptedCount: Value(delta),
        desiredCount: const Value(0),
        lastDate: Value(at),
        createdAt: at,
        updatedAt: at,
      ),
    );
  }

  /// All campaigns for a target, ordered by filter.
  Future<List<Campaign>> getForTarget(int targetId) async {
    final rows =
        await (select(campaigns)
              ..where((c) => c.targetId.equals(targetId))
              ..orderBy([(c) => OrderingTerm.asc(c.filter)]))
            .get();
    return rows.map(_map).toList();
  }

  /// The single campaign for a `(target, filter)` pair, or null when absent.
  /// Filter matching is case-insensitive.
  Future<Campaign?> getForTargetFilter(int targetId, String filter) async {
    final row = await _findRow(targetId, filter);
    return row == null ? null : _map(campaigns.map(row.data));
  }

  /// Remaining accepted frames for a `(target, filter)` campaign, clamped to
  /// zero. Returns null when no campaign row exists for the pair.
  Future<int?> remaining(int targetId, String filter) async {
    final found = await _findRow(targetId, filter);
    if (found == null) return null;
    final row = campaigns.map(found.data);
    final r = row.desiredCount - row.acceptedCount;
    return r < 0 ? 0 : r;
  }

  /// SQL text on purpose: [recordAccepted] runs this for every accepted
  /// frame, and drift's typed result made the lookup 72 -> 100 us.
  Future<QueryRow?> _findRow(int targetId, String filter) {
    return customSelect(
      'SELECT * FROM campaigns '
      'WHERE target_id = ? AND LOWER(filter) = LOWER(?) LIMIT 1',
      variables: [Variable<int>(targetId), Variable<String>(filter)],
    ).getSingleOrNull();
  }

  Future<void> _updateRow(int id, Insertable<CampaignRow> changes) =>
      (update(campaigns)..where((c) => c.id.equals(id))).write(changes);

  Campaign _map(CampaignRow row) {
    final lastDate = row.lastDate;
    return Campaign(
      id: row.id,
      targetId: row.targetId,
      filter: row.filter,
      acceptedCount: row.acceptedCount,
      desiredCount: row.desiredCount,
      lastCaptureAt: lastDate == null ? null : fromEpochSeconds(lastDate),
      createdAt: fromEpochSeconds(row.createdAt),
      updatedAt: fromEpochSeconds(row.updatedAt),
    );
  }
}

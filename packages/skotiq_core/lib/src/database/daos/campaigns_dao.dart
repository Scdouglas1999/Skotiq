import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/campaign.dart';
import '../../providers/database_provider.dart';
import '../database.dart';

/// Data-access object for the v43 `campaigns` table — the durable NINA-style
/// multi-night `(target, filter, accepted, desired, last_date)` campaign
/// counter.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createCampaignsTable]) rather than a drift `Table`
/// class, so this DAO is a plain class that reads/writes through the database's
/// `customSelect`/`customInsert`/`customStatement` APIs — mirroring
/// [NightReportsDao] and `IntegrationGoalService`. It is deliberately NOT a
/// `@DriftAccessor`.
///
/// This DAO is ADDITIVE bookkeeping: it never feeds the live `SchedulerEngine`
/// goals-complete reject (which stays a read-only derivation over
/// `integration_goals` + `captured_images.is_accepted=1`). [recordAccepted] is
/// the only write driven by the acceptance path, and it only ever raises a
/// denormalized counter.
class CampaignsDao {
  CampaignsDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, target_id, filter, accepted_count, desired_count, '
      'last_date, created_at, updated_at';

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
    final at = _toEpochSeconds(now ?? DateTime.now());
    final existing = await _findRow(targetId, filter);
    if (existing != null) {
      final id = existing.read<int>('id');
      await _db.customStatement(
        'UPDATE campaigns SET desired_count = ?, updated_at = ? WHERE id = ?',
        [desiredCount, at, id],
      );
      return id;
    }
    return _db.customInsert(
      'INSERT INTO campaigns('
      'target_id, filter, accepted_count, desired_count, '
      'last_date, created_at, updated_at'
      ') VALUES (?, ?, 0, ?, NULL, ?, ?)',
      variables: [
        Variable<int>(targetId),
        Variable<String>(filter),
        Variable<int>(desiredCount),
        Variable<int>(at),
        Variable<int>(at),
      ],
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
    final at = _toEpochSeconds(capturedAt ?? DateTime.now());
    final existing = await _findRow(targetId, filter);
    if (existing != null) {
      final id = existing.read<int>('id');
      await _db.customStatement(
        'UPDATE campaigns SET accepted_count = accepted_count + ?, '
        'last_date = ?, updated_at = ? WHERE id = ?',
        [delta, at, at, id],
      );
      return id;
    }
    return _db.customInsert(
      'INSERT INTO campaigns('
      'target_id, filter, accepted_count, desired_count, '
      'last_date, created_at, updated_at'
      ') VALUES (?, ?, ?, 0, ?, ?, ?)',
      variables: [
        Variable<int>(targetId),
        Variable<String>(filter),
        Variable<int>(delta),
        Variable<int>(at),
        Variable<int>(at),
        Variable<int>(at),
      ],
    );
  }

  /// All campaigns for a target, ordered by filter.
  Future<List<Campaign>> getForTarget(int targetId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM campaigns WHERE target_id = ? ORDER BY filter ASC',
          variables: [Variable<int>(targetId)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// The single campaign for a `(target, filter)` pair, or null when absent.
  /// Filter matching is case-insensitive.
  Future<Campaign?> getForTargetFilter(int targetId, String filter) async {
    final row = await _findRow(targetId, filter);
    return row == null ? null : _map(row);
  }

  /// Remaining accepted frames for a `(target, filter)` campaign, clamped to
  /// zero. Returns null when no campaign row exists for the pair.
  Future<int?> remaining(int targetId, String filter) async {
    final row = await _findRow(targetId, filter);
    if (row == null) return null;
    final desired = row.read<int>('desired_count');
    final accepted = row.read<int>('accepted_count');
    final r = desired - accepted;
    return r < 0 ? 0 : r;
  }

  Future<QueryRow?> _findRow(int targetId, String filter) {
    return _db
        .customSelect(
          'SELECT $_columns FROM campaigns '
          'WHERE target_id = ? AND LOWER(filter) = LOWER(?) LIMIT 1',
          variables: [Variable<int>(targetId), Variable<String>(filter)],
        )
        .getSingleOrNull();
  }

  Campaign _map(QueryRow row) {
    final lastDate = row.readNullable<int>('last_date');
    return Campaign(
      id: row.read<int>('id'),
      targetId: row.read<int>('target_id'),
      filter: row.read<String>('filter'),
      acceptedCount: row.read<int>('accepted_count'),
      desiredCount: row.read<int>('desired_count'),
      lastCaptureAt: lastDate == null ? null : _fromEpochSeconds(lastDate),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
      updatedAt: _fromEpochSeconds(row.read<int>('updated_at')),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [CampaignsDao].
final campaignsDaoProvider = Provider<CampaignsDao>((ref) {
  return CampaignsDao(ref.watch(databaseProvider));
});

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/darkroom/delivery.dart';
import '../../providers/database_provider.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'delivery_journal_dao.g.dart';

/// An outcome was recorded for a (destination, job, file) that has no journal
/// row — nothing ever recorded an attempt for it.
class DeliveryJournalMissingException implements Exception {
  final int targetId;
  final int jobId;
  final String filePath;

  const DeliveryJournalMissingException(
    this.targetId,
    this.jobId,
    this.filePath,
  );

  @override
  String toString() =>
      'No delivery journal entry for target $targetId, job $jobId, '
      'file $filePath';
}

/// Reads and writes for `delivery_journal`: what was sent where, how big it
/// was, and how it ended.
///
/// UPSERT ON RETRY. `(target_id, job_id, file_path)` is the row identity, so a
/// file retried overnight keeps ONE row carrying its running `attempts` count
/// and latest `last_error` rather than accumulating an append log the morning
/// report would have to fold. [recordAttempt] is a single SQLite upsert, so two
/// writers cannot lose a count between a read and a write. `last_error` is kept
/// after a later success, so the report can say a delivery recovered rather
/// than pretending it went cleanly the first time.
@DriftAccessor(include: {'../schema/darkroom.drift'})
class DeliveryJournalDao extends DatabaseAccessor<SkotiqDatabase>
    with _$DeliveryJournalDaoMixin {
  DeliveryJournalDao(super.db);

  /// Record that a delivery attempt is starting for one file on one
  /// destination, and return the entry as it now stands.
  ///
  /// Creates the row on the first attempt and increments `attempts` on every
  /// later one, leaving the entry [DeliveryAttemptState.retrying] until an
  /// outcome is recorded. [bytes] updates the recorded size only when given and
  /// positive, so a retry that has not restated the size keeps the known one.
  ///
  /// **A `delivered` row is left exactly as it is** and returned untouched: no
  /// attempt is starting for a file that has already arrived, so nothing about
  /// the row changes — not its state, not its count, not its `updated_at`. The
  /// caller reads the returned state and stops there.
  ///
  /// The guard is here rather than only at the call site because this write is
  /// the single door every path goes through — the job's own pass, the
  /// overnight sweep, and the loop that records a destination that would not
  /// open — and because a paired desktop's acknowledgement can land in the
  /// middle of a pass, between the moment the file was selected and this
  /// write. Without it the upsert set `state = excluded.state`, which is always
  /// `retrying`, so a re-run of a finished job walked an acknowledged peer row
  /// backwards from `delivered` to `retrying` while its `delivered_at` stayed
  /// set — a row saying both that the file arrived and that it has not — and
  /// the rig then offered the desktop a file it had already pulled.
  ///
  /// [requeueForRetry] is the one way back out of `delivered`, because that is
  /// the operator asking for it.
  Future<DeliveryJournalEntry> recordAttempt({
    required int targetId,
    required int jobId,
    required String filePath,
    int? bytes,
    DateTime? now,
  }) async {
    if (bytes != null && bytes < 0) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'a file size cannot be negative',
      );
    }
    final at = toEpochSeconds(now ?? DateTime.now());
    await into(deliveryJournal).insert(
      DeliveryJournalCompanion.insert(
        targetId: targetId,
        jobId: jobId,
        filePath: filePath,
        bytes: Value(bytes ?? 0),
        state: Value(DeliveryAttemptState.retrying.wire),
        attempts: const Value(1),
        createdAt: at,
        updatedAt: at,
      ),
      onConflict: _unlessDelivered(
        (old, excluded) => DeliveryJournalCompanion.custom(
          attempts: old.attempts + const Constant(1),
          bytes: _knownSize(old, excluded),
          state: excluded.state,
          updatedAt: excluded.updatedAt,
        ),
      ),
    );
    return _require(targetId, jobId, filePath);
  }

  /// Record that this file is still owed a delivery WITHOUT spending an
  /// attempt, and return the entry as it now stands.
  ///
  /// The stop case: the operator asked the pass to end while it was still
  /// working through the files, so nothing was tried for this one. Writing it
  /// as `failed` is what abandoned it — the sweep reads only `retrying` rows,
  /// so a terminal row is a file nothing on the rig ever looks at again — and
  /// counting an attempt would charge the retry budget for an attempt that was
  /// never made. The row is created if it is not there yet, because the sweep
  /// works entirely from this table: a file with no row is a file no later
  /// pass can find.
  ///
  /// `attempts` is left EXACTLY where it was on a row that already exists (and
  /// starts at zero on a new one), so the backoff and the budget stay the
  /// schedule the interrupted pass was on.
  ///
  /// A `delivered` row is left untouched and returned as it stands, for the
  /// reason [recordAttempt] gives: a file that already arrived is not owed a
  /// delivery, and a stop landing on a re-queued job's pass must not turn an
  /// acknowledged row back into an outstanding one.
  Future<DeliveryJournalEntry> recordStillOwed({
    required int targetId,
    required int jobId,
    required String filePath,
    required String reason,
    int? bytes,
    DateTime? now,
  }) async {
    if (bytes != null && bytes < 0) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'a file size cannot be negative',
      );
    }
    final at = toEpochSeconds(now ?? DateTime.now());
    await into(deliveryJournal).insert(
      DeliveryJournalCompanion.insert(
        targetId: targetId,
        jobId: jobId,
        filePath: filePath,
        bytes: Value(bytes ?? 0),
        state: Value(DeliveryAttemptState.retrying.wire),
        attempts: const Value(0),
        lastError: Value(reason),
        createdAt: at,
        updatedAt: at,
      ),
      onConflict: _unlessDelivered(
        (old, excluded) => DeliveryJournalCompanion.custom(
          state: excluded.state,
          lastError: excluded.lastError,
          bytes: _knownSize(old, excluded),
          updatedAt: excluded.updatedAt,
        ),
      ),
    );
    return _require(targetId, jobId, filePath);
  }

  /// Record that the file arrived and verified, with the [checksum] of the
  /// delivered bytes. Returns the entry as it now stands.
  Future<DeliveryJournalEntry> markDelivered({
    required int targetId,
    required int jobId,
    required String filePath,
    String? checksum,
    int? bytes,
    DateTime? now,
  }) async {
    await _require(targetId, jobId, filePath);
    final at = toEpochSeconds(now ?? DateTime.now());
    await (update(
      deliveryJournal,
    )..where((e) => _isEntry(e, targetId, jobId, filePath))).write(
      DeliveryJournalCompanion(
        state: Value(DeliveryAttemptState.delivered.wire),
        checksum: Value.absentIfNull(checksum),
        bytes: Value.absentIfNull(bytes == 0 ? null : bytes),
        deliveredAt: Value(at),
        updatedAt: Value(at),
      ),
    );
    return _require(targetId, jobId, filePath);
  }

  /// Record that this attempt failed and another is due, with [error] as the
  /// reason. Returns the entry as it now stands.
  Future<DeliveryJournalEntry> markRetrying({
    required int targetId,
    required int jobId,
    required String filePath,
    required String error,
    DateTime? now,
  }) => _recordOutcome(
    targetId: targetId,
    jobId: jobId,
    filePath: filePath,
    state: DeliveryAttemptState.retrying,
    error: error,
    now: now,
  );

  /// Record that every attempt is spent and the file did not arrive, with
  /// [error] as the last reason. Returns the entry as it now stands.
  Future<DeliveryJournalEntry> markFailed({
    required int targetId,
    required int jobId,
    required String filePath,
    required String error,
    DateTime? now,
  }) => _recordOutcome(
    targetId: targetId,
    jobId: jobId,
    filePath: filePath,
    state: DeliveryAttemptState.failed,
    error: error,
    now: now,
  );

  /// Put a spent row back in the retry queue with a fresh attempt budget, and
  /// return the entry as it now stands.
  ///
  /// This is the operator saying "try again" after fixing what the failure
  /// named — mounting the share, freeing space, moving the file that was in
  /// the way. `attempts` is RESET TO ZERO rather than left where it was: the
  /// delivery retry policy reads `attempts` for both the backoff and the
  /// budget, so a row re-queued at its spent count would wait the maximum
  /// backoff and then be terminal again on its first attempt — a retry in
  /// name only.
  ///
  /// `last_error` is KEPT. Until another attempt is made, why the file did not
  /// arrive is still the most recent true thing about it, and the status line
  /// goes on saying so while it waits.
  ///
  /// `delivered_at` is CLEARED. This is the one way back out of `delivered`, so
  /// it is also the one place that can leave an arrival timestamp on a file the
  /// journal now says has not arrived — the contradiction every other writer is
  /// guarded against.
  Future<DeliveryJournalEntry> requeueForRetry({
    required int targetId,
    required int jobId,
    required String filePath,
    DateTime? now,
  }) async {
    await _require(targetId, jobId, filePath);
    final at = toEpochSeconds(now ?? DateTime.now());
    await (update(
      deliveryJournal,
    )..where((e) => _isEntry(e, targetId, jobId, filePath))).write(
      DeliveryJournalCompanion(
        state: Value(DeliveryAttemptState.retrying.wire),
        attempts: const Value(0),
        deliveredAt: const Value(null),
        updatedAt: Value(at),
      ),
    );
    return _require(targetId, jobId, filePath);
  }

  /// The journal entry for one (destination, job, file), or null when nothing
  /// has been attempted for it.
  Future<DeliveryJournalEntry?> getEntry({
    required int targetId,
    required int jobId,
    required String filePath,
  }) async {
    final row =
        await (select(deliveryJournal)
              ..where((e) => _isEntry(e, targetId, jobId, filePath))
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// Every entry for one job, oldest first — what the morning report reads.
  Future<List<DeliveryJournalEntry>> listForJob(int jobId) => _list(
    (e) => e.jobId.equals(jobId),
    [(e) => OrderingTerm.asc(e.createdAt), (e) => OrderingTerm.asc(e.id)],
  );

  /// Every entry for one destination, newest first.
  Future<List<DeliveryJournalEntry>> listForTarget(int targetId) => _list(
    (e) => e.targetId.equals(targetId),
    [(e) => OrderingTerm.desc(e.updatedAt), (e) => OrderingTerm.desc(e.id)],
  );

  /// Every file still owed a delivery, oldest update first — the overnight
  /// retry sweep's work list.
  Future<List<DeliveryJournalEntry>> listPendingRetry() => _list(
    (e) => e.state.equals(DeliveryAttemptState.retrying.wire),
    [(e) => OrderingTerm.asc(e.updatedAt), (e) => OrderingTerm.asc(e.id)],
  );

  /// The shared write behind [markRetrying] and [markFailed].
  ///
  /// **A `delivered` row is left exactly as it is** and returned untouched, for
  /// the reason [recordAttempt] gives at length. The guard belongs here as well
  /// as there because these two are reached on paths that never went through
  /// [recordAttempt]: the overnight sweep writes the outcome of an attempt it
  /// started before it read the row, and the acknowledgement from a paired
  /// desktop can land at any point in between. Without it an acknowledged row
  /// walked back to `failed` while its `delivered_at` stayed set — a row saying
  /// both that the file arrived and that it did not, which the settings page
  /// then read as "Delivered 06:12" beside a failed destination.
  ///
  /// The caller is told, not obeyed: the returned entry still reads
  /// `delivered`, so a pass counts it as already delivered rather than failed.
  Future<DeliveryJournalEntry> _recordOutcome({
    required int targetId,
    required int jobId,
    required String filePath,
    required DeliveryAttemptState state,
    required String error,
    DateTime? now,
  }) async {
    await _require(targetId, jobId, filePath);
    final at = toEpochSeconds(now ?? DateTime.now());
    await (update(deliveryJournal)..where(
          (e) =>
              _isEntry(e, targetId, jobId, filePath) &
              e.state.equals(DeliveryAttemptState.delivered.wire).not(),
        ))
        .write(
          DeliveryJournalCompanion(
            state: Value(state.wire),
            lastError: Value(error),
            updatedAt: Value(at),
          ),
        );
    return _require(targetId, jobId, filePath);
  }

  Future<DeliveryJournalEntry> _require(
    int targetId,
    int jobId,
    String filePath,
  ) async {
    final entry = await getEntry(
      targetId: targetId,
      jobId: jobId,
      filePath: filePath,
    );
    if (entry == null) {
      throw DeliveryJournalMissingException(targetId, jobId, filePath);
    }
    return entry;
  }

  /// The upsert on the `(target_id, job_id, file_path)` identity that leaves a
  /// `delivered` row exactly as it is.
  DoUpdate<DeliveryJournal, DeliveryJournalRow> _unlessDelivered(
    Insertable<DeliveryJournalRow> Function(
      DeliveryJournal old,
      DeliveryJournal excluded,
    )
    update,
  ) {
    return DoUpdate.withExcluded(
      update,
      target: [
        deliveryJournal.targetId,
        deliveryJournal.jobId,
        deliveryJournal.filePath,
      ],
      where: (old, excluded) =>
          old.state.equals(DeliveryAttemptState.delivered.wire).not(),
    );
  }

  /// The attempt's size when it states one, else the size already recorded.
  static Expression<int> _knownSize(
    DeliveryJournal old,
    DeliveryJournal excluded,
  ) {
    return CaseWhenExpression(
      cases: [
        CaseWhen(excluded.bytes.isBiggerThanValue(0), then: excluded.bytes),
      ],
      orElse: old.bytes,
    );
  }

  static Expression<bool> _isEntry(
    DeliveryJournal e,
    int targetId,
    int jobId,
    String filePath,
  ) =>
      e.targetId.equals(targetId) &
      e.jobId.equals(jobId) &
      e.filePath.equals(filePath);

  Future<List<DeliveryJournalEntry>> _list(
    Expression<bool> Function(DeliveryJournal e) filter,
    List<OrderingTerm Function(DeliveryJournal e)> order,
  ) async {
    final rows =
        await (select(deliveryJournal)
              ..where(filter)
              ..orderBy(order))
            .get();
    return rows.map(_map).toList();
  }

  DeliveryJournalEntry _map(DeliveryJournalRow row) {
    final deliveredAt = row.deliveredAt;
    return DeliveryJournalEntry(
      id: row.id,
      targetId: row.targetId,
      jobId: row.jobId,
      filePath: row.filePath,
      bytes: row.bytes,
      checksum: row.checksum,
      state: DeliveryAttemptState.fromWire(row.state),
      attempts: row.attempts,
      lastError: row.lastError,
      createdAt: fromEpochSeconds(row.createdAt),
      updatedAt: fromEpochSeconds(row.updatedAt),
      deliveredAt: deliveredAt == null ? null : fromEpochSeconds(deliveredAt),
    );
  }
}

final deliveryJournalDaoProvider = Provider<DeliveryJournalDao>((ref) {
  return DeliveryJournalDao(ref.watch(databaseProvider));
});

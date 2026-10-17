import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/database_provider.dart';
import '../database.dart';
import '../tables/constellation_contributions.dart';
import '../tables/sky_atlas_tables.dart' show skyAtlasHealpixOrder;

part 'constellation_contributions_dao.g.dart';

/// Data access for [ConstellationContributions] (Pillar C — "Constellation").
///
/// One receipt row per `(hubKey, tileId, healpixOrder)`. The DAO exposes three
/// concerns over the same row so the federation stays idempotent and honest:
///
///   * CONTRIBUTION high-water — [getContribution] / [upsertContribution]: the
///     export anchor + remote receipt id that make repeat-contribute ship a
///     true delta instead of the whole accumulator from epoch.
///   * PULL high-water — [getPulledHighWater] / [upsertPulledHighWater]: the
///     last community depth pulled, so a re-pull with no new community frames is
///     a cheap no-op instead of re-folding the whole community stack.
///   * JOIN rehydration — [getJoined] / [upsertJoined]: the joined-target state
///     a remote companion (or a relaunched host) re-renders without a live hub.
///
/// All writers funnel through [_upsert], which keys on the unique
/// `(hubKey, tileId, healpixOrder)` index and only overwrites the fields a given
/// concern owns — so a pull does not clobber a contribution receipt and vice
/// versa.
@DriftAccessor(tables: [ConstellationContributions])
class ConstellationContributionsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$ConstellationContributionsDaoMixin {
  ConstellationContributionsDao(super.db);

  /// The receipt for [tileId] at [hubKey], or null when none exists yet.
  Future<ConstellationContributionRow?> getContribution(
    String hubKey,
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
  }) {
    return _byKey(hubKey, tileId, healpixOrder).getSingleOrNull();
  }

  /// The pulled-tile high-water for [tileId] at [hubKey] (same row as the
  /// contribution receipt; null when the tile was never pulled or has no row).
  Future<ConstellationContributionRow?> getPulledHighWater(
    String hubKey,
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
  }) {
    return _byKey(hubKey, tileId, healpixOrder).getSingleOrNull();
  }

  /// The joined-target rehydration row for [tileId] at [hubKey].
  Future<ConstellationContributionRow?> getJoined(
    String hubKey,
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
  }) {
    return _byKey(hubKey, tileId, healpixOrder).getSingleOrNull();
  }

  /// Every receipt at [hubKey] (used to rehydrate the federation view for a hub
  /// without a live round-trip).
  Future<List<ConstellationContributionRow>> getAllForHub(String hubKey) {
    return (select(
      constellationContributions,
    )..where((c) => c.hubKey.equals(hubKey))).get();
  }

  /// The tiles this device has contributed to [hubKey] — i.e. rows carrying a
  /// remote [ConstellationContributions.contributionId] receipt. These are the
  /// exact units the privacy "Retract" action can subtract back off the hub
  /// (newest contribution first). Rows with a null id (pull-only / join-only)
  /// are excluded: there is nothing to retract.
  Future<List<ConstellationContributionRow>> getContributedTilesForHub(
    String hubKey,
  ) async {
    final rows = await getAllForHub(hubKey);
    final contributed = rows
        .where((r) => r.contributionId != null && r.contributionId!.isNotEmpty)
        .toList();
    contributed.sort((a, b) {
      final at = a.lastContributedAt ?? a.updatedAt;
      final bt = b.lastContributedAt ?? b.updatedAt;
      return bt.compareTo(at);
    });
    return contributed;
  }

  /// Update-or-insert the CONTRIBUTION high-water after a successful push.
  ///
  /// [lastContributedAt]/[lastContributedLabel] become the anchor for the next
  /// `exportDelta(since:)`; [contributionId] is the remote receipt id (unblocks
  /// Retract); [contributedFrames]/[contributedIntegrationSeconds] are the new
  /// cumulative own-light tallies. Pull/join fields on the row are untouched.
  Future<void> upsertContribution(
    String hubKey,
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
    DateTime? lastContributedAt,
    String? lastContributedLabel,
    String? contributionId,
    int? contributedFrames,
    double? contributedIntegrationSeconds,
    String? sessionId,
  }) {
    return _upsert(
      hubKey,
      tileId,
      healpixOrder,
      ConstellationContributionsCompanion(
        lastContributedAt: Value(lastContributedAt),
        lastContributedLabel: Value(lastContributedLabel),
        contributionId: Value(contributionId),
        sessionId: sessionId == null ? const Value.absent() : Value(sessionId),
        contributedFrames: contributedFrames == null
            ? const Value.absent()
            : Value(contributedFrames),
        contributedIntegrationSeconds: contributedIntegrationSeconds == null
            ? const Value.absent()
            : Value(contributedIntegrationSeconds),
      ),
    );
  }

  /// Update-or-insert the PULL high-water after a successful pull. Contribution/
  /// join fields on the row are untouched.
  Future<void> upsertPulledHighWater(
    String hubKey,
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
    required int lastPulledFrames,
    required double lastPulledIntegrationSeconds,
    DateTime? lastPulledAt,
  }) {
    return _upsert(
      hubKey,
      tileId,
      healpixOrder,
      ConstellationContributionsCompanion(
        lastPulledFrames: Value(lastPulledFrames),
        lastPulledIntegrationSeconds: Value(lastPulledIntegrationSeconds),
        lastPulledAt: Value(lastPulledAt ?? DateTime.now()),
      ),
    );
  }

  /// Update-or-insert the JOIN rehydration row. Contribution/pull fields on the
  /// row are untouched.
  Future<void> upsertJoined(
    String hubKey,
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
    required bool joined,
    String? targetName,
    double? targetRaDeg,
    double? targetDecDeg,
  }) {
    return _upsert(
      hubKey,
      tileId,
      healpixOrder,
      ConstellationContributionsCompanion(
        joined: Value(joined),
        targetName: Value(targetName),
        targetRaDeg: Value(targetRaDeg),
        targetDecDeg: Value(targetDecDeg),
      ),
    );
  }

  /// Delete the receipt for [tileId] at [hubKey] (e.g. after a full retract).
  Future<int> deleteContribution(
    String hubKey,
    int tileId, {
    int healpixOrder = skyAtlasHealpixOrder,
  }) {
    return (delete(constellationContributions)..where(
          (c) =>
              c.hubKey.equals(hubKey) &
              c.tileId.equals(tileId) &
              c.healpixOrder.equals(healpixOrder),
        ))
        .go();
  }

  SimpleSelectStatement<
    $ConstellationContributionsTable,
    ConstellationContributionRow
  >
  _byKey(String hubKey, int tileId, int healpixOrder) {
    return select(constellationContributions)
      ..where(
        (c) =>
            c.hubKey.equals(hubKey) &
            c.tileId.equals(tileId) &
            c.healpixOrder.equals(healpixOrder),
      )
      ..limit(1);
  }

  /// Keyed update-or-insert that touches only the fields present in [patch],
  /// always refreshing [ConstellationContributions.updatedAt].
  Future<void> _upsert(
    String hubKey,
    int tileId,
    int healpixOrder,
    ConstellationContributionsCompanion patch,
  ) {
    return transaction(() async {
      final existing = await _byKey(
        hubKey,
        tileId,
        healpixOrder,
      ).getSingleOrNull();
      final stamped = patch.copyWith(updatedAt: Value(DateTime.now()));
      if (existing != null) {
        await (update(
          constellationContributions,
        )..where((c) => c.id.equals(existing.id))).write(stamped);
        return;
      }
      await into(constellationContributions).insert(
        stamped.copyWith(
          hubKey: Value(hubKey),
          tileId: Value(tileId),
          healpixOrder: Value(healpixOrder),
        ),
      );
    });
  }
}

/// Riverpod provider for [ConstellationContributionsDao].
final constellationContributionsDaoProvider =
    Provider<ConstellationContributionsDao>((ref) {
      return ConstellationContributionsDao(ref.watch(databaseProvider));
    });

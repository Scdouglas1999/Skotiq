import 'package:uuid/uuid.dart';

import '../auth/account_service.dart';
import '../db/hub_database.dart';

/// Attribution materialization: per-account identities become credited
/// attribution for a finished collaborative artifact.
///
/// Where `tile_index.contributors` is only a COUNT, this produces the ordered
/// per-contributor credit list a finished co-add / mosaic / co-imaging session
/// carries: one row per `(artifactType, artifactRef, accountId)` with the
/// frames + integration that account added and the license it shared under.
/// [recordAccepted] is additive and idempotent (UNIQUE upsert), so re-accepting
/// folds in; [recompute] subtracts on retraction and drops a credit that falls
/// to zero, so the credit list stays exactly the live set of contributors.
/// `anonymous` honours the contributor's attribution consent so [list] can
/// render "Anonymous contributor" without exposing the account.
class AttributionService {
  AttributionService(this._db, this._accounts, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final HubDatabase _db;
  final AccountService _accounts;
  final Uuid _uuid;

  /// Fold one accepted contribution's credit into the artifact's attribution.
  /// Additive: a repeat call for the same `(artifact, account)` accumulates the
  /// frames + integration. [anonymous] (from the contributor's consent) and the
  /// most-recent [license] are stamped on the credit row.
  void recordAccepted({
    required String artifactType,
    required String artifactRef,
    required String accountId,
    int frames = 0,
    double integrationSeconds = 0.0,
    String? license,
    bool anonymous = false,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.db.execute(
      'INSERT INTO artifact_attributions '
      '(id, artifact_type, artifact_ref, account_id, frames, '
      'integration_seconds, license, anonymous, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(artifact_type, artifact_ref, account_id) DO UPDATE SET '
      'frames = frames + excluded.frames, '
      'integration_seconds = integration_seconds + excluded.integration_seconds, '
      'license = excluded.license, '
      'anonymous = excluded.anonymous, '
      'updated_at = excluded.updated_at;',
      <Object?>[
        _uuid.v4(),
        artifactType,
        artifactRef,
        accountId,
        frames,
        integrationSeconds,
        license,
        anonymous ? 1 : 0,
        now,
      ],
    );
  }

  /// Subtract a retracted contribution's credit. When the running totals fall to
  /// zero or below, the credit row is removed entirely so the attribution list
  /// no longer names a contributor whose only contribution was retracted.
  void recompute({
    required String artifactType,
    required String artifactRef,
    required String accountId,
    int frames = 0,
    double integrationSeconds = 0.0,
  }) {
    final rows = _db.db.select(
      'SELECT frames, integration_seconds FROM artifact_attributions '
      'WHERE artifact_type = ? AND artifact_ref = ? AND account_id = ?;',
      <Object?>[artifactType, artifactRef, accountId],
    );
    if (rows.isEmpty) return;
    final newFrames = ((rows.first['frames'] as num?)?.toInt() ?? 0) - frames;
    final newSeconds =
        ((rows.first['integration_seconds'] as num?)?.toDouble() ?? 0.0) -
        integrationSeconds;
    if (newFrames <= 0 && newSeconds <= 0) {
      _db.db.execute(
        'DELETE FROM artifact_attributions '
        'WHERE artifact_type = ? AND artifact_ref = ? AND account_id = ?;',
        <Object?>[artifactType, artifactRef, accountId],
      );
      return;
    }
    _db.db.execute(
      'UPDATE artifact_attributions SET frames = ?, integration_seconds = ?, '
      'updated_at = ? WHERE artifact_type = ? AND artifact_ref = ? AND '
      'account_id = ?;',
      <Object?>[
        newFrames < 0 ? 0 : newFrames,
        newSeconds < 0 ? 0.0 : newSeconds,
        DateTime.now().toUtc().toIso8601String(),
        artifactType,
        artifactRef,
        accountId,
      ],
    );
  }

  /// The ordered credit list for one finished artifact (frames desc, then most
  /// recent). Each entry resolves a display name from the accounts table UNLESS
  /// the contributor withheld attribution consent, in which case it renders as
  /// `'Anonymous contributor'` and the raw account id is omitted.
  List<Map<String, Object?>> list({
    required String artifactType,
    required String artifactRef,
    int limit = 200,
  }) {
    final capped = limit < 1 ? 1 : (limit > 500 ? 500 : limit);
    final rows = _db.db.select(
      'SELECT account_id, frames, integration_seconds, license, anonymous '
      'FROM artifact_attributions WHERE artifact_type = ? AND artifact_ref = ? '
      'ORDER BY frames DESC, integration_seconds DESC, updated_at ASC '
      'LIMIT $capped;',
      <Object?>[artifactType, artifactRef],
    );
    final out = <Map<String, Object?>>[];
    for (final r in rows) {
      final accountId = r['account_id'] as String;
      final anonymous = (r['anonymous'] as num?)?.toInt() == 1;
      out.add(<String, Object?>{
        if (!anonymous) 'accountId': accountId,
        'displayName': anonymous
            ? 'Anonymous contributor'
            : (_accounts.getById(accountId)?.displayName ?? 'Unknown'),
        'anonymous': anonymous,
        'frames': (r['frames'] as num?)?.toInt() ?? 0,
        'integrationSeconds':
            (r['integration_seconds'] as num?)?.toDouble() ?? 0.0,
        if (r['license'] != null) 'license': r['license'],
      });
    }
    return out;
  }
}

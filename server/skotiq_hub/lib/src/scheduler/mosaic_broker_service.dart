import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../collab/consent_service.dart';
import '../db/hub_database.dart';

/// Per-panel claim broker + assembly coordinator for collaborative mosaics
/// (distributed panel capture).
///
/// A published [CollaborativeMosaicRow] holds its `rows × cols` panel grid as
/// claimable work items. The broker re-uses [HandoffService]'s single-holder
/// baton pattern, re-keyed from `target_id` to `(mosaic_id, panel_index)`, so
/// two rigs can never hold the same panel at once (the core anti-double-collect
/// guarantee). As with the handoff baton, [claimPanel] is check-then-write with
/// NO `await` in the critical section — under shelf's single-isolate event loop
/// the synchronous sqlite calls serialize, so the claim has no TOCTOU race.
///
/// CLAIM TTL: a panel capture spans a whole night, so the handoff's 30-min TTL
/// would free a panel a rig is still capturing and let another rig steal it
/// (double-capture — the exact thing the baton prevents). The broker uses a long
/// TTL with same-account RENEWAL (the holder re-claims on a heartbeat); a holder
/// that truly goes dark frees the panel for re-claim only after [claimTtl].
///
/// ASSEMBLY: the hub is PURE-DART with no native bridge, so it cannot run the
/// `api_stitch_mosaic` gnomonic feather-blend. It is therefore the assembly
/// COORDINATOR + blob store only: it gates on all-panels-uploaded, flips the
/// mosaic to `assembling`, the owner rig (which HAS the native bridge) pulls
/// every panel master and runs the existing `MosaicProjectService.stitchProject`
/// locally, uploads the finished mosaic back, and the hub marks it `complete`
/// and serves it to every participant.
class MosaicBrokerService {
  MosaicBrokerService(this._db, {ConsentService? consent})
    : _consent = consent,
      _random = Random.secure();

  final HubDatabase _db;

  /// Optional consent ledger. When present, [recordUpload] revokes the
  /// consent row a PREVIOUS uploader recorded for the same panel before
  /// overwriting the panel's single `consent_id`, so a panel that changes hands
  /// (force-release + re-claim + re-upload) leaves exactly one live consent row
  /// (the current one) instead of orphaning the stale one forever. Nullable so
  /// the broker unit tests that drive the service in isolation construct it
  /// unchanged.
  final ConsentService? _consent;
  final Random _random;
  final Uuid _uuid = const Uuid();

  /// How long a panel claim stays valid without renewal. Long (a panel capture
  /// is a multi-hour night), and renewed by the holder on a heartbeat. A holder
  /// that goes dark (clouds, crash) frees the panel for the next rig only after
  /// this elapses.
  static const Duration claimTtl = Duration(hours: 12);

  // --- Publish ---------------------------------------------------------------

  /// Publish a mosaic and its panel grid in one transaction. [panels] carries
  /// one entry per `rows × cols` panel (0-based row-major index + the panel's
  /// sky centre). Returns the new mosaic id.
  String publish({
    required String ownerAccountId,
    required String name,
    required int rows,
    required int cols,
    required double centerRaDeg,
    required double centerDecDeg,
    required List<MosaicPanelSpec> panels,
    double overlapPct = 15.0,
    double positionAngleDeg = 0.0,
  }) {
    final mosaicId = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    _db.db.execute('BEGIN;');
    try {
      _db.db.execute(
        'INSERT INTO collaborative_mosaics '
        '(id, owner_account_id, name, rows, cols, overlap_pct, '
        'position_angle_deg, center_ra_deg, center_dec_deg, status, '
        'created_at, updated_at) '
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?);",
        <Object?>[
          mosaicId,
          ownerAccountId,
          name,
          rows,
          cols,
          overlapPct,
          positionAngleDeg,
          centerRaDeg,
          centerDecDeg,
          now,
          now,
        ],
      );
      for (final panel in panels) {
        _db.db.execute(
          'INSERT INTO collaborative_mosaic_panels '
          '(id, mosaic_id, panel_index, center_ra_deg, center_dec_deg, '
          "status, updated_at) VALUES (?, ?, ?, ?, ?, 'pending', ?);",
          <Object?>[
            _uuid.v4(),
            mosaicId,
            panel.panelIndex,
            panel.centerRaDeg,
            panel.centerDecDeg,
            now,
          ],
        );
      }
      _db.db.execute('COMMIT;');
    } catch (_) {
      _db.db.execute('ROLLBACK;');
      rethrow;
    }
    return mosaicId;
  }

  /// One published mosaic by id, or null.
  CollaborativeMosaicRow? getMosaic(String mosaicId) {
    final rows = _db.db.select(
      'SELECT * FROM collaborative_mosaics WHERE id = ?;',
      <Object?>[mosaicId],
    );
    if (rows.isEmpty) return null;
    return CollaborativeMosaicRow._fromRow(rows.first);
  }

  /// Open/claimable mosaics (status != 'complete'), newest first.
  List<CollaborativeMosaicRow> listMosaics({int limit = 100}) {
    final capped = limit < 1 ? 1 : (limit > 500 ? 500 : limit);
    final rows = _db.db.select(
      'SELECT * FROM collaborative_mosaics ORDER BY created_at DESC LIMIT $capped;',
    );
    return rows.map(CollaborativeMosaicRow._fromRow).toList(growable: false);
  }

  /// Every panel of a mosaic, ordered by `panel_index`.
  List<CollaborativeMosaicPanelRow> panelStates(String mosaicId) {
    final rows = _db.db.select(
      'SELECT * FROM collaborative_mosaic_panels WHERE mosaic_id = ? '
      'ORDER BY panel_index ASC;',
      <Object?>[mosaicId],
    );
    return rows
        .map(CollaborativeMosaicPanelRow._fromRow)
        .toList(growable: false);
  }

  // --- Claim baton -----------------------------------------------------------

  /// Claim `(mosaicId, panelIndex)` for [accountId]. Succeeds (and renews) when
  /// the panel is free, expired, or already held by the SAME account; returns
  /// null when another account holds a live claim or the panel is already
  /// uploaded. Throws [MosaicNotFound] / [MosaicPanelNotFound] for an unknown
  /// mosaic/panel so the handler can answer 404 vs 409.
  ///
  /// CRITICAL: no `await` between the state read and the upsert — the
  /// synchronous sqlite path serializes under shelf's single isolate, keeping
  /// the claim atomic (no TOCTOU). Mirrors [HandoffService.claim].
  MosaicPanelClaim? claimPanel({
    required String mosaicId,
    required int panelIndex,
    required String accountId,
    String? rigId,
  }) {
    if (getMosaic(mosaicId) == null) throw MosaicNotFound(mosaicId);
    _expireStale(mosaicId, panelIndex);
    final row = _panelRow(mosaicId, panelIndex);
    if (row == null) throw MosaicPanelNotFound(mosaicId, panelIndex);
    final status = row['status'] as String? ?? 'pending';
    final holder = row['assigned_account_id'] as String?;
    // An uploaded panel is done — never re-claimable.
    if (status == 'uploaded') return null;
    // Held by a different account with a live (non-expired) claim.
    if (status == 'claimed' && holder != null && holder != accountId) {
      return null;
    }
    final token = _generateToken();
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(claimTtl);
    _db.db.execute(
      'UPDATE collaborative_mosaic_panels SET '
      "status = 'claimed', assigned_account_id = ?, assigned_rig_id = ?, "
      'claim_token = ?, claim_expires_at = ?, updated_at = ? '
      'WHERE mosaic_id = ? AND panel_index = ?;',
      <Object?>[
        accountId,
        // Preserve a prior rig id on a same-account renewal that omits it.
        (rigId == null || rigId.isEmpty)
            ? row['assigned_rig_id'] as String?
            : rigId,
        token,
        expiresAt.toIso8601String(),
        now.toIso8601String(),
        mosaicId,
        panelIndex,
      ],
    );
    return MosaicPanelClaim(
      mosaicId: mosaicId,
      panelIndex: panelIndex,
      claimToken: token,
      expiresAt: expiresAt,
    );
  }

  /// Release `(mosaicId, panelIndex)` if held by [accountId]. Returns true when
  /// a live claim was released. An already-uploaded panel is never released.
  bool releasePanel({
    required String mosaicId,
    required int panelIndex,
    required String accountId,
  }) {
    _expireStale(mosaicId, panelIndex);
    final row = _panelRow(mosaicId, panelIndex);
    if (row == null) return false;
    if ((row['status'] as String?) != 'claimed') return false;
    if ((row['assigned_account_id'] as String?) != accountId) return false;
    _db.db.execute(
      'UPDATE collaborative_mosaic_panels SET '
      "status = 'pending', assigned_account_id = NULL, claim_token = NULL, "
      'claim_expires_at = NULL, updated_at = ? '
      'WHERE mosaic_id = ? AND panel_index = ?;',
      <Object?>[DateTime.now().toUtc().toIso8601String(), mosaicId, panelIndex],
    );
    return true;
  }

  /// Owner/admin force-release of a panel — the recovery path the per-account
  /// [releasePanel] cannot provide. Authorised ONLY for the mosaic owner (when
  /// [accountId] == `owner_account_id`) or an admin ([isAdmin]); returns false
  /// for anyone else, an unknown mosaic/panel, or a panel that is already
  /// `pending` (nothing to evict).
  ///
  /// Resets the panel to `pending`, clears the claim AND any uploaded master
  /// (path + id), so a squatting claim that blocks a slot indefinitely OR a
  /// bogus/garbage upload that poisoned the slot can be re-opened for a fresh
  /// rig. Re-opening an already-`uploaded` panel of an `assembling` mosaic also
  /// reverts the mosaic to `open`, re-arming the all-panels-uploaded gate so the
  /// owner cannot then publish a stitch that included the evicted garbage.
  bool forceReleasePanel({
    required String mosaicId,
    required int panelIndex,
    required String accountId,
    bool isAdmin = false,
  }) {
    final mosaic = getMosaic(mosaicId);
    if (mosaic == null) return false;
    if (!isAdmin && mosaic.ownerAccountId != accountId) return false;
    final row = _panelRow(mosaicId, panelIndex);
    if (row == null) return false;
    final status = row['status'] as String?;
    // Only a claimed or uploaded panel can be evicted; a pending slot is free.
    if (status != 'claimed' && status != 'uploaded') return false;
    final now = DateTime.now().toUtc().toIso8601String();
    _db.db.execute(
      'UPDATE collaborative_mosaic_panels SET '
      "status = 'pending', assigned_account_id = NULL, assigned_rig_id = NULL, "
      'claim_token = NULL, claim_expires_at = NULL, uploaded_master_id = NULL, '
      'uploaded_master_path = NULL, updated_at = ? '
      'WHERE mosaic_id = ? AND panel_index = ?;',
      <Object?>[now, mosaicId, panelIndex],
    );
    // Re-opening a slot of an assembling mosaic re-arms the partial-set gate so
    // the owner cannot publish an output built from the now-removed panel.
    if (mosaic.status == 'assembling') {
      _db.db.execute(
        "UPDATE collaborative_mosaics SET status = 'open', updated_at = ? "
        "WHERE id = ? AND status = 'assembling';",
        <Object?>[now, mosaicId],
      );
    }
    return true;
  }

  /// Whether [accountId] (or a matching [claimToken]) currently holds a live
  /// claim on `(mosaicId, panelIndex)`. The upload gate — only the claim holder
  /// may upload that panel's master.
  bool holdsClaim({
    required String mosaicId,
    required int panelIndex,
    required String accountId,
    String? claimToken,
  }) {
    _expireStale(mosaicId, panelIndex);
    final row = _panelRow(mosaicId, panelIndex);
    if (row == null) return false;
    if ((row['status'] as String?) != 'claimed') return false;
    final holder = row['assigned_account_id'] as String?;
    if (holder == accountId) return true;
    final token = row['claim_token'] as String?;
    return claimToken != null && token != null && claimToken == token;
  }

  // --- Upload / assembly -----------------------------------------------------

  /// Record an uploaded panel master: flip the panel to `uploaded`, persist the
  /// stored [path] + generated [masterId], and stamp the authoritative
  /// [accountId] / [rigId] provenance. The [consentId] / [license] /
  /// [attributionConsent] that gated the upload are persisted onto the panel so
  /// the finalize attribution can honour the named-vs-anonymous choice +
  /// license, and a force-release can revoke the matching consent.
  ///
  /// CLAIM-GUARDED / SELF-HEALING: the handler resolves consent and reads the
  /// (potentially large) master body BEFORE calling this, yielding the isolate
  /// for the duration of that stream. During that `await` the claim can be lost
  /// — an owner/admin `force-release` (which resets the panel to `pending` and
  /// revokes its consent) or a natural claim expiry that lets another rig
  /// re-claim + re-upload. So the write is guarded: it only lands while the
  /// panel is still `claimed` by this [accountId] (or the presented
  /// [claimToken]), mirroring [claimPanel]'s check + [CoImagingService]'s
  /// contribution guard. Any prior non-matching `consent_id` on the row is
  /// revoked before the overwrite so a re-claimer's consent is never orphaned.
  /// Returns the panel row after the update, or null when the claim was lost
  /// (0 rows updated) — the caller then deletes the just-stored bytes, revokes
  /// its up-front consent, and returns 409 rather than clobbering the new state.
  CollaborativeMosaicPanelRow? recordUpload({
    required String mosaicId,
    required int panelIndex,
    required String accountId,
    required String masterId,
    required String path,
    String? rigId,
    String? claimToken,
    String? consentId,
    String? license,
    bool attributionConsent = true,
  }) {
    final existing = _panelRow(mosaicId, panelIndex);
    if (existing == null) throw MosaicPanelNotFound(mosaicId, panelIndex);
    // The claim must still be held by this uploader for the write to land; a
    // mid-upload force-release/expiry (which flipped the panel to `pending` or
    // handed it to a re-claimer) makes the guard match 0 rows and the caller
    // self-heals. Revoke the consent this write is about to overwrite (a stale
    // re-claimer's or the panel's prior share) inside the same transaction so
    // the `(mosaic, mosaicId)` live-consent count tracks only the current share.
    final priorConsentId = existing['consent_id'] as String?;
    _db.db.execute('BEGIN;');
    try {
      if (priorConsentId != null &&
          priorConsentId.isNotEmpty &&
          priorConsentId != consentId) {
        _consent?.revoke(priorConsentId);
      }
      _db.db.execute(
        'UPDATE collaborative_mosaic_panels SET '
        "status = 'uploaded', assigned_account_id = ?, assigned_rig_id = ?, "
        'uploaded_master_id = ?, uploaded_master_path = ?, consent_id = ?, '
        'license = ?, attribution_consent = ?, updated_at = ? '
        'WHERE mosaic_id = ? AND panel_index = ? '
        "AND status = 'claimed' AND (assigned_account_id = ? OR claim_token = ?);",
        <Object?>[
          accountId,
          (rigId == null || rigId.isEmpty)
              ? existing['assigned_rig_id'] as String?
              : rigId,
          masterId,
          path,
          consentId,
          license,
          attributionConsent ? 1 : 0,
          DateTime.now().toUtc().toIso8601String(),
          mosaicId,
          panelIndex,
          accountId,
          claimToken,
        ],
      );
      final claimed = _db.db.updatedRows > 0;
      if (!claimed) {
        // Claim lost mid-upload: nothing was overwritten, so the prior-consent
        // revoke above must not stand either — roll the whole thing back.
        _db.db.execute('ROLLBACK;');
        return null;
      }
      _db.db.execute('COMMIT;');
    } catch (_) {
      _db.db.execute('ROLLBACK;');
      rethrow;
    }
    return _panelRowTyped(mosaicId, panelIndex)!;
  }

  /// The recorded consent id of an uploaded panel (the share consent the
  /// uploader granted), or null when the panel has not been uploaded under a
  /// recorded consent. Used by a force-release to revoke that consent.
  String? panelConsentId(String mosaicId, int panelIndex) {
    final row = _panelRow(mosaicId, panelIndex);
    return row?['consent_id'] as String?;
  }

  /// Whether every panel of [mosaicId] has been uploaded (the partial-set gate:
  /// assembly is refused until this is true). False when the mosaic has no
  /// panels.
  bool allPanelsUploaded(String mosaicId) {
    final total =
        (_db.db.select(
                  'SELECT COUNT(*) AS n FROM collaborative_mosaic_panels '
                  'WHERE mosaic_id = ?;',
                  <Object?>[mosaicId],
                ).first['n']
                as num)
            .toInt();
    if (total == 0) return false;
    final uploaded =
        (_db.db.select(
                  'SELECT COUNT(*) AS n FROM collaborative_mosaic_panels '
                  "WHERE mosaic_id = ? AND status = 'uploaded';",
                  <Object?>[mosaicId],
                ).first['n']
                as num)
            .toInt();
    return uploaded == total;
  }

  /// On-disk path of an uploaded panel master, or null when the panel has not
  /// been uploaded.
  String? panelMasterPath(String mosaicId, int panelIndex) {
    final row = _panelRow(mosaicId, panelIndex);
    return row?['uploaded_master_path'] as String?;
  }

  /// The account a single panel is (or was) assigned to, or null when the panel
  /// is unclaimed or unknown. Used to scope a panel-master download to the rig
  /// that produced THAT panel — a contributor may re-pull its own panel, but
  /// never a peer's raw data — without granting the cross-panel read that
  /// [isParticipant] would.
  String? panelAssignedAccount(String mosaicId, int panelIndex) {
    final row = _panelRow(mosaicId, panelIndex);
    return row?['assigned_account_id'] as String?;
  }

  /// Move a mosaic to `assembling` (all panels are in; the owner rig now pulls
  /// + stitches). No-op when it is already past `open`.
  void markAssembling(String mosaicId) {
    _db.db.execute(
      "UPDATE collaborative_mosaics SET status = 'assembling', updated_at = ? "
      "WHERE id = ? AND status = 'open';",
      <Object?>[DateTime.now().toUtc().toIso8601String(), mosaicId],
    );
  }

  /// Record the finished stitched output and mark the mosaic `complete` — only
  /// when it is currently `assembling` (i.e. every panel has uploaded). The
  /// `status = 'assembling'` guard makes a premature completion (panels still
  /// pending/claimed) or a repeat completion (overwriting an already-`complete`
  /// output) a no-op rather than a silent overwrite that drops contributors.
  /// Returns whether the output was accepted.
  bool markComplete(String mosaicId, {required String outputPath}) {
    _db.db.execute(
      "UPDATE collaborative_mosaics SET status = 'complete', "
      "output_sidecar_path = ?, updated_at = ? "
      "WHERE id = ? AND status = 'assembling';",
      <Object?>[outputPath, DateTime.now().toUtc().toIso8601String(), mosaicId],
    );
    return _db.db.updatedRows > 0;
  }

  /// Whether [accountId] is the owner of [mosaicId] or holds (or held — was
  /// assigned) one of its panels. The authorization gate for pulling a panel
  /// master or the finished output: only the owner (the assembler) + the rigs
  /// that contributed may download a mosaic's FITS bytes — an unrelated account
  /// is refused so collaborative imaging data never leaks cross-user.
  bool isParticipant(String mosaicId, String accountId) {
    final mosaic = getMosaic(mosaicId);
    if (mosaic == null) return false;
    if (mosaic.ownerAccountId == accountId) return true;
    final rows = _db.db.select(
      'SELECT 1 FROM collaborative_mosaic_panels '
      'WHERE mosaic_id = ? AND assigned_account_id = ? LIMIT 1;',
      <Object?>[mosaicId, accountId],
    );
    return rows.isNotEmpty;
  }

  /// On-disk path of the finished mosaic output, or null until `complete`.
  String? outputPathFor(String mosaicId) {
    final mosaic = getMosaic(mosaicId);
    if (mosaic == null || mosaic.status != 'complete') return null;
    return mosaic.outputPath;
  }

  // --- Internals -------------------------------------------------------------

  /// Free a claim whose TTL has elapsed (lazy, like [HandoffService]). An
  /// uploaded panel is terminal and never expired.
  void _expireStale(String mosaicId, int panelIndex) {
    final row = _panelRow(mosaicId, panelIndex);
    if (row == null) return;
    if ((row['status'] as String?) != 'claimed') return;
    final raw = row['claim_expires_at'] as String?;
    if (raw == null) return;
    final exp = DateTime.tryParse(raw);
    if (exp != null && !DateTime.now().toUtc().isBefore(exp)) {
      _db.db.execute(
        'UPDATE collaborative_mosaic_panels SET '
        "status = 'pending', assigned_account_id = NULL, claim_token = NULL, "
        'claim_expires_at = NULL, updated_at = ? '
        'WHERE mosaic_id = ? AND panel_index = ?;',
        <Object?>[
          DateTime.now().toUtc().toIso8601String(),
          mosaicId,
          panelIndex,
        ],
      );
    }
  }

  Map<String, Object?>? _panelRow(String mosaicId, int panelIndex) {
    final rows = _db.db.select(
      'SELECT * FROM collaborative_mosaic_panels '
      'WHERE mosaic_id = ? AND panel_index = ?;',
      <Object?>[mosaicId, panelIndex],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  CollaborativeMosaicPanelRow? _panelRowTyped(String mosaicId, int panelIndex) {
    final row = _panelRow(mosaicId, panelIndex);
    return row == null ? null : CollaborativeMosaicPanelRow._fromRow(row);
  }

  String _generateToken() {
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// One panel's grid index + sky centre, supplied to [MosaicBrokerService.publish].
class MosaicPanelSpec {
  const MosaicPanelSpec({
    required this.panelIndex,
    required this.centerRaDeg,
    required this.centerDecDeg,
  });

  final int panelIndex;
  final double centerRaDeg;
  final double centerDecDeg;
}

/// A successful panel claim handed to a rig (the baton + its expiry).
class MosaicPanelClaim {
  const MosaicPanelClaim({
    required this.mosaicId,
    required this.panelIndex,
    required this.claimToken,
    required this.expiresAt,
  });

  final String mosaicId;
  final int panelIndex;
  final String claimToken;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'mosaicId': mosaicId,
    'panelIndex': panelIndex,
    'claimToken': claimToken,
    'expiresAt': expiresAt.toIso8601String(),
  };
}

/// One published collaborative mosaic row. [toJson] is the wire shape the client
/// `CollabMosaic.fromJson` decodes.
class CollaborativeMosaicRow {
  const CollaborativeMosaicRow({
    required this.id,
    required this.ownerAccountId,
    required this.name,
    required this.rows,
    required this.cols,
    required this.overlapPct,
    required this.positionAngleDeg,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.status,
    required this.outputPath,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String ownerAccountId;
  final String name;
  final int rows;
  final int cols;
  final double overlapPct;
  final double positionAngleDeg;
  final double centerRaDeg;
  final double centerDecDeg;
  final String status;
  final String? outputPath;
  final String createdAt;
  final String updatedAt;

  bool get isComplete => status == 'complete';

  factory CollaborativeMosaicRow._fromRow(dynamic row) {
    return CollaborativeMosaicRow(
      id: row['id'] as String,
      ownerAccountId: row['owner_account_id'] as String,
      name: row['name'] as String,
      rows: (row['rows'] as num).toInt(),
      cols: (row['cols'] as num).toInt(),
      overlapPct: (row['overlap_pct'] as num?)?.toDouble() ?? 15.0,
      positionAngleDeg: (row['position_angle_deg'] as num?)?.toDouble() ?? 0.0,
      centerRaDeg: (row['center_ra_deg'] as num?)?.toDouble() ?? 0.0,
      centerDecDeg: (row['center_dec_deg'] as num?)?.toDouble() ?? 0.0,
      status: row['status'] as String? ?? 'open',
      outputPath: row['output_sidecar_path'] as String?,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );
  }

  /// Wire shape for the client `CollabMosaic.fromJson`.
  ///
  /// PRIVACY: the internal `owner_account_id` is an enumerable hub identifier,
  /// not a display name. It is emitted ONLY when [includeAccountId] is true
  /// (the caller is the owner, a participant, or an admin); a plain read-scoped
  /// non-participant gets coarse state plus a server-resolved [ownerDisplayName]
  /// for attribution, never the raw account id (no cross-user enumeration
  /// oracle). [ownerDisplayName] is resolved hub-side from the accounts table.
  Map<String, Object?> toJson({
    bool includeAccountId = false,
    String? ownerDisplayName,
  }) => <String, Object?>{
    'mosaicId': id,
    if (includeAccountId) 'ownerAccountId': ownerAccountId,
    if (ownerDisplayName != null) 'ownerDisplayName': ownerDisplayName,
    'name': name,
    'rows': rows,
    'cols': cols,
    'overlapPct': overlapPct,
    'positionAngleDeg': positionAngleDeg,
    'centerRaDeg': centerRaDeg,
    'centerDecDeg': centerDecDeg,
    'status': status,
    'outputPresent': isComplete,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

/// One hub-side mosaic panel row (a claimable work item). NOTE: this table
/// SHARES its name with the CLIENT `mosaic_panels` table but lives in a separate
/// sqlite DB — intentional. `assignedAccountId` is a HUB account id (string),
/// unrelated to the client's per-panel capture target id.
class CollaborativeMosaicPanelRow {
  const CollaborativeMosaicPanelRow({
    required this.mosaicId,
    required this.panelIndex,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.assignedAccountId,
    required this.assignedRigId,
    required this.status,
    required this.uploadedMasterId,
    required this.claimExpiresAt,
    required this.license,
    required this.attributionConsent,
  });

  final String mosaicId;
  final int panelIndex;
  final double centerRaDeg;
  final double centerDecDeg;
  final String? assignedAccountId;
  final String? assignedRigId;
  final String status;
  final String? uploadedMasterId;
  final String? claimExpiresAt;

  /// The share license + named-vs-anonymous choice recorded at panel upload.
  /// `attribution_consent` defaults to credited (true) for a row written before
  /// the column existed; the finalize attribution renders the contributor
  /// anonymously when it is false.
  final String? license;
  final bool attributionConsent;

  bool get isUploaded => status == 'uploaded';

  factory CollaborativeMosaicPanelRow._fromRow(dynamic row) {
    return CollaborativeMosaicPanelRow(
      mosaicId: row['mosaic_id'] as String,
      panelIndex: (row['panel_index'] as num).toInt(),
      centerRaDeg: (row['center_ra_deg'] as num?)?.toDouble() ?? 0.0,
      centerDecDeg: (row['center_dec_deg'] as num?)?.toDouble() ?? 0.0,
      assignedAccountId: row['assigned_account_id'] as String?,
      assignedRigId: row['assigned_rig_id'] as String?,
      status: row['status'] as String? ?? 'pending',
      uploadedMasterId: row['uploaded_master_id'] as String?,
      claimExpiresAt: row['claim_expires_at'] as String?,
      license: row['license'] as String?,
      attributionConsent: (row['attribution_consent'] as num?)?.toInt() != 0,
    );
  }

  /// Wire shape for the client `CollabMosaicPanel.fromJson`.
  ///
  /// PRIVACY: like the mosaic row, the per-panel `assigned_account_id` (and the
  /// `assigned_rig_id`, which maps a rig to a panel to a sky target) is emitted
  /// ONLY when [includeAccountId] is true (owner / participant / admin). A plain
  /// read-scoped non-participant gets coarse panel state plus a server-resolved
  /// [assignedDisplayName] for attribution — never the internal account id that
  /// would let an arbitrary read token map account -> panel -> contributor.
  Map<String, Object?> toJson({
    bool includeAccountId = false,
    String? assignedDisplayName,
  }) => <String, Object?>{
    'panelIndex': panelIndex,
    'centerRaDeg': centerRaDeg,
    'centerDecDeg': centerDecDeg,
    if (includeAccountId && assignedAccountId != null)
      'assignedAccountId': assignedAccountId,
    if (includeAccountId && assignedRigId != null)
      'assignedRigId': assignedRigId,
    if (assignedDisplayName != null) 'assignedDisplayName': assignedDisplayName,
    'status': status,
    'uploaded': isUploaded,
    if (uploadedMasterId != null) 'uploadedMasterId': uploadedMasterId,
    if (claimExpiresAt != null) 'claimExpiresAt': claimExpiresAt,
  };
}

/// No published mosaic with the given id exists.
class MosaicNotFound implements Exception {
  MosaicNotFound(this.mosaicId);
  final String mosaicId;
  @override
  String toString() => 'MosaicNotFound($mosaicId)';
}

/// No panel with the given index exists on the mosaic.
class MosaicPanelNotFound implements Exception {
  MosaicPanelNotFound(this.mosaicId, this.panelIndex);
  final String mosaicId;
  final int panelIndex;
  @override
  String toString() => 'MosaicPanelNotFound($mosaicId, $panelIndex)';
}

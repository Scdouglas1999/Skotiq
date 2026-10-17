import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../db/hub_database.dart';
import 'subframe_store.dart';

/// Ledger + storage orchestration for raw FITS subframes (the opt-in
/// `acceptsRawSubs` path).
///
/// Mirrors [FusionService] for additive sums, but with one crucial difference:
/// a raw subframe is **not** fused into anything. Each frame is stored as its
/// own immutable FITS via [SubframeStore] and recorded as its own row in
/// `raw_subframe_contributions`, so a retraction is an exact file-delete (raw
/// pixels cannot be subtracted from a co-add the way sums can). This is why the
/// hub gates the whole path behind `acceptsRawSubs` and the client surfaces a
/// stronger consent: a raw frame, once shared, is re-derivable by anyone with
/// read access and cannot be cleanly un-shared.
class SubframeService {
  SubframeService({required HubDatabase db, required SubframeStore store})
    : _db = db,
      _store = store;

  final HubDatabase _db;
  final SubframeStore _store;
  final Uuid _uuid = const Uuid();

  /// Store one raw FITS subframe for [accountId] under [tileId]/[order] and
  /// record its ledger row. Returns the receipt the handler echoes back.
  SubframeReceipt store({
    required String accountId,
    required int tileId,
    required int order,
    required Uint8List bytes,
    int? capturedImageId,
    String? instrument,
    double? exposureSeconds,
    String? license,
    String? consentId,
  }) {
    final contributionId = _uuid.v4();
    final path = _store.save(
      accountId: accountId,
      tileId: tileId,
      order: order,
      contributionId: contributionId,
      bytes: bytes,
    );
    _db.db.execute(
      'INSERT INTO raw_subframe_contributions '
      '(contribution_id, account_id, tile_id, healpix_order, '
      'captured_image_id, path, bytes, instrument, exposure_seconds, '
      'license, consent_id, received_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        contributionId,
        accountId,
        tileId,
        order,
        capturedImageId,
        path,
        bytes.length,
        instrument,
        exposureSeconds,
        license,
        consentId,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    return SubframeReceipt(
      contributionId: contributionId,
      accepted: true,
      storedBytes: bytes.length,
    );
  }

  /// Read the persisted ledger row for [contributionId], or null if none.
  ///
  /// Read-only. Lets callers (and the regression suite) confirm the exact
  /// provenance recorded for a stored subframe — the tile/order it landed on,
  /// the originating capture, instrument, exposure, and byte count — rather
  /// than only that the receipt round-tripped.
  SubframeLedgerEntry? ledgerRow(String contributionId) {
    final rows = _db.db.select(
      'SELECT contribution_id, account_id, tile_id, healpix_order, '
      'captured_image_id, path, bytes, instrument, exposure_seconds, '
      'received_at FROM raw_subframe_contributions WHERE contribution_id = ?;',
      <Object?>[contributionId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return SubframeLedgerEntry(
      contributionId: r['contribution_id'] as String,
      accountId: r['account_id'] as String,
      tileId: r['tile_id'] as int,
      healpixOrder: r['healpix_order'] as int,
      capturedImageId: r['captured_image_id'] as int?,
      path: r['path'] as String,
      bytes: r['bytes'] as int,
      instrument: r['instrument'] as String?,
      exposureSeconds: (r['exposure_seconds'] as num?)?.toDouble(),
      receivedAt: r['received_at'] as String,
    );
  }

  /// Delete a stored subframe (file + ledger row). [requesterId] non-null scopes
  /// the delete to the owner; null (admin) may delete anyone's. Throws
  /// [SubframeNotFound] / [SubframeForbidden] for a clean handler mapping.
  /// Returns the deleted row's `consent_id` (or null) so the caller can revoke
  /// the matching consent record — a deleted raw frame is no longer consented.
  String? delete(String contributionId, {String? requesterId}) {
    final rows = _db.db.select(
      'SELECT account_id, path, consent_id FROM raw_subframe_contributions '
      'WHERE contribution_id = ?;',
      <Object?>[contributionId],
    );
    if (rows.isEmpty) throw SubframeNotFound(contributionId);
    final accountId = rows.first['account_id'] as String;
    if (requesterId != null && requesterId != accountId) {
      throw SubframeForbidden(contributionId);
    }
    final path = rows.first['path'] as String;
    final consentId = rows.first['consent_id'] as String?;
    _store.delete(path);
    _db.db.execute(
      'DELETE FROM raw_subframe_contributions WHERE contribution_id = ?;',
      <Object?>[contributionId],
    );
    return consentId;
  }
}

/// The receipt for a stored raw subframe.
class SubframeReceipt {
  const SubframeReceipt({
    required this.contributionId,
    required this.accepted,
    required this.storedBytes,
  });

  final String contributionId;
  final bool accepted;
  final int storedBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'contributionId': contributionId,
    'accepted': accepted,
    'storedBytes': storedBytes,
  };
}

/// A persisted raw-subframe ledger row (`raw_subframe_contributions`).
class SubframeLedgerEntry {
  const SubframeLedgerEntry({
    required this.contributionId,
    required this.accountId,
    required this.tileId,
    required this.healpixOrder,
    required this.capturedImageId,
    required this.path,
    required this.bytes,
    required this.instrument,
    required this.exposureSeconds,
    required this.receivedAt,
  });

  final String contributionId;
  final String accountId;
  final int tileId;
  final int healpixOrder;
  final int? capturedImageId;
  final String path;
  final int bytes;
  final String? instrument;
  final double? exposureSeconds;
  final String receivedAt;
}

/// No raw subframe with the given id exists.
class SubframeNotFound implements Exception {
  const SubframeNotFound(this.contributionId);
  final String contributionId;
}

/// The requester does not own the raw subframe they tried to delete.
class SubframeForbidden implements Exception {
  const SubframeForbidden(this.contributionId);
  final String contributionId;
}

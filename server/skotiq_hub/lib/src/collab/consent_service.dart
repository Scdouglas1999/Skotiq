import 'package:uuid/uuid.dart';

import '../db/hub_database.dart';

/// Consent + license ledger: every publish / contribute records a consent row
/// + license, and a retraction marks it revoked.
///
/// A consent record is the durable proof that, BEFORE any bytes were stored, the
/// contributor named a license and the per-action rights (raw-subframe sharing,
/// derivatives, redistribution, public credit) under which the artifact may be
/// reused. It is the gate the share paths call: a contribution with no parseable
/// shareable license is refused before `_readBinary`, so an un-consented frame
/// is never persisted. On retraction the matching record's `revoked_at` is
/// stamped so a removed contribution can prove it is no longer consented.
class ConsentService {
  ConsentService(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final HubDatabase _db;
  final Uuid _uuid;

  /// The license wire names the hub recognizes (mirrors the
  /// `consent_records.license` CHECK + the client `ContributionLicense`).
  static const Set<String> knownLicenses = {
    'private',
    'cc0',
    'cc-by',
    'cc-by-sa',
    'cc-by-nc',
  };

  /// The shareable subset — a contribution into a SHARED co-add must carry one
  /// of these (never `private`, which means "do not share").
  static const Set<String> shareableLicenses = {
    'cc0',
    'cc-by',
    'cc-by-sa',
    'cc-by-nc',
  };

  /// Whether [license] is a known, shareable license wire name.
  static bool isShareable(String? license) =>
      license != null && shareableLicenses.contains(license.trim());

  /// Record a consent for one share. Returns the new consent id, which the
  /// caller persists onto the contribution ledger row so a retraction can find
  /// and revoke it. [license] MUST already be validated shareable by the caller.
  String record({
    required String accountId,
    required String artifactType,
    required String artifactRef,
    required String license,
    bool shareRawSubframes = false,
    bool allowDerivatives = false,
    bool allowRedistribution = false,
    bool attributionConsent = true,
  }) {
    final id = _uuid.v4();
    _db.db.execute(
      'INSERT INTO consent_records '
      '(id, account_id, artifact_type, artifact_ref, license, '
      'share_raw_subframes, allow_derivatives, allow_redistribution, '
      'attribution_consent, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        id,
        accountId,
        artifactType,
        artifactRef,
        license.trim(),
        shareRawSubframes ? 1 : 0,
        allowDerivatives ? 1 : 0,
        allowRedistribution ? 1 : 0,
        attributionConsent ? 1 : 0,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    return id;
  }

  /// Whether the contributor consented to public credit for [consentId] (false
  /// → render as "Anonymous contributor"). A missing record fails closed to
  /// anonymous so a stripped consent never silently credits by name.
  bool attributionConsentFor(String? consentId) {
    if (consentId == null) return false;
    final rows = _db.db.select(
      'SELECT attribution_consent FROM consent_records WHERE id = ?;',
      <Object?>[consentId],
    );
    if (rows.isEmpty) return false;
    return (rows.first['attribution_consent'] as num?)?.toInt() == 1;
  }

  /// The number of still-live (un-revoked) consent records for a shared artifact
  /// `(artifactType, artifactRef)`. Zero once every record for it has been
  /// revoked (e.g. after the artifact is retracted), so a moderation / audit
  /// surface can confirm a share is currently consented.
  int liveConsentCount(String artifactType, String artifactRef) {
    final rows = _db.db.select(
      'SELECT COUNT(*) AS n FROM consent_records '
      'WHERE artifact_type = ? AND artifact_ref = ? AND revoked_at IS NULL;',
      <Object?>[artifactType, artifactRef],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Mark [consentId]'s record revoked (retraction). No-op when the id is null
  /// or unknown. Returns whether a record was revoked.
  bool revoke(String? consentId) {
    if (consentId == null || consentId.isEmpty) return false;
    _db.db.execute(
      'UPDATE consent_records SET revoked_at = ? '
      'WHERE id = ? AND revoked_at IS NULL;',
      <Object?>[DateTime.now().toUtc().toIso8601String(), consentId],
    );
    return _db.db.updatedRows > 0;
  }

  /// Revoke every still-live consent record for a shared artifact identified by
  /// `(artifactType, artifactRef)`, used where the artifact itself is deleted
  /// and the caller holds no stored consent id to target — e.g. a retracted
  /// shared calibration master, whose id is generated inside its publish. Stamps
  /// `revoked_at` on each un-revoked matching row and returns the count revoked.
  int revokeForArtifact(String artifactType, String artifactRef) {
    _db.db.execute(
      'UPDATE consent_records SET revoked_at = ? '
      'WHERE artifact_type = ? AND artifact_ref = ? AND revoked_at IS NULL;',
      <Object?>[
        DateTime.now().toUtc().toIso8601String(),
        artifactType,
        artifactRef,
      ],
    );
    return _db.db.updatedRows;
  }
}

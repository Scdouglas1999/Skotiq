import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../auth/account_service.dart';
import '../collab/attribution_service.dart';
import '../collab/consent_service.dart';
import '../db/hub_database.dart';
import 'tile_builder.dart';
import 'tile_codec.dart';
import 'tile_quality.dart';
import 'tile_store.dart';

/// Server-side fusion: accepts a contributor's `.nst` delta, weights it by the
/// contributor's trust, robust-rejects gross outliers, and merges it into the
/// shared tile using the SAME additive co-add the keystone uses
/// (`mergeSigned`). Records the contribution for retraction + audit and updates
/// the tile index + the contributor's reputation.
class FusionService {
  FusionService({
    required HubDatabase db,
    required TileStore store,
    required AccountService accounts,
    TileQualityGate? qualityGate,
    AttributionService? attribution,
    ConsentService? consent,
    this.expectedTilePixels = 1024,
    this.expectedHealpixOrder = 9,
    this.maxFramesPerContribution = 100000,
    this.maxIntegrationSecondsPerContribution = 100000000.0,
  }) : _db = db,
       _store = store,
       _accounts = accounts,
       _qualityGate = qualityGate ?? TileQualityGate(),
       _attribution = attribution,
       _consent = consent;

  final HubDatabase _db;
  final TileStore _store;
  final AccountService _accounts;
  final TileQualityGate _qualityGate;

  /// Optional consent + attribution collaborators. When present, an accepted
  /// contribution folds a per-account credit into the tile's
  /// [AttributionService] and a retraction recomputes it + revokes the matching
  /// [ConsentService] record. Nullable so the unit tests that drive fusion in
  /// isolation construct it unchanged.
  final AttributionService? _attribution;
  final ConsentService? _consent;
  final Uuid _uuid = const Uuid();

  /// The attribution artifact ref for a fused tile: `tileId:order`.
  static String tileArtifactRef(int tileId, int order) => '$tileId:$order';

  /// The hub's configured tile raster edge. A contributor's declared
  /// width/height must match this exactly before its untrusted header is
  /// allowed to seed a never-seen tile's geometry.
  final int expectedTilePixels;

  /// The hub's configured HEALPix order. A delta declaring a different order is
  /// rejected (it would address a different sky grid).
  final int expectedHealpixOrder;

  /// Per-contribution ceiling on self-reported frames. A single upload claiming
  /// more than this is rejected as implausible rather than silently trusted.
  final int maxFramesPerContribution;

  /// Per-contribution ceiling on self-reported integration seconds.
  final double maxIntegrationSecondsPerContribution;

  /// Channel counts a tile may declare: 1 (mono) or 3 (OSC/RGB). Anything else
  /// would seed a malformed tile geometry.
  static const Set<int> _channelWhitelist = <int>{1, 3};

  /// Fuse a contributor delta into the shared tile.
  ///
  /// [deltaBytes] is the contributor's serialized `.nst`. [tileId]/[order] come
  /// from the request path/query and MUST match the delta's own header (a
  /// mismatch is a 409, surfaced as a [TileCodecException]). [framesDelta] /
  /// [integrationSecondsDelta] / [medianFwhm] are the contributor's claimed
  /// stats, used for the ledger and reputation; the authoritative pixel state
  /// comes from the delta itself.
  ContributionOutcome contribute({
    required String accountId,
    required int tileId,
    required int order,
    required Uint8List deltaBytes,
    required int framesDelta,
    required double integrationSecondsDelta,
    double? medianFwhm,
    String? instrument,
    String? solver,
    String? license,
    String? consentId,
    bool anonymous = false,
  }) {
    final delta = TileAccumulator.deserialize(deltaBytes);
    if (delta.tileId != tileId) {
      throw TileCodecException(
        'geometryMismatch',
        'delta tile id ${delta.tileId} != path tile id $tileId',
      );
    }
    if (delta.order != order) {
      throw TileCodecException(
        'orderMismatch',
        'delta order ${delta.order} != query order $order',
      );
    }

    // The first contributor to a never-seen tile seeds its geometry from this
    // untrusted header. Bound it against the hub's configured grid + a channel
    // whitelist BEFORE it is allowed to seed or merge, so a malicious or buggy
    // client cannot create a 100k-wide tile (an allocation bomb) or a
    // nonsensical channel count that every later contributor then mismatches.
    if (delta.order != expectedHealpixOrder) {
      throw ContributionRejected(
        'badRequest',
        'tile order ${delta.order} != hub order $expectedHealpixOrder',
      );
    }
    if (delta.width != expectedTilePixels ||
        delta.height != expectedTilePixels) {
      throw ContributionRejected(
        'badRequest',
        'tile geometry ${delta.width}x${delta.height} != hub tile '
            '${expectedTilePixels}x$expectedTilePixels',
      );
    }
    if (!_channelWhitelist.contains(delta.channels)) {
      throw ContributionRejected(
        'badRequest',
        'channel count ${delta.channels} is not allowed (must be 1 or 3)',
      );
    }

    // Clamp the self-reported ledger params to a sane, non-negative range. These
    // come straight off the query string and are otherwise unbounded; a wildly
    // inflated value would corrupt the tile's headline integration total and a
    // contributor's reputation. Out-of-range is a client error (400), not a
    // silent clamp, so a buggy uploader learns its request was wrong.
    if (framesDelta < 0 || framesDelta > maxFramesPerContribution) {
      throw ContributionRejected(
        'badRequest',
        'framesDelta $framesDelta out of range '
            '[0, $maxFramesPerContribution]',
      );
    }
    if (!integrationSecondsDelta.isFinite ||
        integrationSecondsDelta < 0 ||
        integrationSecondsDelta > maxIntegrationSecondsPerContribution) {
      throw ContributionRejected(
        'badRequest',
        'integrationSecondsDelta $integrationSecondsDelta out of range '
            '[0, $maxIntegrationSecondsPerContribution]',
      );
    }

    final account = _accounts.getById(accountId);
    final trust = account?.trust ?? AccountService.defaultTrust;

    // Never trust provenance/contributor fields embedded in the uploaded blob: a
    // contributor controls every byte and could otherwise inflate total_frames /
    // total_integration_seconds or forge other accounts' ids into `contributors`.
    // Overwrite the delta's provenance with server-validated stats and the
    // authenticated account id BEFORE it reaches mergeSigned, and persist the
    // sanitized bytes so a later retraction subtracts exactly what was folded.
    sanitizeContributionProvenance(
      delta,
      accountId: accountId,
      framesDelta: framesDelta < 0 ? 0 : framesDelta,
      integrationSecondsDelta: integrationSecondsDelta < 0
          ? 0.0
          : integrationSecondsDelta,
    );
    final sanitizedBytes = delta.serialize();

    // Load (or seed) the fused base tile.
    final base =
        _store.load(tileId, order) ??
        TileBuilder.empty(
          tileId: tileId,
          order: order,
          channels: delta.channels,
          width: delta.width,
          height: delta.height,
        );

    // Robust outlier gate BEFORE merging: a contribution that disagrees grossly
    // with the existing stack is rejected and recorded, never folded in.
    final verdict = _qualityGate.evaluate(base, delta);
    if (!verdict.accepted) {
      final contributionId = _uuid.v4();
      _recordContribution(
        contributionId: contributionId,
        accountId: accountId,
        tileId: tileId,
        order: order,
        framesDelta: framesDelta,
        integrationSecondsDelta: integrationSecondsDelta,
        medianFwhm: medianFwhm,
        trustApplied: 0.0,
        status: 'rejected',
        deltaPath: '',
        instrument: instrument,
        solver: solver,
        license: license,
        consentId: consentId,
      );
      // The delta was rejected and never folded in, and a `rejected` row is not
      // retractable, so its consent could never otherwise be released — revoke it
      // now so the tile's live-consent count reflects only accepted shares.
      _consent?.revoke(consentId);
      _accounts.recordGrade(
        accountId: accountId,
        medianResidual: verdict.deviation,
        rejectedFrames: framesDelta,
      );
      return ContributionOutcome(
        contributionId: contributionId,
        accepted: false,
        trustApplied: 0.0,
        totalFramesAfter: base.totalFrames,
        integrationSecondsAfter: base.totalIntegrationSeconds,
        contributorsAfter: base.contributors.length,
        verdict: verdict,
      );
    }

    // Fuse: additive merge scaled by trust (the keystone's algebra).
    mergeSigned(base, delta, trust, 1.0);
    _store.save(base);

    final contributionId = _uuid.v4();
    // Persist the contributor's delta so a retraction can subtract it exactly.
    final deltaPath =
        '${_store.pathFor(tileId, order)}.contrib.$contributionId';
    _writeDelta(deltaPath, sanitizedBytes);

    _recordContribution(
      contributionId: contributionId,
      accountId: accountId,
      tileId: tileId,
      order: order,
      framesDelta: framesDelta,
      integrationSecondsDelta: integrationSecondsDelta,
      medianFwhm: medianFwhm,
      trustApplied: trust,
      status: 'accepted',
      deltaPath: deltaPath,
      instrument: instrument,
      solver: solver,
      license: license,
      consentId: consentId,
    );
    _upsertTileIndex(base);
    _accounts.recordGrade(
      accountId: accountId,
      medianResidual: medianFwhm,
      acceptedFrames: framesDelta,
    );
    // Materialize the per-account credit for this fused tile.
    _attribution?.recordAccepted(
      artifactType: 'tile',
      artifactRef: tileArtifactRef(tileId, order),
      accountId: accountId,
      frames: framesDelta,
      integrationSeconds: integrationSecondsDelta,
      license: license,
      anonymous: anonymous,
    );

    return ContributionOutcome(
      contributionId: contributionId,
      accepted: true,
      trustApplied: trust,
      totalFramesAfter: base.totalFrames,
      integrationSecondsAfter: base.totalIntegrationSeconds,
      contributorsAfter: base.contributors.length,
      verdict: verdict,
    );
  }

  /// Exactly retract a previously accepted contribution: subtract its stored
  /// delta (trust-scaled, the same trust it was folded with) from the fused
  /// tile. Linear, so the result equals never having received it. Returns the
  /// tile totals after retraction.
  RetractionOutcome retract(String contributionId, {String? requesterId}) {
    final rows = _db.db.select(
      'SELECT * FROM contributions WHERE id = ?;',
      <Object?>[contributionId],
    );
    if (rows.isEmpty) {
      throw ContributionNotFound(contributionId);
    }
    final row = rows.first;
    if (requesterId != null && row['account_id'] != requesterId) {
      throw ContributionForbidden(contributionId);
    }
    final status = row['status'] as String;
    if (status != 'accepted') {
      throw ContributionStateError(
        'contribution $contributionId is "$status", not retractable',
      );
    }
    final tileId = row['tile_id'] as int;
    final order = row['healpix_order'] as int;
    final trustApplied = (row['trust_applied'] as num).toDouble();
    final deltaPath = row['delta_path'] as String;
    final accountId = row['account_id'] as String;
    final framesDelta = (row['frames_delta'] as num?)?.toInt() ?? 0;
    final integrationSecondsDelta =
        (row['integration_seconds_delta'] as num?)?.toDouble() ?? 0.0;
    final consentId = row['consent_id'] as String?;

    final base = _store.load(tileId, order);
    if (base == null) {
      throw ContributionStateError('fused tile for $contributionId is missing');
    }
    final deltaBytes = _readDelta(deltaPath);
    final delta = TileAccumulator.deserialize(deltaBytes);
    mergeSigned(base, delta, trustApplied, -1.0);
    _store.save(base);

    _db.db.execute(
      'UPDATE contributions SET status = ? WHERE id = ?;',
      <Object?>['retracted', contributionId],
    );
    _upsertTileIndex(base);

    // A retracted contribution is no longer consented, and its credit must
    // come back out of the tile's attribution so the credit list matches the
    // live co-add exactly.
    _consent?.revoke(consentId);
    _attribution?.recompute(
      artifactType: 'tile',
      artifactRef: tileArtifactRef(tileId, order),
      accountId: accountId,
      frames: framesDelta,
      integrationSeconds: integrationSecondsDelta,
    );

    return RetractionOutcome(
      retracted: true,
      totalFramesAfter: base.totalFrames,
      integrationSecondsAfter: base.totalIntegrationSeconds,
      contributorsAfter: base.contributors.length,
    );
  }

  void _recordContribution({
    required String contributionId,
    required String accountId,
    required int tileId,
    required int order,
    required int framesDelta,
    required double integrationSecondsDelta,
    required double? medianFwhm,
    required double trustApplied,
    required String status,
    required String deltaPath,
    required String? instrument,
    required String? solver,
    String? license,
    String? consentId,
  }) {
    _db.db.execute(
      'INSERT INTO contributions (id, account_id, tile_id, healpix_order, '
      'frames_delta, integration_seconds_delta, median_fwhm, trust_applied, '
      'status, delta_path, instrument, solver, license, consent_id, '
      'created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        contributionId,
        accountId,
        tileId,
        order,
        framesDelta,
        integrationSecondsDelta,
        medianFwhm,
        trustApplied,
        status,
        deltaPath,
        instrument,
        solver,
        license,
        consentId,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  void _upsertTileIndex(TileAccumulator tile) {
    final center = TileBuilder.tileCenter(tile.tileId, tile.order);
    _db.db.execute(
      'INSERT INTO tile_index (tile_id, healpix_order, channels, '
      'center_ra_deg, center_dec_deg, total_frames, integration_seconds, '
      'contributors, sidecar_path, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(tile_id, healpix_order) DO UPDATE SET '
      'channels = excluded.channels, '
      'total_frames = excluded.total_frames, '
      'integration_seconds = excluded.integration_seconds, '
      'contributors = excluded.contributors, '
      'sidecar_path = excluded.sidecar_path, '
      'updated_at = excluded.updated_at;',
      <Object?>[
        tile.tileId,
        tile.order,
        tile.channels,
        center.$1,
        center.$2,
        tile.totalFrames,
        tile.totalIntegrationSeconds,
        tile.contributors.length,
        _store.pathFor(tile.tileId, tile.order),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  void _writeDelta(String path, Uint8List bytes) {
    final file = File(path);
    final dir = Directory(file.parent.path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
  }

  Uint8List _readDelta(String path) {
    return File(path).readAsBytesSync();
  }
}

/// Result of a [FusionService.contribute] call.
class ContributionOutcome {
  ContributionOutcome({
    required this.contributionId,
    required this.accepted,
    required this.trustApplied,
    required this.totalFramesAfter,
    required this.integrationSecondsAfter,
    required this.contributorsAfter,
    required this.verdict,
  });

  final String contributionId;
  final bool accepted;
  final double trustApplied;
  final int totalFramesAfter;
  final double integrationSecondsAfter;
  final int contributorsAfter;
  final TileQualityVerdict verdict;
}

/// Result of a [FusionService.retract] call.
class RetractionOutcome {
  RetractionOutcome({
    required this.retracted,
    required this.totalFramesAfter,
    required this.integrationSecondsAfter,
    required this.contributorsAfter,
  });

  final bool retracted;
  final int totalFramesAfter;
  final double integrationSecondsAfter;
  final int contributorsAfter;
}

/// Thrown when a retraction targets an unknown contribution id (404).
class ContributionNotFound implements Exception {
  ContributionNotFound(this.id);
  final String id;
  @override
  String toString() => 'ContributionNotFound: $id';
}

/// Thrown when a caller tries to retract a contribution they do not own (403).
class ContributionForbidden implements Exception {
  ContributionForbidden(this.id);
  final String id;
  @override
  String toString() => 'ContributionForbidden: $id';
}

/// Thrown when a contribution is not in a retractable state (409).
class ContributionStateError implements Exception {
  ContributionStateError(this.message);
  final String message;
  @override
  String toString() => 'ContributionStateError: $message';
}

/// Thrown when a contribution's declared geometry or self-reported stats are
/// out of the hub's accepted range. Mapped to HTTP 400 by the route layer (the
/// uploader sent a request the hub will never accept as-is).
class ContributionRejected implements Exception {
  ContributionRejected(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'ContributionRejected($code): $message';
}

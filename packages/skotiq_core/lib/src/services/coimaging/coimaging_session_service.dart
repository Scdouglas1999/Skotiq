// Client-side orchestration for live co-imaging.
//
// [CoImagingSessionService] is the workflow on top of the raw
// [ConstellationClient] co-imaging endpoints: it CREATEs / JOINs a live session,
// persists the hub-assigned framing offset + membership token durably (so a
// relaunched host or a remote companion re-renders the session without a live
// round-trip), reports each rig's contribution to the hub's COMBINED accounting,
// drives the longitude hand-off baton, and exposes the live combined-preview
// stream. It mirrors the construction of [CollaborativeMosaicService]: a
// settings-backed credentials resolver, the durable [CoImagingSessionsDao], and
// an injectable client factory for tests.

import 'dart:async';
import 'dart:math' as math;

import '../../database/database.dart' show CoImagingSessionRow;
import '../../models/collaboration/collaboration_models.dart'
    show ContributionLicense;
import '../../database/daos/coimaging_sessions_dao.dart';
import '../../database/daos/constellation_contributions_dao.dart';
import '../constellation/constellation_client.dart';
import '../constellation/constellation_models.dart';
import '../constellation/constellation_service.dart';
import '../logging_service.dart';
import '../scheduler/sky_calculations.dart';
import '../constellation/constellation_hub_key.dart';
part 'coimaging_session_service/coimaging_types.dart';
part 'coimaging_session_service/baton_scheduler.dart';
part 'coimaging_session_service/internals.dart';

/// Client-side orchestration for live co-imaging sessions.
class CoImagingSessionService {
  CoImagingSessionService({
    required Future<ConstellationCredentials?> Function() credentialsResolver,
    required CoImagingSessionsDao sessionsDao,
    required LoggingService logger,
    ConstellationContributionsDao? contributionsDao,
    ConstellationClientFactory? clientFactory,
    CoImagingTileFuser? fusionContributor,
    CoImagingContributionConsentResolver? consentResolver,
    int order = ConstellationService.defaultHealpixOrder,
  }) : _credentialsResolver = credentialsResolver,
       _sessions = sessionsDao,
       _logger = logger,
       _contributions = contributionsDao,
       _clientFactory = clientFactory ?? _defaultClientFactory,
       _fuser = fusionContributor,
       _consentResolver = consentResolver,
       _order = order;

  final Future<ConstellationCredentials?> Function() _credentialsResolver;
  final CoImagingSessionsDao _sessions;
  final LoggingService _logger;

  /// Optional: ties the co-imaging session id onto the per-tile contribution
  /// high-water (`constellation_contributions.session_id`) so a tile contributed
  /// while in a session records which session deepened it. Null in legacy/test
  /// wirings that predate the receipt table.
  final ConstellationContributionsDao? _contributions;
  final ConstellationClientFactory _clientFactory;

  /// Folds a completed sub into the session's shared-target tile through the
  /// existing additive-sum pipeline (see [CoImagingTileFuser]). Null in legacy /
  /// test wirings that only exercise the coordination layer; [recordCompletedSub]
  /// then advances accounting without an auto-fuse (the caller fused already).
  final CoImagingTileFuser? _fuser;

  /// Resolves the operator's persisted contribution consent (license +
  /// attribution). Null only in legacy / test wirings that drive accounting
  /// directly; [recordCompletedSub] then skips the consent gate (the caller
  /// owns consent). In the real app wiring this is always present and
  /// [recordCompletedSub] / [recordContribution] fail CLOSED on a null record.
  final CoImagingContributionConsentResolver? _consentResolver;

  /// The angular tolerance (degrees) within which a captured / centred frame's
  /// sky centre is treated as belonging to a live session's target. A session
  /// radius is ~1.5 deg; 2.0 keeps a slightly-off plate-solve or a framing-offset
  /// tile inside the match while staying well clear of an unrelated target.
  static const double membershipMatchToleranceDeg = 2.0;

  /// The imaging-altitude floor (degrees) the longitude-baton automation
  /// claims-above / releases-below by default — the same 20 deg the planner
  /// treats as the practical horizon for useful integration.
  static const double defaultImagingAltitudeFloorDeg = 20.0;

  final int _order;

  static const _logSource = 'CoImagingSessionService';

  static ConstellationClient _defaultClientFactory(
    ConstellationCredentials c,
  ) =>
      ConstellationClient(hubBaseUrl: c.hubBaseUrl, bearerToken: c.bearerToken);

  // Create / join / leave

  /// Open a live co-imaging session on a target and persist this rig's owner
  /// membership (anchor framing offset + membership token) durably.
  Future<CoImagingSession> createSession({
    required String targetName,
    required double raDeg,
    required double decDeg,
    double radiusDeg = 1.5,
    String? rigId,
  }) async {
    final creds = await _credentialsResolver();
    final client = await _requireClient();
    try {
      final session = await client.createCoImagingSession(
        targetName: targetName,
        centerRaDeg: raDeg,
        centerDecDeg: decDeg,
        radiusDeg: radiusDeg,
        rigId: rigId,
      );
      await _persistMembership(creds, session, rigId: rigId);
      _logger.info(
        'Opened co-imaging session ${session.sessionId} on "$targetName".',
        source: _logSource,
      );
      return session;
    } finally {
      client.close();
    }
  }

  /// JOIN an existing live session as a rig and persist the hub-assigned framing
  /// offset + membership token durably.
  ///
  /// When the caller already holds the session's identity (e.g. it joined from a
  /// browsed [CoImagingSession] card), it MAY pass [targetName] / [targetRaDeg]
  /// / [targetDecDeg] so the durable membership carries the sky centre — the join
  /// participant payload itself does not echo target coordinates, and those are
  /// what [framingOffsetFor] (RA-scaling by cos(dec)), [evaluateBaton] (altitude
  /// trigger), and [membershipsForPoint] (the in-process auto-contribute filter)
  /// need offline.
  ///
  /// When the caller omits them — notably the headless REST join path, which has
  /// only the session id — they are backfilled HERE from a single live
  /// [getCoImagingSession] on the same open client, so EVERY join persists a
  /// coordinate-bearing membership row. [framingOffsetFor] / [evaluateBaton]
  /// self-heal lazily on first use, but [membershipsForPoint] does not, so a
  /// coordinate-less row would silently exclude the rig from its own
  /// auto-contribute — backfilling on join closes that path-specific gap.
  Future<CoImagingParticipant> joinSession(
    String sessionId, {
    String? rigId,
    String role = 'contribute',
    String? targetName,
    double? targetRaDeg,
    double? targetDecDeg,
  }) async {
    final creds = await _credentialsResolver();
    final client = await _requireClient();
    try {
      final participant = await client.joinCoImagingSession(
        sessionId,
        rigId: rigId,
        role: role,
      );
      // Backfill the sky centre when the caller did not supply it so the durable
      // row is never coordinate-less (the join payload carries no coordinates).
      var name = targetName;
      var raDeg = targetRaDeg;
      var decDeg = targetDecDeg;
      if (raDeg == null || decDeg == null) {
        final session = await client.getCoImagingSession(sessionId);
        name ??= session.targetName;
        raDeg ??= session.centerRaDeg;
        decDeg ??= session.centerDecDeg;
      }
      if (creds != null) {
        await _sessions.upsertMembership(
          constellationHubKey(creds.hubBaseUrl),
          sessionId,
          targetName: name,
          targetRaDeg: raDeg,
          targetDecDeg: decDeg,
          role: participant.role,
          claimToken: participant.membershipToken,
          framingOffsetIndex: participant.framingOffsetIndex,
          framingOffsetRaArcsec: participant.framingOffsetRaArcsec,
          framingOffsetDecArcsec: participant.framingOffsetDecArcsec,
          active: true,
        );
      }
      _logger.info(
        'Joined co-imaging session $sessionId at framing slot '
        '${participant.framingOffsetIndex}.',
        source: _logSource,
      );
      return participant;
    } finally {
      client.close();
    }
  }

  /// Leave a session and mark the local membership inactive (history survives).
  Future<bool> leaveSession(String sessionId, {String? rigId}) async {
    final creds = await _credentialsResolver();
    final client = await _requireClient();
    try {
      final left = await client.leaveCoImagingSession(sessionId, rigId: rigId);
      if (creds != null) {
        await _sessions.markInactive(
          constellationHubKey(creds.hubBaseUrl),
          sessionId,
        );
      }
      return left;
    } finally {
      client.close();
    }
  }

  /// Close a session (owner/admin action). Flips it to `closed` on the hub,
  /// tears down its live preview subscribers, and marks the local membership
  /// inactive. Returns the closed session's state.
  Future<CoImagingSession> closeSession(String sessionId) async {
    final creds = await _credentialsResolver();
    final client = await _requireClient();
    try {
      final session = await client.closeCoImagingSession(sessionId);
      if (creds != null) {
        await _sessions.markInactive(
          constellationHubKey(creds.hubBaseUrl),
          sessionId,
        );
      }
      _logger.info('Closed co-imaging session $sessionId.', source: _logSource);
      return session;
    } finally {
      client.close();
    }
  }

  // Combined accounting

  /// Report this rig's contribution (frames + integration it just folded into the
  /// shared-target tile) to the session's COMBINED accounting, presenting the
  /// stored membership token. Advances the local cumulative tally and returns the
  /// hub's combined totals across all rigs.
  Future<CoImagingAccounting> recordContribution(
    String sessionId, {
    required int framesDelta,
    required double integrationSecondsDelta,
    String? rigId,
    ContributionLicense? license,
    bool? attributionConsent,
  }) async {
    // Consent gate: this report records the rig's license + attribution in
    // the hub's per-participant attribution ledger, so it must reflect the
    // operator's ACTUAL choice — never a silent ccBy + public default. When the
    // caller did not pass an explicit consent (e.g. the headless contribute
    // endpoint), resolve the persisted record and FAIL CLOSED if absent.
    final resolved = await _resolveContributionConsent(
      license: license,
      attributionConsent: attributionConsent,
    );
    if (resolved == null) {
      // A missing LOCAL consent is a device precondition, not a hub
      // authentication failure: reporting it as `auth` makes a caller re-check
      // its bearer token instead of recording the sharing choice the message
      // actually asks for.
      throw const ConstellationException(
        'No co-imaging contribution consent is on record. Pass an explicit '
        '{"license", "attributionConsent"} with this request, or choose a '
        'sharing license and attribution preference to persist first.',
        kind: ConstellationErrorKind.conflict,
      );
    }
    final effectiveLicense = resolved.license;
    final effectiveAttribution = resolved.attributionConsent;
    final creds = await _credentialsResolver();
    final hubKey = creds == null ? null : constellationHubKey(creds.hubBaseUrl);
    // Resolve the stored membership token so the hub's per-rig gate accepts us.
    String? membershipToken;
    int priorFrames = 0;
    double priorSeconds = 0;
    if (hubKey != null) {
      final row = await _sessions.getSession(hubKey, sessionId);
      membershipToken = row?.claimToken;
      priorFrames = row?.contributedFrames ?? 0;
      priorSeconds = row?.contributedIntegrationSeconds ?? 0;
    }
    final client = await _requireClient();
    try {
      final accounting = await client.recordCoImagingContribution(
        sessionId,
        framesDelta: framesDelta,
        integrationSecondsDelta: integrationSecondsDelta,
        license: effectiveLicense.wireName,
        rigId: rigId,
        membershipToken: membershipToken,
        attributionConsent: effectiveAttribution,
      );
      if (hubKey != null) {
        await _sessions.updateProgress(
          hubKey,
          sessionId,
          contributedFrames: priorFrames + (framesDelta < 0 ? 0 : framesDelta),
          contributedIntegrationSeconds:
              priorSeconds +
              (integrationSecondsDelta < 0 ? 0 : integrationSecondsDelta),
        );
      }
      _logger.info(
        'Co-imaging session $sessionId now at ${accounting.combinedFrames} '
        'combined frames across ${accounting.participantCount} '
        'rig${accounting.participantCount == 1 ? '' : 's'}.',
        source: _logSource,
      );
      return accounting;
    } finally {
      client.close();
    }
  }

  /// Tie [sessionId] onto the per-tile contribution receipt for [tileId] so a
  /// tile deepened while in a session records which session drove it (reuses the
  /// foundation's `constellation_contributions.session_id`). Best-effort: a
  /// missing receipt store / no-hub simply skips.
  Future<void> tagTileSession({
    required int tileId,
    required String sessionId,
  }) async {
    final dao = _contributions;
    if (dao == null) return;
    final creds = await _credentialsResolver();
    if (creds == null) return;
    await dao.upsertContribution(
      constellationHubKey(creds.hubBaseUrl),
      tileId,
      healpixOrder: _order,
      sessionId: sessionId,
    );
  }

  // Framing-offset pointing

  /// The (raDeg, decDeg) pointing DELTA this rig should add to the session
  /// target's centre so its optical centre sits at `centre + offset`, making
  /// the hub's framing slot a real coverage tile that rejects walking /
  /// correlated noise.
  ///
  /// The hub assigns the offset as a true angular nudge in arcseconds
  /// (`framing_offset_*_arcsec`); converting the RA arcsec component to an RA
  /// *coordinate* delta requires dividing by cos(dec) (a given on-sky arcsec is a
  /// larger RA-degree step nearer the pole). Slot 0 (the anchor) returns (0, 0).
  /// Returns null when this rig is not an active member of the session or no hub
  /// is configured. The value is stable for the lifetime of the membership (it is
  /// a fixed coverage tile; normal per-sub dither layers on top elsewhere), so it
  /// is applied once at framing time, not per-sub.
  Future<({double raDeg, double decDeg})?> framingOffsetFor(
    String sessionId,
  ) async {
    final creds = await _credentialsResolver();
    if (creds == null) return null;
    final hubKey = constellationHubKey(creds.hubBaseUrl);
    final row = await _sessions.getSession(hubKey, sessionId);
    if (row == null || !row.active) return null;
    final raArcsec = row.framingOffsetRaArcsec;
    final decArcsec = row.framingOffsetDecArcsec;
    // Anchor slot (or any zero offset): no nudge, no need to resolve dec.
    if (raArcsec == 0 && decArcsec == 0) {
      return (raDeg: 0.0, decDeg: 0.0);
    }
    // RA scaling needs the target declination; self-heal from a live session if
    // the membership row predates carrying the centre (e.g. an early join).
    final decDeg = row.targetDecDeg ?? (await _sessionCenter(sessionId)).decDeg;
    return offsetDeltaDegrees(
      raArcsec: raArcsec,
      decArcsec: decArcsec,
      decDeg: decDeg,
    );
  }

  /// Pure conversion of a hub framing offset (arcsec on the sky) to an
  /// RA/Dec coordinate delta in degrees, RA scaled by 1/cos(dec). Exposed for the
  /// sequencer/centering routine and unit tests.
  static ({double raDeg, double decDeg}) offsetDeltaDegrees({
    required double raArcsec,
    required double decArcsec,
    required double decDeg,
  }) {
    final cosDec = math.cos(decDeg * math.pi / 180.0);
    // Guard the pole: clamp the divisor so a near-90 deg target cannot blow the
    // RA delta up to a meaningless slew.
    final safeCos = cosDec.abs() < 1e-4
        ? (cosDec.isNegative ? -1e-4 : 1e-4)
        : cosDec;
    return (raDeg: (raArcsec / 3600.0) / safeCos, decDeg: decArcsec / 3600.0);
  }

  /// The absolute RA/Dec (degrees) this rig should centre on for [sessionId]:
  /// the session centre plus this rig's framing offset. Returns null when not an
  /// active member. This is the one value the centering/slew routine consumes.
  Future<({double raDeg, double decDeg})?> framedCenterFor(
    String sessionId, {
    required double centerRaDeg,
    required double centerDecDeg,
  }) async {
    final offset = await framingOffsetFor(sessionId);
    if (offset == null) return null;
    return (
      raDeg: centerRaDeg + offset.raDeg,
      decDeg: centerDecDeg + offset.decDeg,
    );
  }

  /// The active memberships whose session-target centre lies within
  /// [toleranceDeg] of the given sky point (degrees). Used to attribute a
  /// centring/slew target or a freshly captured frame to the live session(s) it
  /// belongs to WITHOUT a hub round-trip — the durable membership row already
  /// carries the session centre. Empty when this rig is not co-imaging the point.
  Future<List<CoImagingSessionRow>> membershipsForPoint({
    required double raDeg,
    required double decDeg,
    double toleranceDeg = membershipMatchToleranceDeg,
  }) async {
    final rows = await activeMemberships();
    return rows
        .where((r) {
          final tRa = r.targetRaDeg;
          final tDec = r.targetDecDeg;
          if (tRa == null || tDec == null) return false;
          return angularSeparationDegrees(raDeg, decDeg, tRa, tDec) <=
              toleranceDeg;
        })
        .toList(growable: false);
  }

  /// The absolute RA/Dec (degrees) this rig should slew / centre on when the
  /// requested target centre belongs to a live co-imaging session it is in: the
  /// centre plus this rig's hub-assigned framing offset (Gap 1 — turns the offset
  /// from a displayed value into real pointing so rigs tile the field instead of
  /// stacking identically). Returns null when the rig is not an active member of
  /// any session covering the point, so the caller slews to the raw centre.
  ///
  /// This is the seam the centering/slew path consumes: it resolves the
  /// session from the point itself (no session id needed at the call site), so a
  /// manual recenter, a sequencer slew, or the headless framing endpoint all
  /// frame the rig's coverage tile automatically.
  Future<({double raDeg, double decDeg})?> framedCenterForPoint({
    required double centerRaDeg,
    required double centerDecDeg,
  }) async {
    final matches = await membershipsForPoint(
      raDeg: centerRaDeg,
      decDeg: centerDecDeg,
    );
    for (final row in matches) {
      final framed = await framedCenterFor(
        row.sessionId,
        centerRaDeg: centerRaDeg,
        centerDecDeg: centerDecDeg,
      );
      if (framed != null) return framed;
    }
    return null;
  }

  /// Great-circle angular separation (degrees) between two sky points. Pure +
  /// static so the membership matcher and unit tests share one implementation.
  static double angularSeparationDegrees(
    double ra1Deg,
    double dec1Deg,
    double ra2Deg,
    double dec2Deg,
  ) {
    const d2r = math.pi / 180.0;
    final dec1 = dec1Deg * d2r;
    final dec2 = dec2Deg * d2r;
    final dRa = (ra1Deg - ra2Deg) * d2r;
    final cosSep =
        math.sin(dec1) * math.sin(dec2) +
        math.cos(dec1) * math.cos(dec2) * math.cos(dRa);
    return math.acos(cosSep.clamp(-1.0, 1.0)) / d2r;
  }

  // Capture-loop auto-contribute

  /// Drive one completed sub all the way through the co-imaging pipeline, in the
  /// order that keeps accounting honest:
  ///
  ///   (a) fold the sub's additive sum into the session's shared-target tile via
  ///       the injected [CoImagingTileFuser] (the existing
  ///       `ConstellationService.contributeTarget` `.nst` upload);
  ///   (b) report `framesDelta` + `exposureSeconds` to the COMBINED accounting;
  ///   (c) tag `constellation_contributions.session_id` so the deepened tile
  ///       records which session drove it.
  ///
  /// When a fuser is wired and it deepens nothing (upload failed, or no local
  /// tile overlapped the cone), accounting is not advanced and this returns
  /// null, so the combined-integration display cannot claim depth the fusion
  /// never received.
  ///
  /// With a fuser wired, the combined accounting advances by the delta the
  /// fuser actually pushed ([CoImagingFusionResult.framesPushed] /
  /// `integrationSecondsPushed`); [framesDelta] / [exposureSeconds] are used
  /// only in the no-fuser wiring, where the caller fused and reports its own
  /// delta.
  ///
  /// Data leaves the device here, so the operator's persisted sharing license +
  /// attribution preference is resolved up front and fails closed: with no
  /// consent record the sub is not contributed (returns null) rather than
  /// shipping under a silent ccBy + public default.
  Future<CoImagingAccounting?> recordCompletedSub(
    String sessionId, {
    required double exposureSeconds,
    int framesDelta = 1,
    String? rigId,
    double radiusDeg = 1.5,
    ContributionLicense? license,
    bool? attributionConsent,
  }) async {
    // Consent gate (fail closed): resolve the operator's persisted sharing
    // license + attribution before anything leaves the device. A null record
    // means the user has not consented — skip the contribution entirely.
    final consent = await _resolveContributionConsent(
      license: license,
      attributionConsent: attributionConsent,
    );
    if (consent == null) {
      _logger.warning(
        'recordCompletedSub($sessionId): no contribution consent on record; '
        'NOT contributing the sub (fail closed).',
        source: _logSource,
      );
      return null;
    }

    // Resolve the live session for the shared-target id + active fused tile the
    // fuse + tag steps key on (and to refuse a closed session up front).
    final session = await getSession(sessionId);
    if (!session.isActive) {
      throw const ConstellationException(
        'Co-imaging session is closed — no further subs can be contributed.',
        kind: ConstellationErrorKind.conflict,
      );
    }

    // (a) Fuse the additive sum into the shared-target tile. The TRUE pushed
    // delta drives the accounting below; a zero-tile result trips the guard.
    var reportedFrames = framesDelta;
    var reportedSeconds = exposureSeconds;
    final fuser = _fuser;
    if (fuser != null) {
      final fused = await fuser(
        CoImagingFusionRequest(
          sharedTargetId: session.sharedTargetId,
          targetName: session.targetName,
          centerRaDeg: session.centerRaDeg,
          centerDecDeg: session.centerDecDeg,
          radiusDeg: radiusDeg,
          activeTileId: session.activeTileId,
          license: consent.license,
          attributionConsent: consent.attributionConsent,
        ),
      );
      if (fused.acceptedTiles <= 0) {
        _logger.warning(
          'recordCompletedSub($sessionId): fusion deepened nothing; NOT '
          'advancing combined accounting (no phantom depth).',
          source: _logSource,
        );
        return null;
      }
      // Report exactly what fusion received, so the headline combined depth can
      // never drift above (or, per accepted-tile, below) the fused stack.
      reportedFrames = fused.framesPushed;
      reportedSeconds = fused.integrationSecondsPushed;
    }

    // (b) Advance the COMBINED accounting with the consented license + the true
    // pushed delta.
    final accounting = await recordContribution(
      sessionId,
      framesDelta: reportedFrames,
      integrationSecondsDelta: reportedSeconds,
      rigId: rigId,
      license: consent.license,
      attributionConsent: consent.attributionConsent,
    );

    // (c) Tag which session deepened the active tile (best-effort).
    if (session.activeTileId != null) {
      await tagTileSession(tileId: session.activeTileId!, sessionId: sessionId);
    }
    return accounting;
  }

  // Longitude baton

  /// Current baton holder for the session.
  Future<CoImagingBatonState> batonState(String sessionId) async {
    final client = await _requireClient();
    try {
      return await client.getCoImagingBaton(sessionId);
    } finally {
      client.close();
    }
  }

  /// Claim the active-imager baton (null when another site holds it).
  Future<HandoffClaim?> claimBaton(String sessionId) async {
    final client = await _requireClient();
    try {
      return await client.claimCoImagingBaton(sessionId);
    } finally {
      client.close();
    }
  }

  /// Release the baton (hand it east as the target sets).
  Future<bool> releaseBaton(String sessionId) async {
    final client = await _requireClient();
    try {
      return await client.releaseCoImagingBaton(sessionId);
    } finally {
      client.close();
    }
  }

  /// One altitude-driven longitude-baton tick for [sessionId] at this rig's
  /// observer location — productizes the site->site hand-off so the combined
  /// stack keeps growing without anyone touching the UI:
  ///
  ///   * when the session target is above [altitudeFloorDeg] here, CLAIM the
  ///     baton (begin/continue imaging) — a [HandoffClaim] when granted, null
  ///     when another site still holds it;
  ///   * when it has set (or dropped below the floor), RELEASE the baton so the
  ///     next site east can claim it.
  ///
  /// The rig knows its own [latitudeDeg]/[longitudeDeg]; the target centre is
  /// taken from the durable membership (or filled from a live session once). No
  /// hub change is needed — every rig folds into the SAME `activeTileFor(session)`
  /// tile, so the depth survives the hand-off. [atUtc] defaults to now (injectable
  /// for tests / simulated longitudes).
  Future<CoImagingBatonDecision> evaluateBaton(
    String sessionId, {
    required double latitudeDeg,
    required double longitudeDeg,
    double altitudeFloorDeg = defaultImagingAltitudeFloorDeg,
    DateTime? atUtc,
  }) async {
    final center = await _sessionCenter(sessionId);
    final altitudeDeg = observerAltitudeDegrees(
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      raDeg: center.raDeg,
      decDeg: center.decDeg,
      atUtc: atUtc ?? DateTime.now().toUtc(),
    );
    if (altitudeDeg >= altitudeFloorDeg) {
      final claim = await claimBaton(sessionId);
      _logger.info(
        'evaluateBaton($sessionId): target up at ${altitudeDeg.toStringAsFixed(1)}'
        ' deg — ${claim != null ? 'claimed the baton' : 'baton held by another '
                  'site'}.',
        source: _logSource,
      );
      return CoImagingBatonDecision(
        altitudeDeg: altitudeDeg,
        aboveFloor: true,
        claim: claim,
        released: false,
      );
    }
    final released = await releaseBaton(sessionId);
    _logger.info(
      'evaluateBaton($sessionId): target set at '
      '${altitudeDeg.toStringAsFixed(1)} deg — '
      '${released ? 'released the baton east' : 'baton not held here'}.',
      source: _logSource,
    );
    return CoImagingBatonDecision(
      altitudeDeg: altitudeDeg,
      aboveFloor: false,
      claim: null,
      released: released,
    );
  }

  // Browse / live preview

  /// Browse active sessions on the configured hub.
  Future<List<CoImagingSession>> listSessions() async {
    final client = await _requireClient();
    try {
      return await client.listCoImagingSessions();
    } finally {
      client.close();
    }
  }

  /// One session's live detail (participants + baton + combined totals).
  Future<CoImagingSession> getSession(String sessionId) async {
    final client = await _requireClient();
    try {
      return await client.getCoImagingSession(sessionId);
    } finally {
      client.close();
    }
  }

  /// The authoritative contributor-credit list the hub materialized for this
  /// session (`GET /v1/attribution` keyed `coimaging`/[sessionId]) — read back
  /// consent-aware from the hub rather than reconstructed from the participant
  /// roster, so a contributor who withheld credit renders anonymously.
  Future<ArtifactAttribution> fetchAttribution(String sessionId) async {
    final client = await _requireClient();
    try {
      return await client.fetchAttribution(
        artifactType: 'coimaging',
        artifactRef: sessionId,
      );
    } finally {
      client.close();
    }
  }

  /// The sessions this rig is still an active participant of, rehydrated from the
  /// durable membership table without a live round-trip.
  Future<List<CoImagingSessionRow>> activeMemberships() {
    return _sessions.getActiveSessions();
  }

  /// Subscribe to the live combined-preview channel for a session. Yields a
  /// snapshot immediately then one [CoImagingPreview] per contribution / join.
  /// The caller MUST cancel the subscription to release the streaming connection.
  ///
  /// NOTE: this opens its own [ConstellationClient] for the lifetime of the
  /// stream (an SSE connection is long-lived, unlike the request/response calls
  /// above), so it is closed only when the subscription completes/cancels.
  Stream<CoImagingPreview> watchPreview(String sessionId) async* {
    final client = await _requireClient();
    try {
      yield* client.streamCoImagingEvents(sessionId);
    } finally {
      client.close();
    }
  }

  /// Geometric altitude (degrees) of a sky position from an observer site at a
  /// UTC instant. Standard hour-angle altitude formula (same maths the planner's
  /// `TargetsDao` observability filter uses), kept pure + static here so the
  /// longitude-baton automation can drive it without a DAO and so it is unit
  /// testable for simulated longitudes.
  ///
  /// It deliberately does NOT call [SkyCalculations.altitudeDegrees], which is
  /// otherwise the shared copy of this formula. This one converts through a
  /// `const d2r = pi/180` and un-converts by dividing by it; the shared helper
  /// multiplies by `180/pi`. Those are not the same double — they disagree in
  /// the last bit for roughly a quarter of all inputs — and this function's
  /// longitude-baton tests are pinned to the numbers it returns today.
  static double observerAltitudeDegrees({
    required double latitudeDeg,
    required double longitudeDeg,
    required double raDeg,
    required double decDeg,
    required DateTime atUtc,
  }) {
    final lstDeg = _localSiderealTimeDegrees(atUtc.toUtc(), longitudeDeg);
    var haDeg = (lstDeg - raDeg) % 360.0;
    if (haDeg < -180.0) haDeg += 360.0;
    if (haDeg > 180.0) haDeg -= 360.0;
    const d2r = math.pi / 180.0;
    final latRad = latitudeDeg * d2r;
    final decRad = decDeg * d2r;
    final haRad = haDeg * d2r;
    final sinAlt =
        math.sin(decRad) * math.sin(latRad) +
        math.cos(decRad) * math.cos(latRad) * math.cos(haRad);
    return math.asin(sinAlt.clamp(-1.0, 1.0)) / d2r;
  }

  /// Unlike `TargetsDao`, this wraps GMST once, *after* the site longitude is
  /// added. The two orders differ by ~1e-9° (GMST is ~3.4e6° for a modern
  /// date), so the composition stays here and only the polynomial is shared.
  static double _localSiderealTimeDegrees(DateTime atUtc, double longitudeDeg) {
    final gmst = SkyCalculations.gmstDegreesRaw(_julianDate(atUtc));
    final lst = (gmst + longitudeDeg) % 360.0;
    return lst < 0 ? lst + 360.0 : lst;
  }

  static double _julianDate(DateTime atUtc) =>
      SkyCalculations.julianDate(atUtc);
}

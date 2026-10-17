import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../collab/consent_service.dart';
import '../db/hub_database.dart';
import 'follow_the_night.dart';
import 'handoff_service.dart';

/// Live co-imaging session coordinator — work-splitting across rigs.
///
/// Multiple rigs JOIN the SAME target and their subs co-add through the EXISTING
/// additive fusion pipeline (`FusionService` on the session's shared-target
/// tile), so effective integration scales with rig count and imaging continues
/// across longitudes. This service is the coordination layer on top of that:
///
///   * It owns a [coimaging_sessions] row tracking the COMBINED integration time
///     + frame count across every participating rig (re-aggregated from the
///     per-participant tallies on each report, so the total is always exact and
///     a duplicate report can never inflate it).
///   * On JOIN it assigns each rig a UNIQUE framing-offset slot — a small RA/Dec
///     dither nudge on an expanding ring pattern — so rigs tile the field instead
///     of stacking identically (better coverage + walking/correlated-noise
///     rejection). Slot 0 is the anchor (no offset).
///   * It pushes a LIVE COMBINED PREVIEW to every participant over a streamed
///     events channel ([subscribe]) as subs fuse — the "we are building this
///     together, right now" signal. (The hub is pure-Dart with no WebSocket
///     dependency, so the channel is delivered as Server-Sent Events — a streamed
///     `text/event-stream` shelf response — which has identical push-to-all
///     semantics with no new dependency.)
///   * It productizes the LONGITUDE HAND-OFF by re-using the existing
///     [HandoffService] single-holder claim, keyed on THIS SESSION (not the
///     cone-merged shared target, so unrelated sessions on the same object cannot
///     seize each other's baton): as the target sets at site A the baton moves to
///     site B, and because every rig folds into the same fused tile the combined
///     stack just keeps growing.
///
/// DB access is synchronous (sqlite3) and the slot-assignment / accounting
/// critical sections take no `await`, so under shelf's single-isolate event loop
/// they serialize — no TOCTOU on the unique-slot or combined-total invariants.
class CoImagingService {
  CoImagingService({
    required HubDatabase db,
    required FollowTheNightScheduler scheduler,
    required HandoffService handoff,
    required int healpixOrder,
    ConsentService? consent,
    this.framingStepArcsec = 30.0,
    DateTime Function()? clock,
  }) : _db = db,
       _scheduler = scheduler,
       _handoff = handoff,
       _healpixOrder = healpixOrder,
       _consent = consent,
       _now = clock ?? (() => DateTime.now().toUtc()),
       _random = Random.secure();

  final HubDatabase _db;
  final FollowTheNightScheduler _scheduler;
  final HandoffService _handoff;
  final int _healpixOrder;

  /// Optional consent ledger. When present, each combined-accounting report
  /// revokes the consent row the PREVIOUS report recorded for this participant
  /// before overwriting the participant's single `consent_id`, so a rig
  /// streaming N subs into one session leaves exactly one live consent row (the
  /// current one) instead of N orphaned ones. Nullable so the accounting unit
  /// tests that drive the service in isolation construct it unchanged.
  final ConsentService? _consent;

  /// Wall clock (UTC). Injectable so the anti-forgery contribution envelope can
  /// be exercised deterministically in tests.
  final DateTime Function() _now;
  final Random _random;

  /// How much a single rig may "round up" its reported integration over the true
  /// wall-clock elapsed since it joined — covers clock skew between rig and hub
  /// and the latency between a sub finishing and its report landing.
  static const double _integrationToleranceFactor = 1.1;

  /// One-time head-start (seconds) on the integration envelope so a rig's FIRST
  /// report right after joining — which legitimately carries the sub(s) it was
  /// already integrating around join time — is not rejected, and to absorb clock
  /// skew between rig and hub. Because the envelope is CUMULATIVE (total
  /// contributed seconds vs. wall-clock since join), this is a single allowance
  /// per participant, not a per-report budget, so it cannot be milked by a report
  /// flood to inflate depth. 30 min mirrors the hand-off claim TTL.
  static const double _integrationGraceSeconds = 1800.0;

  /// Fastest physically-plausible cadence (seconds per frame) — a generous lucky-
  /// imaging ceiling (~20 fps). Bounds reported frame counts against elapsed time.
  static const double _minSecondsPerFrame = 0.05;

  /// One-time head-start on the cumulative frame count (same rationale as the
  /// integration grace) plus a hard absolute ceiling on any single report.
  static const int _framesGrace = 2000;
  static const int _absoluteMaxFramesPerReport = 1000000;

  /// Per-ring step (arcsec) of the framing-offset dither pattern. The default
  /// (30") is comfortably larger than typical seeing so adjacent rigs cover
  /// genuinely different sky and de-correlate fixed-pattern / walking noise.
  final double framingStepArcsec;

  /// Active SSE subscribers per session id (the live combined-preview channel).
  final Map<String, Set<StreamController<CoImagingPreviewEvent>>> _subscribers =
      <String, Set<StreamController<CoImagingPreviewEvent>>>{};

  // --- Session lifecycle -----------------------------------------------------

  /// Open a live co-imaging session on a shared target. Ensures (cone-merges) a
  /// [shared_targets] row via [FollowTheNightScheduler.ensureTarget] so the
  /// longitude baton + additive fusion address the same sky, records the session,
  /// and auto-joins the owner as the anchor participant (slot 0). Returns the new
  /// session id.
  String createSession({
    required String ownerAccountId,
    required String targetName,
    required double centerRaDeg,
    required double centerDecDeg,
    double radiusDeg = 1.5,
    double priority = 0.5,
    String? ownerRigId,
  }) {
    final sharedTargetId = _scheduler.ensureTarget(
      name: targetName,
      centerRaDeg: centerRaDeg,
      centerDecDeg: centerDecDeg,
      radiusDeg: radiusDeg,
      priority: priority,
    );
    final sessionId = _generateId();
    final now = _now().toIso8601String();
    _db.db.execute('BEGIN;');
    try {
      _db.db.execute(
        'INSERT INTO coimaging_sessions '
        '(id, owner_account_id, target_name, center_ra_deg, center_dec_deg, '
        'shared_target_id, status, combined_frames, '
        'combined_integration_seconds, created_at, updated_at) '
        "VALUES (?, ?, ?, ?, ?, ?, 'active', 0, 0, ?, ?);",
        <Object?>[
          sessionId,
          ownerAccountId,
          targetName,
          centerRaDeg,
          centerDecDeg,
          sharedTargetId,
          now,
          now,
        ],
      );
      _insertParticipant(
        sessionId: sessionId,
        accountId: ownerAccountId,
        rigId: ownerRigId,
        role: 'admin',
        slot: 0,
        now: now,
      );
      _db.db.execute('COMMIT;');
    } catch (_) {
      _db.db.execute('ROLLBACK;');
      rethrow;
    }
    return sessionId;
  }

  /// One session by id, or null.
  CoImagingSessionRow? getSession(String sessionId) {
    final rows = _db.db.select(
      'SELECT * FROM coimaging_sessions WHERE id = ?;',
      <Object?>[sessionId],
    );
    if (rows.isEmpty) return null;
    return CoImagingSessionRow._fromRow(rows.first);
  }

  /// Active sessions (status = 'active'), newest first.
  List<CoImagingSessionRow> listSessions({int limit = 100}) {
    final capped = limit < 1 ? 1 : (limit > 500 ? 500 : limit);
    final rows = _db.db.select(
      "SELECT * FROM coimaging_sessions WHERE status = 'active' "
      'ORDER BY created_at DESC LIMIT $capped;',
    );
    return rows.map(CoImagingSessionRow._fromRow).toList(growable: false);
  }

  /// Every participant of a session, ordered by assigned slot.
  List<CoImagingParticipantRow> participants(String sessionId) {
    final rows = _db.db.select(
      'SELECT * FROM coimaging_participants WHERE session_id = ? '
      'ORDER BY framing_offset_index ASC;',
      <Object?>[sessionId],
    );
    return rows.map(CoImagingParticipantRow._fromRow).toList(growable: false);
  }

  /// Close a session (owner/admin action). No-op when already closed.
  void closeSession(String sessionId) {
    _db.db.execute(
      "UPDATE coimaging_sessions SET status = 'closed', updated_at = ? "
      "WHERE id = ? AND status = 'active';",
      <Object?>[_now().toIso8601String(), sessionId],
    );
  }

  // --- Join / leave ----------------------------------------------------------

  /// JOIN [sessionId] as [accountId]/[rigId]. Idempotent: a rig already in the
  /// session keeps its assigned slot + membership token (a re-join is a renewal
  /// that re-activates a previously-left membership). A fresh participant is
  /// assigned the lowest free framing-offset slot so its dither nudge is unique
  /// among the current participants. Throws [CoImagingSessionNotFound] for an
  /// unknown session and [CoImagingSessionClosed] for a closed one.
  ///
  /// CRITICAL: no `await` between reading the in-use slot set and the insert, so
  /// the unique-slot assignment is atomic under the single isolate.
  CoImagingParticipantRow join({
    required String sessionId,
    required String accountId,
    String? rigId,
    String role = 'contribute',
  }) {
    final session = getSession(sessionId);
    if (session == null) throw CoImagingSessionNotFound(sessionId);
    if (session.status != 'active') throw CoImagingSessionClosed(sessionId);
    final normRig = rigId ?? '';
    final now = _now().toIso8601String();
    final existing = _participantRow(sessionId, accountId, normRig);
    if (existing != null) {
      // Renewal: keep the assigned slot, re-stamp updated_at/role. A previously
      // LEFT membership has its token cleared to '' (see [leave]); minting a
      // fresh token here genuinely RE-ACTIVATES it so the re-joined rig can
      // contribute again. An already-active membership keeps its existing token.
      final priorToken = existing['membership_token'] as String? ?? '';
      final token = priorToken.isEmpty ? _generateToken() : priorToken;
      _db.db.execute(
        'UPDATE coimaging_participants SET updated_at = ?, role = ?, '
        'membership_token = ? '
        'WHERE session_id = ? AND account_id = ? AND rig_id = ?;',
        <Object?>[now, role, token, sessionId, accountId, normRig],
      );
      final renewed = _participantRowTyped(sessionId, accountId, normRig)!;
      // A renewal re-activates a previously-left membership, so the roster
      // changed just as much as a fresh join did — broadcast it too, otherwise
      // subscribers only learn the rig is back on its next contribution.
      _broadcast(sessionId, kind: 'participant-joined', actor: renewed);
      return renewed;
    }
    final slot = _lowestFreeSlot(sessionId);
    _insertParticipant(
      sessionId: sessionId,
      accountId: accountId,
      rigId: rigId,
      role: role,
      slot: slot,
      now: now,
    );
    final joined = _participantRowTyped(sessionId, accountId, normRig)!;
    _broadcast(sessionId, kind: 'participant-joined', actor: joined);
    return joined;
  }

  /// LEAVE [sessionId]: mark the participant row inactive by clearing its
  /// membership token (history + attribution + accumulated tallies survive).
  /// Returns whether a membership was found. The freed slot becomes re-assignable
  /// to a future joiner.
  bool leave({
    required String sessionId,
    required String accountId,
    String? rigId,
  }) {
    final normRig = rigId ?? '';
    final row = _participantRow(sessionId, accountId, normRig);
    if (row == null) return false;
    _db.db.execute(
      "UPDATE coimaging_participants SET membership_token = '', updated_at = ? "
      'WHERE session_id = ? AND account_id = ? AND rig_id = ?;',
      <Object?>[_now().toIso8601String(), sessionId, accountId, normRig],
    );
    return true;
  }

  /// Whether [accountId] (any rig) is currently an ACTIVE participant — the
  /// authorization gate for contributing accounting + receiving the live preview.
  bool isParticipant(String sessionId, String accountId) {
    final rows = _db.db.select(
      'SELECT 1 FROM coimaging_participants '
      "WHERE session_id = ? AND account_id = ? AND membership_token != '' "
      'LIMIT 1;',
      <Object?>[sessionId, accountId],
    );
    return rows.isNotEmpty;
  }

  /// Whether [accountId]/[rigId] holds a membership matching [membershipToken]
  /// (the contribution gate, mirroring the mosaic claim-token check). A null
  /// token falls back to plain account membership.
  bool holdsMembership({
    required String sessionId,
    required String accountId,
    String? rigId,
    String? membershipToken,
  }) {
    final normRig = rigId ?? '';
    final row = _participantRow(sessionId, accountId, normRig);
    if (row == null) return false;
    final token = row['membership_token'] as String? ?? '';
    if (token.isEmpty) return false; // left the session
    if (membershipToken == null) return true; // account-level membership
    return membershipToken == token;
  }

  // --- Combined accounting + live preview ------------------------------------

  /// Record a rig's contribution to the session's COMBINED accounting after it
  /// has folded its sub into the shared-target tile via the additive fusion path.
  /// Advances the participant's cumulative tallies and re-aggregates the session
  /// combined totals as the EXACT SUM across participants (so accounting is
  /// duplicate-safe and never drifts), then pushes a live combined preview to
  /// every subscriber. Throws [CoImagingSessionNotFound] /
  /// [CoImagingSessionClosed] (a closed session accepts no further
  /// contributions) / [CoImagingParticipantNotFound] / [CoImagingContributionRejected]
  /// (the report exceeds the physically-plausible accounting envelope).
  CoImagingAccounting recordContribution({
    required String sessionId,
    required String accountId,
    String? rigId,
    required int framesDelta,
    required double integrationSecondsDelta,
    String? consentId,
    String? license,
    bool attributionConsent = true,
  }) {
    final session = getSession(sessionId);
    if (session == null) throw CoImagingSessionNotFound(sessionId);
    // A closed session is dead: no further contributions may drift its combined
    // accounting (mirrors the JOIN gate + the close handler's stated contract).
    if (session.status != 'active') throw CoImagingSessionClosed(sessionId);
    final normRig = rigId ?? '';
    final row = _participantRow(sessionId, accountId, normRig);
    if (row == null) throw CoImagingParticipantNotFound(sessionId, accountId);
    final frames = framesDelta < 0 ? 0 : framesDelta;
    final seconds =
        (!integrationSecondsDelta.isFinite || integrationSecondsDelta < 0)
        ? 0.0
        : integrationSecondsDelta;
    // PROVENANCE GUARD: the accounting is self-reported, so bound each report to
    // what a single camera could physically have produced. The cumulative
    // contributed tallies for this rig may never exceed the wall-clock elapsed
    // since it joined (one camera integrates at most one second per second) plus
    // a small skew/latency grace. This caps forged-depth attacks regardless of
    // report frequency: a flood of reports cannot out-run real time, and a single
    // `integrationSecondsDelta=1e30` / `framesDelta=2e9` report is rejected
    // outright instead of silently inflating the shared depth + stealing credit.
    final joinedAt = DateTime.tryParse(row['joined_at'] as String? ?? '');
    final priorFrames = (row['contributed_frames'] as num?)?.toInt() ?? 0;
    final priorSeconds =
        (row['contributed_integration_seconds'] as num?)?.toDouble() ?? 0.0;
    var sinceJoin = joinedAt == null
        ? 0.0
        : _now().difference(joinedAt).inMicroseconds / 1e6;
    if (sinceJoin < 0) sinceJoin = 0.0;
    final maxCumulativeSeconds =
        sinceJoin * _integrationToleranceFactor + _integrationGraceSeconds;
    if (priorSeconds + seconds > maxCumulativeSeconds) {
      throw CoImagingContributionRejected(
        sessionId: sessionId,
        accountId: accountId,
        reason:
            'reported integration (${(priorSeconds + seconds).toStringAsFixed(1)}s '
            'cumulative) exceeds the '
            '${maxCumulativeSeconds.toStringAsFixed(1)}s wall-clock envelope '
            'since this rig joined',
      );
    }
    final maxCumulativeFrames =
        (sinceJoin / _minSecondsPerFrame).floor() + _framesGrace;
    if (frames > _absoluteMaxFramesPerReport ||
        priorFrames + frames > maxCumulativeFrames) {
      throw CoImagingContributionRejected(
        sessionId: sessionId,
        accountId: accountId,
        reason:
            'reported frame count (${priorFrames + frames} cumulative, '
            '+$frames this report) exceeds the plausible per-rig maximum',
      );
    }
    // A participant carries a SINGLE `consent_id`, so the row this report is
    // about to overwrite orphans the consent the previous report recorded for
    // the same share. Revoke it here (inside the same transaction) so the
    // `(coimaging, sessionId)` live-consent count tracks only currently-active
    // shares instead of growing one orphan per sub folded in.
    final priorConsentId = row['consent_id'] as String?;
    final now = _now().toIso8601String();
    _db.db.execute('BEGIN;');
    try {
      if (priorConsentId != null &&
          priorConsentId.isNotEmpty &&
          priorConsentId != consentId) {
        _consent?.revoke(priorConsentId);
      }
      _db.db.execute(
        'UPDATE coimaging_participants SET '
        'contributed_frames = contributed_frames + ?, '
        'contributed_integration_seconds = '
        'contributed_integration_seconds + ?, consent_id = ?, license = ?, '
        'attribution_consent = ?, updated_at = ? '
        'WHERE session_id = ? AND account_id = ? AND rig_id = ?;',
        <Object?>[
          frames,
          seconds,
          consentId,
          license,
          attributionConsent ? 1 : 0,
          now,
          sessionId,
          accountId,
          normRig,
        ],
      );
      // Re-aggregate the authoritative combined totals from the parts.
      final agg = _db.db.select(
        'SELECT COALESCE(SUM(contributed_frames), 0) AS f, '
        'COALESCE(SUM(contributed_integration_seconds), 0) AS s '
        'FROM coimaging_participants WHERE session_id = ?;',
        <Object?>[sessionId],
      ).first;
      final combinedFrames = (agg['f'] as num).toInt();
      final combinedSeconds = (agg['s'] as num).toDouble();
      _db.db.execute(
        'UPDATE coimaging_sessions SET combined_frames = ?, '
        'combined_integration_seconds = ?, updated_at = ? WHERE id = ?;',
        <Object?>[combinedFrames, combinedSeconds, now, sessionId],
      );
      _db.db.execute('COMMIT;');
    } catch (_) {
      _db.db.execute('ROLLBACK;');
      rethrow;
    }
    final updated = getSession(sessionId)!;
    final actor = _participantRowTyped(sessionId, accountId, normRig);
    _broadcast(sessionId, kind: 'combined-preview', actor: actor);
    return CoImagingAccounting(
      sessionId: sessionId,
      combinedFrames: updated.combinedFrames,
      combinedIntegrationSeconds: updated.combinedIntegrationSeconds,
      participantCount: participants(sessionId).length,
    );
  }

  /// The HEALPix tile at the session's target centre — the fused co-add every
  /// participant pulls to see the combined preview deepen.
  int activeTileFor(CoImagingSessionRow session, int order) {
    final target = session.sharedTargetId == null
        ? null
        : _scheduler.getTarget(session.sharedTargetId!);
    if (target != null) {
      return FollowTheNightScheduler.activeTileFor(target, order);
    }
    // No linked target (defensive): address the tile at the stored centre.
    return FollowTheNightScheduler.activeTileFor(
      SharedTarget(
        id: -1,
        name: session.targetName,
        centerRaDeg: session.centerRaDeg,
        centerDecDeg: session.centerDecDeg,
        radiusDeg: 1.5,
        priority: 0.5,
        integrationSeconds: 0,
      ),
      order,
    );
  }

  /// Subscribe to the live combined-preview channel for [sessionId]. The returned
  /// stream emits one snapshot immediately (so a late joiner sees current depth)
  /// then one event per contribution / join until cancelled. The controller is
  /// removed from the fan-out set on cancel so a disconnected participant does not
  /// leak.
  Stream<CoImagingPreviewEvent> subscribe(String sessionId) {
    late final StreamController<CoImagingPreviewEvent> controller;
    controller = StreamController<CoImagingPreviewEvent>(
      onListen: () {
        final session = getSession(sessionId);
        if (session != null) {
          controller.add(_snapshot(session, kind: 'snapshot', actor: null));
        }
      },
      onCancel: () {
        final set = _subscribers[sessionId];
        set?.remove(controller);
        if (set != null && set.isEmpty) _subscribers.remove(sessionId);
      },
    );
    _subscribers.putIfAbsent(sessionId, () => {}).add(controller);
    return controller.stream;
  }

  /// Number of live preview subscribers for a session (test/diagnostic).
  int subscriberCount(String sessionId) => _subscribers[sessionId]?.length ?? 0;

  void _broadcast(
    String sessionId, {
    required String kind,
    CoImagingParticipantRow? actor,
  }) {
    final set = _subscribers[sessionId];
    if (set == null || set.isEmpty) return;
    final session = getSession(sessionId);
    if (session == null) return;
    final event = _snapshot(session, kind: kind, actor: actor);
    for (final controller in set.toList(growable: false)) {
      if (!controller.isClosed) controller.add(event);
    }
  }

  CoImagingPreviewEvent _snapshot(
    CoImagingSessionRow session, {
    required String kind,
    CoImagingParticipantRow? actor,
  }) {
    return CoImagingPreviewEvent(
      kind: kind,
      sessionId: session.id,
      combinedFrames: session.combinedFrames,
      combinedIntegrationSeconds: session.combinedIntegrationSeconds,
      participantCount: participants(session.id).length,
      activeTileId: activeTileFor(session, _healpixOrder),
      actorRigId: actor?.rigId,
      actorFramingOffsetIndex: actor?.framingOffsetIndex,
      at: _now(),
    );
  }

  /// Drop every subscriber for a session (called when the session closes / on
  /// server shutdown) so pending streams complete instead of hanging.
  void disposeSession(String sessionId) {
    final set = _subscribers.remove(sessionId);
    if (set == null) return;
    for (final controller in set) {
      if (!controller.isClosed) controller.close();
    }
  }

  // --- Longitude hand-off baton ----------------------------------------------

  /// Current baton state for a session — who is actively imaging right now (the
  /// holder of the [HandoffService] claim keyed on THIS SESSION). The baton is
  /// scoped to the session, not the cone-merged shared target, so two distinct
  /// sessions on the same object never read/seize each other's baton. It moves
  /// site->site as the target sets.
  CoImagingBatonState batonState(String sessionId) {
    final session = getSession(sessionId);
    if (session == null) throw CoImagingSessionNotFound(sessionId);
    final state = _handoff.sessionState(sessionId);
    return CoImagingBatonState(
      sessionId: sessionId,
      holder: state.holder,
      expiresAt: state.expiresAt,
    );
  }

  /// Claim the active-imager baton for the session (take over imaging as the
  /// target rises at this site). Returns null when another site holds it. Throws
  /// [CoImagingSessionClosed] for a closed session.
  HandoffClaim? claimBaton({
    required String sessionId,
    required String accountId,
  }) {
    final session = getSession(sessionId);
    if (session == null) throw CoImagingSessionNotFound(sessionId);
    if (session.status != 'active') throw CoImagingSessionClosed(sessionId);
    final claimed = _handoff.claimSession(
      sessionId: sessionId,
      accountId: accountId,
    );
    if (claimed == null) return null;
    return HandoffClaim(
      targetId: session.sharedTargetId ?? -1,
      claimToken: claimed.token,
      expiresAt: claimed.expiresAt,
    );
  }

  /// Release the baton (the target is setting at this site; hand it east). Throws
  /// [CoImagingSessionClosed] for a closed session.
  bool releaseBaton({required String sessionId, required String accountId}) {
    final session = getSession(sessionId);
    if (session == null) throw CoImagingSessionNotFound(sessionId);
    if (session.status != 'active') throw CoImagingSessionClosed(sessionId);
    return _handoff.releaseSession(sessionId: sessionId, accountId: accountId);
  }

  // --- Framing offsets -------------------------------------------------------

  /// The deterministic dither nudge (RA arcsec, Dec arcsec) for participant
  /// [slot]. Slot 0 is the anchor (0, 0); higher slots fan out on concentric
  /// rings of 8·r positions each, scaled by [framingStepArcsec]. Distinct slots
  /// always map to distinct offsets, so no two participating rigs frame
  /// identically.
  (double, double) framingOffsetForSlot(int slot) {
    if (slot <= 0) return (0.0, 0.0);
    var ring = 1;
    var idx = slot - 1;
    while (idx >= 8 * ring) {
      idx -= 8 * ring;
      ring++;
    }
    final positions = 8 * ring;
    final angle = 2 * pi * idx / positions;
    final radius = ring * framingStepArcsec;
    return (radius * cos(angle), radius * sin(angle));
  }

  // --- Internals -------------------------------------------------------------

  void _insertParticipant({
    required String sessionId,
    required String accountId,
    required String? rigId,
    required String role,
    required int slot,
    required String now,
  }) {
    final offset = framingOffsetForSlot(slot);
    _db.db.execute(
      'INSERT INTO coimaging_participants '
      '(id, session_id, account_id, rig_id, role, membership_token, '
      'framing_offset_index, framing_offset_ra_arcsec, '
      'framing_offset_dec_arcsec, contributed_frames, '
      'contributed_integration_seconds, joined_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?) '
      'ON CONFLICT(session_id, account_id, rig_id) DO UPDATE SET '
      'role = excluded.role, membership_token = excluded.membership_token, '
      'updated_at = excluded.updated_at;',
      <Object?>[
        _generateId(),
        sessionId,
        accountId,
        rigId ?? '',
        role,
        _generateToken(),
        slot,
        offset.$1,
        offset.$2,
        now,
        now,
      ],
    );
  }

  /// The lowest non-negative slot index not currently held by ANY participant of
  /// the session (active or left — a left participant keeps its slot row, so its
  /// index stays reserved until the row is gone; this keeps assignment simple and
  /// collision-free under the unique offset invariant).
  int _lowestFreeSlot(String sessionId) {
    final rows = _db.db.select(
      'SELECT framing_offset_index AS i FROM coimaging_participants '
      'WHERE session_id = ?;',
      <Object?>[sessionId],
    );
    final used = <int>{for (final r in rows) (r['i'] as num).toInt()};
    var slot = 0;
    while (used.contains(slot)) {
      slot++;
    }
    return slot;
  }

  Map<String, Object?>? _participantRow(
    String sessionId,
    String accountId,
    String rigId,
  ) {
    final rows = _db.db.select(
      'SELECT * FROM coimaging_participants '
      'WHERE session_id = ? AND account_id = ? AND rig_id = ?;',
      <Object?>[sessionId, accountId, rigId],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  CoImagingParticipantRow? _participantRowTyped(
    String sessionId,
    String accountId,
    String rigId,
  ) {
    final row = _participantRow(sessionId, accountId, rigId);
    return row == null ? null : CoImagingParticipantRow._fromRow(row);
  }

  String _generateId() => _uuidV4();

  String _uuidV4() {
    final b = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      b[i] = _random.nextInt(256);
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String hex(int start, int end) => b
        .sublist(start, end)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  String _generateToken() {
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// One live co-imaging session row. [toJson] is the wire shape the client
/// `CoImagingSession.fromJson` decodes; the internal owner account id is emitted
/// only to a privileged caller (owner / participant / admin), mirroring the
/// mosaic privacy scoping.
class CoImagingSessionRow {
  const CoImagingSessionRow({
    required this.id,
    required this.ownerAccountId,
    required this.targetName,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.sharedTargetId,
    required this.status,
    required this.combinedFrames,
    required this.combinedIntegrationSeconds,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String ownerAccountId;
  final String targetName;
  final double centerRaDeg;
  final double centerDecDeg;
  final int? sharedTargetId;
  final String status;
  final int combinedFrames;
  final double combinedIntegrationSeconds;
  final String createdAt;
  final String updatedAt;

  bool get isActive => status == 'active';

  factory CoImagingSessionRow._fromRow(dynamic row) {
    return CoImagingSessionRow(
      id: row['id'] as String,
      ownerAccountId: row['owner_account_id'] as String,
      targetName: row['target_name'] as String? ?? '',
      centerRaDeg: (row['center_ra_deg'] as num?)?.toDouble() ?? 0.0,
      centerDecDeg: (row['center_dec_deg'] as num?)?.toDouble() ?? 0.0,
      sharedTargetId: (row['shared_target_id'] as num?)?.toInt(),
      status: row['status'] as String? ?? 'active',
      combinedFrames: (row['combined_frames'] as num?)?.toInt() ?? 0,
      combinedIntegrationSeconds:
          (row['combined_integration_seconds'] as num?)?.toDouble() ?? 0.0,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );
  }

  Map<String, Object?> toJson({
    bool includeAccountId = false,
    String? ownerDisplayName,
    int? activeTileId,
    String? batonHolder,
    String? batonHolderDisplayName,
    List<Map<String, Object?>>? participants,
  }) => <String, Object?>{
    'sessionId': id,
    if (includeAccountId) 'ownerAccountId': ownerAccountId,
    if (ownerDisplayName != null) 'ownerDisplayName': ownerDisplayName,
    'targetName': targetName,
    'centerRaDeg': centerRaDeg,
    'centerDecDeg': centerDecDeg,
    if (sharedTargetId != null) 'sharedTargetId': sharedTargetId,
    'status': status,
    'combinedFrames': combinedFrames,
    'combinedIntegrationSeconds': combinedIntegrationSeconds,
    if (activeTileId != null) 'activeTileId': activeTileId,
    if (includeAccountId && batonHolder != null) 'batonHolder': batonHolder,
    if (batonHolderDisplayName != null)
      'batonHolderDisplayName': batonHolderDisplayName,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (participants != null) 'participants': participants,
  };
}

/// One participant (rig) of a co-imaging session, carrying its assigned framing
/// offset + cumulative tallies. The internal account id + membership token are
/// emitted only to a privileged caller.
class CoImagingParticipantRow {
  const CoImagingParticipantRow({
    required this.sessionId,
    required this.accountId,
    required this.rigId,
    required this.role,
    required this.membershipToken,
    required this.framingOffsetIndex,
    required this.framingOffsetRaArcsec,
    required this.framingOffsetDecArcsec,
    required this.contributedFrames,
    required this.contributedIntegrationSeconds,
    required this.joinedAt,
    required this.updatedAt,
    required this.license,
    required this.attributionConsent,
  });

  final String sessionId;
  final String accountId;
  final String rigId;
  final String role;
  final String membershipToken;
  final int framingOffsetIndex;
  final double framingOffsetRaArcsec;
  final double framingOffsetDecArcsec;
  final int contributedFrames;
  final double contributedIntegrationSeconds;
  final String joinedAt;
  final String updatedAt;

  /// The share license + named-vs-anonymous choice recorded with this rig's
  /// most-recent combined-accounting report. `attribution_consent` defaults to
  /// credited (true) for a row written before the column existed; the close
  /// attribution renders the contributor anonymously when it is false.
  final String? license;
  final bool attributionConsent;

  bool get isActive => membershipToken.isNotEmpty;

  factory CoImagingParticipantRow._fromRow(dynamic row) {
    return CoImagingParticipantRow(
      sessionId: row['session_id'] as String,
      accountId: row['account_id'] as String,
      rigId: row['rig_id'] as String? ?? '',
      role: row['role'] as String? ?? 'contribute',
      membershipToken: row['membership_token'] as String? ?? '',
      framingOffsetIndex: (row['framing_offset_index'] as num?)?.toInt() ?? 0,
      framingOffsetRaArcsec:
          (row['framing_offset_ra_arcsec'] as num?)?.toDouble() ?? 0.0,
      framingOffsetDecArcsec:
          (row['framing_offset_dec_arcsec'] as num?)?.toDouble() ?? 0.0,
      contributedFrames: (row['contributed_frames'] as num?)?.toInt() ?? 0,
      contributedIntegrationSeconds:
          (row['contributed_integration_seconds'] as num?)?.toDouble() ?? 0.0,
      joinedAt: row['joined_at'] as String,
      updatedAt: row['updated_at'] as String,
      license: row['license'] as String?,
      attributionConsent: (row['attribution_consent'] as num?)?.toInt() != 0,
    );
  }

  /// Wire shape for the client `CoImagingParticipant.fromJson`. [includeToken]
  /// (the caller is this very rig, on its own JOIN response) additionally emits
  /// the membership token the rig presents on later contributions.
  Map<String, Object?> toJson({
    bool includeAccountId = false,
    bool includeToken = false,
    String? displayName,
  }) => <String, Object?>{
    'sessionId': sessionId,
    if (includeAccountId) 'accountId': accountId,
    if (displayName != null) 'displayName': displayName,
    'rigId': rigId,
    'role': role,
    if (includeToken) 'membershipToken': membershipToken,
    'framingOffsetIndex': framingOffsetIndex,
    'framingOffsetRaArcsec': framingOffsetRaArcsec,
    'framingOffsetDecArcsec': framingOffsetDecArcsec,
    'contributedFrames': contributedFrames,
    'contributedIntegrationSeconds': contributedIntegrationSeconds,
    'active': isActive,
    'joinedAt': joinedAt,
    'updatedAt': updatedAt,
  };
}

/// The combined accounting returned by [CoImagingService.recordContribution].
class CoImagingAccounting {
  const CoImagingAccounting({
    required this.sessionId,
    required this.combinedFrames,
    required this.combinedIntegrationSeconds,
    required this.participantCount,
  });

  final String sessionId;
  final int combinedFrames;
  final double combinedIntegrationSeconds;
  final int participantCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': sessionId,
    'combinedFrames': combinedFrames,
    'combinedIntegrationSeconds': combinedIntegrationSeconds,
    'participantCount': participantCount,
  };
}

/// The longitude-baton state of a session (who is actively imaging now).
class CoImagingBatonState {
  const CoImagingBatonState({
    required this.sessionId,
    required this.holder,
    required this.expiresAt,
  });

  final String sessionId;
  final String? holder;
  final DateTime? expiresAt;

  /// Wire shape. The raw [holder] account id is emitted only to a privileged
  /// caller; everyone else sees just whether the baton is held.
  Map<String, Object?> toJson({
    bool includeAccountId = false,
    String? holderDisplayName,
  }) => <String, Object?>{
    'sessionId': sessionId,
    'held': holder != null,
    if (includeAccountId && holder != null) 'holder': holder,
    if (holderDisplayName != null) 'holderDisplayName': holderDisplayName,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
  };
}

/// One live combined-preview event pushed to a session's subscribers. Rendered
/// onto the SSE channel via [toSseFrame].
class CoImagingPreviewEvent {
  const CoImagingPreviewEvent({
    required this.kind,
    required this.sessionId,
    required this.combinedFrames,
    required this.combinedIntegrationSeconds,
    required this.participantCount,
    required this.activeTileId,
    required this.actorRigId,
    required this.actorFramingOffsetIndex,
    required this.at,
  });

  /// `snapshot` (sent on subscribe), `combined-preview` (a fused contribution),
  /// or `participant-joined`.
  final String kind;
  final String sessionId;
  final int combinedFrames;
  final double combinedIntegrationSeconds;
  final int participantCount;

  /// The fused-tile id every participant pulls to see the combined co-add deepen.
  final int activeTileId;

  /// Provenance of the event's trigger (the rig that just contributed / joined).
  final String? actorRigId;
  final int? actorFramingOffsetIndex;
  final DateTime at;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': kind,
    'sessionId': sessionId,
    'combinedFrames': combinedFrames,
    'combinedIntegrationSeconds': combinedIntegrationSeconds,
    'participantCount': participantCount,
    'activeTileId': activeTileId,
    if (actorRigId != null && actorRigId!.isNotEmpty) 'actorRigId': actorRigId,
    if (actorFramingOffsetIndex != null)
      'actorFramingOffsetIndex': actorFramingOffsetIndex,
    'at': at.toIso8601String(),
  };

  /// The Server-Sent-Events wire frame: an `event:` line + a `data:` line of the
  /// JSON payload, terminated by the blank line that delimits an SSE message.
  String toSseFrame() => 'event: $kind\ndata: ${jsonEncode(toJson())}\n\n';
}

/// No co-imaging session with the given id exists.
class CoImagingSessionNotFound implements Exception {
  CoImagingSessionNotFound(this.sessionId);
  final String sessionId;
  @override
  String toString() => 'CoImagingSessionNotFound($sessionId)';
}

/// The session exists but is closed (no joins / contributions accepted).
class CoImagingSessionClosed implements Exception {
  CoImagingSessionClosed(this.sessionId);
  final String sessionId;
  @override
  String toString() => 'CoImagingSessionClosed($sessionId)';
}

/// The caller is not a participant of the session.
class CoImagingParticipantNotFound implements Exception {
  CoImagingParticipantNotFound(this.sessionId, this.accountId);
  final String sessionId;
  final String accountId;
  @override
  String toString() => 'CoImagingParticipantNotFound($sessionId, $accountId)';
}

/// A self-reported contribution exceeded the physically-plausible accounting
/// envelope (combined integration / frame count vs. wall-clock since join) and
/// was refused to protect the shared depth + contributor attribution from
/// forged inflation.
class CoImagingContributionRejected implements Exception {
  CoImagingContributionRejected({
    required this.sessionId,
    required this.accountId,
    required this.reason,
  });
  final String sessionId;
  final String accountId;
  final String reason;
  @override
  String toString() =>
      'CoImagingContributionRejected($sessionId, $accountId): $reason';
}

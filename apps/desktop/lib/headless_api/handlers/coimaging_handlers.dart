import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Headless API handlers for Collaborative Sky live co-imaging.
///
/// Lets an UNATTENDED rig take part in a live co-imaging session over the same
/// hub the GUI uses: discover sessions, open one (owner), JOIN one (participant)
/// and receive its assigned framing offset, report contributions to the COMBINED
/// accounting, and drive the longitude hand-off baton. The heavy fusion still
/// flows through the existing tile-contribution path; these endpoints coordinate
/// the session around it.
class CoImagingHandlers {
  final ProviderContainer container;

  CoImagingHandlers(this.container);

  CoImagingSessionService get _service =>
      container.read(coImagingSessionServiceProvider);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'CoImagingHandlers');

  /// Map a failed hub-bound service call to an HTTP response. A hub outage or
  /// upstream error is a transient SERVER-side failure, not a client mistake,
  /// so it must not surface as 400 (which a rig treats as non-retryable). The
  /// raw exception is logged but never serialized to the wire — the response
  /// carries a stable machine code and a generic message.
  /// Read the optional per-request consent pair from a request body.
  /// Both fields are optional; when either is absent the service falls back to
  /// the operator's persisted consent record.
  static (ContributionLicense?, bool?) _readConsent(
    Map<String, dynamic> payload,
  ) {
    final licenseWire = optionalString(payload, 'license');
    return (
      licenseWire == null
          ? null
          // An unrecognized token fails closed to `private`, which the consent
          // gate then refuses — never a silent widening to a shareable default.
          : ContributionLicense.fromWire(
              licenseWire,
              fallback: ContributionLicense.private,
            ),
      optionalBool(payload, 'attributionConsent'),
    );
  }

  Response _hubError(
    Object error, {
    required String code,
    required String message,
  }) {
    if (error is ConstellationException) {
      _logger.warning(
        '[coimaging] $code ($error)',
        source: 'CoImagingHandlers',
      );
      return jsonError(
        code: code,
        // Carry the hub/gate's own words: without them a caller sees only
        // "Failed to …" and cannot tell an unreachable hub from a missing
        // sharing consent from a session it already left.
        message: '$message: ${error.message}',
        statusCode: _statusForKind(error.kind),
      );
    }
    _logger.error(
      '[coimaging] $code (unexpected)',
      source: 'CoImagingHandlers',
      fields: {'error': error.toString()},
    );
    return jsonError(code: code, message: message, statusCode: 500);
  }

  static int _statusForKind(ConstellationErrorKind kind) => switch (kind) {
    ConstellationErrorKind.network => 502,
    ConstellationErrorKind.server => 503,
    ConstellationErrorKind.auth => 401,
    ConstellationErrorKind.notFound => 404,
    ConstellationErrorKind.conflict => 409,
    // The hub rejected the REQUEST (its 400/409 map to `protocol`), so this is
    // the caller's fault, not ours. Reporting 500 tells a client to retry an
    // identical request that can never succeed. Matches MosaicHandlers.
    ConstellationErrorKind.protocol => 400,
    ConstellationErrorKind.geometryMismatch => 409,
    _ => 500,
  };

  /// GET `/api/coimaging/sessions` — discover active co-imaging sessions on the
  /// configured hub (the participant's entry point).
  Future<Response> handleListSessions(Request request) async {
    _logInfo('[API] GET /api/coimaging/sessions');
    try {
      final sessions = await _service.listSessions();
      return jsonOk({'sessions': sessions.map(_sessionToJson).toList()});
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_list_failed',
        message: 'Failed to list co-imaging sessions',
      );
    }
  }

  /// GET `/api/coimaging/sessions/<sessionId>` — one session's live state
  /// (combined totals, participants, baton).
  Future<Response> handleGetSession(Request request, String sessionId) async {
    _logInfo('[API] GET /api/coimaging/sessions/$sessionId');
    if (sessionId.trim().isEmpty) {
      return jsonError(
        code: 'invalid_session_id',
        message: 'sessionId is required',
        statusCode: 400,
      );
    }
    try {
      final session = await _service.getSession(sessionId);
      return jsonOk(_sessionToJson(session));
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_get_failed',
        message: 'Failed to get co-imaging session $sessionId',
      );
    }
  }

  /// POST `/api/coimaging/sessions` — open a live co-imaging session on a target.
  /// Body: `{targetName, raDeg, decDeg, radiusDeg?, rigId?}`. The caller is the
  /// owner + anchor participant.
  Future<Response> handleCreateSession(Request request) async {
    _logInfo('[API] POST /api/coimaging/sessions');
    final payload = await readJsonObject(request);
    final targetName = requireString(payload, 'targetName');
    final raDeg = requireDouble(payload, 'raDeg');
    final decDeg = requireDouble(payload, 'decDeg');
    final radiusDeg = optionalDouble(payload, 'radiusDeg') ?? 1.5;
    final rigId = optionalString(payload, 'rigId');
    try {
      final session = await _service.createSession(
        targetName: targetName,
        raDeg: raDeg,
        decDeg: decDeg,
        radiusDeg: radiusDeg,
        rigId: rigId,
      );
      return jsonOk(_sessionToJson(session));
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_create_failed',
        message: 'Failed to open co-imaging session',
      );
    }
  }

  /// POST `/api/coimaging/sessions/<sessionId>/join` — JOIN as a rig. Body:
  /// `{rigId?, role?}`. Returns the hub-assigned framing offset + slot.
  Future<Response> handleJoinSession(Request request, String sessionId) async {
    _logInfo('[API] POST /api/coimaging/sessions/$sessionId/join');
    if (sessionId.trim().isEmpty) {
      return jsonError(
        code: 'invalid_session_id',
        message: 'sessionId is required',
        statusCode: 400,
      );
    }
    final payload = await _readOptionalBody(request);
    final rigId = optionalString(payload, 'rigId');
    final role = optionalString(payload, 'role') ?? 'contribute';
    try {
      final participant = await _service.joinSession(
        sessionId,
        rigId: rigId,
        role: role,
      );
      return jsonOk({
        'sessionId': sessionId,
        'framingOffsetIndex': participant.framingOffsetIndex,
        'framingOffsetRaArcsec': participant.framingOffsetRaArcsec,
        'framingOffsetDecArcsec': participant.framingOffsetDecArcsec,
        'role': participant.role,
      });
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_join_failed',
        message: 'Failed to join co-imaging session',
      );
    }
  }

  /// POST `/api/coimaging/sessions/<sessionId>/leave` — leave the session.
  Future<Response> handleLeaveSession(Request request, String sessionId) async {
    _logInfo('[API] POST /api/coimaging/sessions/$sessionId/leave');
    final payload = await _readOptionalBody(request);
    final rigId = optionalString(payload, 'rigId');
    try {
      final left = await _service.leaveSession(sessionId, rigId: rigId);
      return jsonOk({'sessionId': sessionId, 'left': left});
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_leave_failed',
        message: 'Failed to leave co-imaging session',
      );
    }
  }

  /// POST `/api/coimaging/sessions/<sessionId>/close` — close the session
  /// (owner/admin). Marks it closed on the hub and tears down its live preview.
  Future<Response> handleCloseSession(Request request, String sessionId) async {
    _logInfo('[API] POST /api/coimaging/sessions/$sessionId/close');
    if (sessionId.trim().isEmpty) {
      return jsonError(
        code: 'invalid_session_id',
        message: 'sessionId is required',
        statusCode: 400,
      );
    }
    try {
      final session = await _service.closeSession(sessionId);
      return jsonOk(_sessionToJson(session));
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_close_failed',
        message: 'Failed to close co-imaging session $sessionId',
      );
    }
  }

  /// POST `/api/coimaging/sessions/<sessionId>/contribute` — report this rig's
  /// frames + integration to the COMBINED accounting after folding its sub into
  /// the shared-target tile. Body: `{framesDelta, integrationSecondsDelta,
  /// rigId?, license?, attributionConsent?}`.
  ///
  /// Consent gate: the report writes this rig's license + attribution into
  /// the hub's per-participant ledger, so it only proceeds under an explicit
  /// sharing choice. The optional `{license, attributionConsent}` pair supplies
  /// that choice per-request (mirroring the mosaic panel upload); with neither,
  /// the service falls back to the operator's PERSISTED consent and fails the
  /// contribution closed when none is recorded.
  Future<Response> handleContribute(Request request, String sessionId) async {
    _logInfo('[API] POST /api/coimaging/sessions/$sessionId/contribute');
    final payload = await readJsonObject(request);
    final frames = requireInt(payload, 'framesDelta', min: 0);
    final seconds = requireDouble(payload, 'integrationSecondsDelta', min: 0);
    final rigId = optionalString(payload, 'rigId');
    final (license, attributionConsent) = _readConsent(payload);
    try {
      final acc = await _service.recordContribution(
        sessionId,
        framesDelta: frames,
        integrationSecondsDelta: seconds,
        rigId: rigId,
        license: license,
        attributionConsent: attributionConsent,
      );
      return jsonOk({
        'sessionId': acc.sessionId,
        'combinedFrames': acc.combinedFrames,
        'combinedIntegrationSeconds': acc.combinedIntegrationSeconds,
        'participantCount': acc.participantCount,
      });
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_contribute_failed',
        message: 'Failed to record co-imaging contribution',
      );
    }
  }

  /// GET `/api/coimaging/sessions/<sessionId>/framing-offset` — the (raDeg,
  /// decDeg) pointing delta this unattended rig must add to the session centre so
  /// it frames its assigned coverage tile instead of stacking identically.
  /// The centering routine adds this to its recenter target.
  Future<Response> handleFramingOffset(
    Request request,
    String sessionId,
  ) async {
    _logInfo('[API] GET /api/coimaging/sessions/$sessionId/framing-offset');
    if (sessionId.trim().isEmpty) {
      return jsonError(
        code: 'invalid_session_id',
        message: 'sessionId is required',
        statusCode: 400,
      );
    }
    try {
      final offset = await _service.framingOffsetFor(sessionId);
      if (offset == null) {
        return jsonError(
          code: 'coimaging_not_a_member',
          message: 'this rig is not an active member of session $sessionId',
          statusCode: 404,
        );
      }
      return jsonOk({
        'sessionId': sessionId,
        'raDeg': offset.raDeg,
        'decDeg': offset.decDeg,
      });
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_framing_offset_failed',
        message: 'Failed to resolve framing offset for $sessionId',
      );
    }
  }

  /// POST `/api/coimaging/sessions/<sessionId>/sub-complete` — the unattended
  /// capture-loop hook: fold a freshly completed sub's additive sum
  /// into the shared-target tile, advance the COMBINED accounting, and tag the
  /// tile with the session — in that order, with the fusion-failure guard so the
  /// appliance never claims depth the fusion did not receive. Body:
  /// `{exposureSeconds, framesDelta?, rigId?, radiusDeg?, license?,
  /// attributionConsent?}` — the optional consent pair carries the same
  /// per-request sharing choice as `/contribute`.
  Future<Response> handleSubComplete(Request request, String sessionId) async {
    _logInfo('[API] POST /api/coimaging/sessions/$sessionId/sub-complete');
    final payload = await readJsonObject(request);
    final exposureSeconds = requireDouble(payload, 'exposureSeconds', min: 0);
    final framesDelta = optionalInt(payload, 'framesDelta') ?? 1;
    final radiusDeg = optionalDouble(payload, 'radiusDeg') ?? 1.5;
    final rigId = optionalString(payload, 'rigId');
    final (license, attributionConsent) = _readConsent(payload);
    try {
      final acc = await _service.recordCompletedSub(
        sessionId,
        exposureSeconds: exposureSeconds,
        framesDelta: framesDelta,
        radiusDeg: radiusDeg,
        rigId: rigId,
        license: license,
        attributionConsent: attributionConsent,
      );
      if (acc == null) {
        return jsonOk({
          'sessionId': sessionId,
          'fused': false,
          'message': 'fusion deepened nothing; accounting not advanced',
        });
      }
      return jsonOk({
        'sessionId': acc.sessionId,
        'fused': true,
        'combinedFrames': acc.combinedFrames,
        'combinedIntegrationSeconds': acc.combinedIntegrationSeconds,
        'participantCount': acc.participantCount,
      });
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_sub_complete_failed',
        message: 'Failed to contribute completed sub to $sessionId',
      );
    }
  }

  /// POST `/api/coimaging/sessions/<sessionId>/baton/auto` — one altitude-driven
  /// longitude-baton tick: claim the baton when the target is up at
  /// this rig's site, release it when it sets, so an unattended appliance hands
  /// the night east without operator input. Body:
  /// `{latitudeDeg, longitudeDeg, altitudeFloorDeg?}`.
  Future<Response> handleAutoBaton(Request request, String sessionId) async {
    _logInfo('[API] POST /api/coimaging/sessions/$sessionId/baton/auto');
    final payload = await readJsonObject(request);
    final latitudeDeg = requireDouble(payload, 'latitudeDeg');
    final longitudeDeg = requireDouble(payload, 'longitudeDeg');
    final floor = optionalDouble(payload, 'altitudeFloorDeg');
    try {
      final decision = await _service.evaluateBaton(
        sessionId,
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
        altitudeFloorDeg:
            floor ?? CoImagingSessionService.defaultImagingAltitudeFloorDeg,
      );
      return jsonOk({
        'sessionId': sessionId,
        'altitudeDeg': decision.altitudeDeg,
        'aboveFloor': decision.aboveFloor,
        'holdsBaton': decision.holdsBaton,
        'released': decision.released,
        if (decision.claim?.claimToken != null)
          'claimToken': decision.claim!.claimToken,
        if (decision.claim?.expiresAt != null)
          'expiresAt': decision.claim!.expiresAt!.toUtc().toIso8601String(),
      });
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_auto_baton_failed',
        message: 'Failed to evaluate co-imaging baton for $sessionId',
      );
    }
  }

  /// POST `/api/coimaging/sessions/<sessionId>/baton/claim` — take the
  /// active-imager baton as the target rises at this site.
  Future<Response> handleClaimBaton(Request request, String sessionId) async {
    _logInfo('[API] POST /api/coimaging/sessions/$sessionId/baton/claim');
    try {
      final claim = await _service.claimBaton(sessionId);
      if (claim == null) {
        return jsonError(
          code: 'coimaging_baton_held',
          message: 'the baton is held by another site',
          statusCode: 409,
        );
      }
      return jsonOk({
        'sessionId': sessionId,
        'claimToken': claim.claimToken,
        if (claim.expiresAt != null)
          'expiresAt': claim.expiresAt!.toUtc().toIso8601String(),
      });
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_baton_claim_failed',
        message: 'Failed to claim co-imaging baton',
      );
    }
  }

  /// POST `/api/coimaging/sessions/<sessionId>/baton/release` — hand the baton
  /// east as the target sets at this site.
  Future<Response> handleReleaseBaton(Request request, String sessionId) async {
    _logInfo('[API] POST /api/coimaging/sessions/$sessionId/baton/release');
    try {
      final released = await _service.releaseBaton(sessionId);
      return jsonOk({'sessionId': sessionId, 'released': released});
    } catch (e) {
      return _hubError(
        e,
        code: 'coimaging_baton_release_failed',
        message: 'Failed to release co-imaging baton',
      );
    }
  }

  /// Read a JSON object body, tolerating an empty body (join/leave carry only
  /// optional fields). Returns an empty map for an empty/blank body.
  Future<Map<String, dynamic>> _readOptionalBody(Request request) async {
    final raw = await request.readAsString();
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Map<String, Object?> _sessionToJson(CoImagingSession s) => <String, Object?>{
    'sessionId': s.sessionId,
    if (s.ownerDisplayName != null) 'ownerDisplayName': s.ownerDisplayName,
    'targetName': s.targetName,
    'centerRaDeg': s.centerRaDeg,
    'centerDecDeg': s.centerDecDeg,
    'status': s.status,
    'combinedFrames': s.combinedFrames,
    'combinedIntegrationSeconds': s.combinedIntegrationSeconds,
    if (s.activeTileId != null) 'activeTileId': s.activeTileId,
    if (s.batonHolderDisplayName != null)
      'batonHolderDisplayName': s.batonHolderDisplayName,
    'participants': s.participants
        .map(
          (p) => <String, Object?>{
            if (p.displayName != null) 'displayName': p.displayName,
            'rigId': p.rigId,
            'role': p.role,
            'framingOffsetIndex': p.framingOffsetIndex,
            'framingOffsetRaArcsec': p.framingOffsetRaArcsec,
            'framingOffsetDecArcsec': p.framingOffsetDecArcsec,
            'contributedFrames': p.contributedFrames,
            'contributedIntegrationSeconds': p.contributedIntegrationSeconds,
            'active': p.active,
          },
        )
        .toList(),
  };
}

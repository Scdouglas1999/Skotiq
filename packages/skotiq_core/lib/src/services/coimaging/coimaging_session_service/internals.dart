part of '../coimaging_session_service.dart';

extension _CoImagingSessionInternals on CoImagingSessionService {
  Future<ConstellationClient> _requireClient() async {
    final creds = await _credentialsResolver();
    if (creds == null) {
      throw const ConstellationException(
        'No Constellation hub is configured. Sign in to a hub first.',
        kind: ConstellationErrorKind.auth,
      );
    }
    return _clientFactory(creds);
  }

  /// Resolve the effective contribution consent for an egress: an explicit
  /// [license] + [attributionConsent] (already-resolved caller) wins; otherwise
  /// the injected persisted record is consulted. Returns null ONLY when a
  /// consent resolver is wired and no record exists — the FAIL-CLOSED signal.
  /// Wirings without a resolver fall back to a ccBy + credited default so the
  /// coordination layer stays testable.
  Future<({ContributionLicense license, bool attributionConsent})?>
  _resolveContributionConsent({
    ContributionLicense? license,
    bool? attributionConsent,
  }) async {
    if (license != null && attributionConsent != null) {
      return (license: license, attributionConsent: attributionConsent);
    }
    final resolver = _consentResolver;
    if (resolver == null) {
      // Legacy/test wiring: no persisted consent surface to gate against.
      return (
        license: license ?? ContributionLicense.ccBy,
        attributionConsent: attributionConsent ?? true,
      );
    }
    return resolver();
  }

  // Internals

  /// The session target's sky centre (degrees): from the durable membership when
  /// it carries coordinates, else from a single live [getSession] (self-healing
  /// the membership row so later offline calls are cheap).
  Future<({double raDeg, double decDeg})> _sessionCenter(
    String sessionId,
  ) async {
    final creds = await _credentialsResolver();
    final hubKey = creds == null ? null : constellationHubKey(creds.hubBaseUrl);
    if (hubKey != null) {
      final row = await _sessions.getSession(hubKey, sessionId);
      if (row?.targetRaDeg != null && row?.targetDecDeg != null) {
        return (raDeg: row!.targetRaDeg!, decDeg: row.targetDecDeg!);
      }
    }
    final session = await getSession(sessionId);
    if (hubKey != null) {
      await _sessions.upsertMembership(
        hubKey,
        sessionId,
        targetName: session.targetName,
        targetRaDeg: session.centerRaDeg,
        targetDecDeg: session.centerDecDeg,
      );
    }
    return (raDeg: session.centerRaDeg, decDeg: session.centerDecDeg);
  }

  Future<void> _persistMembership(
    ConstellationCredentials? creds,
    CoImagingSession session, {
    String? rigId,
  }) async {
    if (creds == null) return;
    // The owner's own participant row carries the membership token + offset.
    CoImagingParticipant? self;
    for (final p in session.participants) {
      if (p.membershipToken != null && p.membershipToken!.isNotEmpty) {
        if (rigId == null || rigId.isEmpty || p.rigId == rigId) {
          self = p;
          break;
        }
      }
    }
    await _sessions.upsertMembership(
      constellationHubKey(creds.hubBaseUrl),
      session.sessionId,
      targetName: session.targetName,
      targetRaDeg: session.centerRaDeg,
      targetDecDeg: session.centerDecDeg,
      role: self?.role ?? 'admin',
      claimToken: self?.membershipToken,
      framingOffsetIndex: self?.framingOffsetIndex ?? 0,
      framingOffsetRaArcsec: self?.framingOffsetRaArcsec ?? 0,
      framingOffsetDecArcsec: self?.framingOffsetDecArcsec ?? 0,
      active: true,
    );
  }
}

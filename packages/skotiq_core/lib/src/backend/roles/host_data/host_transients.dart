import 'dart:typed_data';

/// Transient discoveries on a linked imaging host: First Light candidates, and the alert settings and per-alert states.
abstract interface class HostTransients {
  /// Fetch the appliance's First Light transient detections (newest-first).
  /// Pass [sessionId] for a single session, or null for the across-sessions
  /// feed. The difference pipeline runs on the host, so a remote client reads
  /// its persisted candidates here instead of the local DB. Callers
  /// reconstruct rows via `transientDetectionFromWireJson`.
  Future<List<Map<String, dynamic>>> getFirstLightCandidates({int? sessionId});

  /// Fetch a REAL per-detection pixel postage stamp (PNG bytes) for detection
  /// [id], [stage] = `template` | `science` | `residual`. The host re-derives the
  /// deterministic crop filename from the persisted detection row and streams the
  /// PNG the difference pass wrote, so a companion tablet sees the actual pixels
  /// around the candidate — not a host-local file path. Maps to the advertised
  /// `GET /api/firstlight/<id>/crops/<stage>`.
  Future<Uint8List> getFirstLightCrop(int id, String stage);

  /// Fetch the host's cross-night history for one transient: every persisted
  /// detection within [radiusDeg] of ([raDeg], [decDeg]), oldest-first. Backs
  /// the multi-night light-curve detail view so the same source seen over
  /// several nights groups into one Δmag-vs-time history on a slave too.
  Future<List<Map<String, dynamic>>> getFirstLightHistory({
    required double raDeg,
    required double decDeg,
    double radiusDeg = 0.02,
  });

  /// Mark a First Light detection reviewed (confirmed) on the host.
  Future<void> reviewFirstLightCandidate(int id);

  /// Dismiss a First Light detection as a triaged artefact on the host so the
  /// next difference scan suppresses the same position.
  Future<void> dismissFirstLightCandidate(int id);

  /// Get the imaging host's durable per-alert action states.
  Future<Map<String, dynamic>> getTransientStates();

  /// Persist an alert action state on the imaging host.
  Future<void> updateTransientState(String transientId, String state);

  /// Remove all durable alert action states on the imaging host.
  Future<void> clearTransientStates();

  /// Get transient settings
  Future<Map<String, dynamic>> getTransientSettings();

  /// Update transient settings
  Future<void> updateTransientSettings(Map<String, dynamic> settings);

  /// Get active transient alerts
  Future<Map<String, dynamic>> getActiveTransients();
}

part of '../network_backend.dart';

/// Transient alerts and first-light candidates kept by a linked imaging host.
mixin HostTransients on NetworkBackendTransport {
  /// Ask the host to generate an ingestible AAVSO Extended File Format report
  /// for detection [id] and return the bytes (the slave saves / share-sheets
  /// them — there is no per-observer AAVSO upload API; WebObs upload is manual).
  /// [magZeroPoint] is required (a calibrated magnitude); the host returns 400
  /// if unavailable.
  Future<Uint8List> exportFirstLightAavso(
    int id, {
    required double magZeroPoint,
    String? standardBand,
  }) async {
    return _postRawBytes(
      FirstLightApi.exportAavso,
      path: {'id': id},
      body: {
        'magZeroPoint': magZeroPoint,
        if (standardBand != null && standardBand.isNotEmpty)
          'standardBand': standardBand,
      },
    );
  }

  /// Ask the host to generate an MPC ADES PSV astrometry report for detection
  /// [id] and return the bytes (MPC submission is via the web form / email).
  Future<Uint8List> exportFirstLightMpc(int id) async {
    return _postRawBytes(
      FirstLightApi.exportMpc,
      path: {'id': id},
      body: const {},
    );
  }

  /// Trigger a REAL TNS submission for detection [id] ON THE HOST. The host
  /// holds the bot credentials + api key (the api key never crosses the wire);
  /// the slave only triggers and surfaces the result. Returns the host's
  /// `{success, atName?, reportId?, message}` payload.
  Future<Map<String, dynamic>> submitFirstLightToTns(int id) async {
    return _post(FirstLightApi.submitTns, path: {'id': id});
  }

  // First Light — difference-imaging transient discovery (read + triage)

  /// Fetch the appliance's First Light transient detections (newest-first).
  /// Pass [sessionId] for a single session, or null for the across-sessions
  /// feed. The difference pipeline runs on the host, so a remote client reads
  /// its persisted candidates here instead of the local DB. Callers
  /// reconstruct rows via `transientDetectionFromWireJson`.
  Future<List<Map<String, dynamic>>> getFirstLightCandidates({
    int? sessionId,
  }) async {
    final json = await _get(
      FirstLightApi.getCandidates,
      query: sessionId == null ? null : {'sessionId': sessionId.toString()},
    );
    return _sessionScienceObjectList(
      json,
      'candidates',
      'GET /api/firstlight/candidates',
    );
  }

  /// Fetch a REAL per-detection pixel postage stamp (PNG bytes) for detection
  /// [id], [stage] = `template` | `science` | `residual`. The host re-derives the
  /// deterministic crop filename from the persisted detection row and streams the
  /// PNG the difference pass wrote, so a companion tablet sees the actual pixels
  /// around the candidate — not a host-local file path. Maps to the advertised
  /// `GET /api/firstlight/<id>/crops/<stage>`.
  Future<Uint8List> getFirstLightCrop(int id, String stage) {
    return _downloadBytes(
      FirstLightApi.getCrop,
      path: {'id': id, 'stage': stage},
    );
  }

  /// Fetch the host's cross-night history for one transient: every persisted
  /// detection within [radiusDeg] of ([raDeg], [decDeg]), oldest-first. Backs
  /// the multi-night light-curve detail view so the same source seen over
  /// several nights groups into one Δmag-vs-time history on a slave too.
  Future<List<Map<String, dynamic>>> getFirstLightHistory({
    required double raDeg,
    required double decDeg,
    double radiusDeg = 0.02,
  }) async {
    final json = await _get(
      FirstLightApi.getNear,
      query: {
        'ra': raDeg.toString(),
        'dec': decDeg.toString(),
        'radius': radiusDeg.toString(),
      },
    );
    return _sessionScienceObjectList(
      json,
      'detections',
      'GET /api/firstlight/near',
    );
  }

  /// Mark a First Light detection reviewed (confirmed) on the host.
  Future<void> reviewFirstLightCandidate(int id) async {
    await _post(FirstLightApi.review, path: {'id': id});
  }

  /// Dismiss a First Light detection as a triaged artefact on the host so the
  /// next difference scan suppresses the same position.
  Future<void> dismissFirstLightCandidate(int id) async {
    await _post(FirstLightApi.dismiss, path: {'id': id});
  }

  /// Get the imaging host's durable per-alert action states.
  Future<Map<String, dynamic>> getTransientStates() async {
    final response = await _get(TransientApi.getStates);
    return _sessionScienceObject(
      response,
      'states',
      'GET /api/transients/states',
    );
  }

  /// Persist an alert action state on the imaging host.
  Future<void> updateTransientState(String transientId, String state) async {
    await _post(
      TransientApi.updateState,
      path: {'id': transientId},
      body: {'state': state},
    );
  }

  /// Remove all durable alert action states on the imaging host.
  Future<void> clearTransientStates() async {
    await _delete(TransientApi.clearStates);
  }

  Future<Map<String, dynamic>> getTransientSettings() async {
    final response = await _get(TransientApi.getSettings);
    return _sessionScienceObject(
      response,
      'settings',
      'GET /api/transients/settings',
    );
  }

  Future<void> updateTransientSettings(Map<String, dynamic> settings) async {
    await _post(TransientApi.updateSettings, body: settings);
  }

  Future<Map<String, dynamic>> getActiveTransients() async {
    final response = await _get(TransientApi.getActiveTransients);
    return {
      ...response,
      'alerts': _sessionScienceObjectList(
        response,
        'alerts',
        'GET /api/transients',
      ),
    };
  }
}

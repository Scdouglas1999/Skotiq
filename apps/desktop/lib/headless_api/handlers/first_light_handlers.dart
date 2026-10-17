import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for Pillar B ("First Light") — the difference-imaging transient
/// discovery surface.
///
/// The difference pipeline and its persistence run on the appliance/desktop
/// (where solved frames land); a remote tablet/desktop cannot watch that DB, so
/// these endpoints expose the persisted [TransientDetectionRow] feed over REST
/// and let a remote client triage (review / dismiss) a candidate. Reads default
/// to `view` scope, the triage mutations to `control`, per `route_metadata`.
class FirstLightHandlers {
  final ProviderContainer container;

  FirstLightHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'FirstLightHandlers');

  TransientDetectionsDao get _dao =>
      container.read(transientDetectionsDaoProvider);

  /// Parse a `<id>` path segment as a detection id, or reject with the 400
  /// envelope every First Light route shares: `BadRequestError(field: 'id',
  /// expected: 'integer', message: 'detection id must be an integer')`, which
  /// the error-translation middleware renders on the wire.
  int _requireDetectionId(String id) {
    final detectionId = int.tryParse(id);
    if (detectionId == null) {
      throw BadRequestError(
        field: 'id',
        expected: 'integer',
        message: 'detection id must be an integer',
      );
    }
    return detectionId;
  }

  /// POST `/api/firstlight/<id>/submit/tns` — REAL TNS bot-API submission.
  ///
  /// The host holds the credentials (non-secret in ScienceSettings, the secret
  /// api key in the keyring). A slave only triggers this; the api key never
  /// crosses the wire. Returns the submission result JSON.
  Future<Response> handleSubmitTns(Request request, String id) async {
    final detectionId = _requireDetectionId(id);
    _logInfo('[API] POST /api/firstlight/$detectionId/submit/tns');

    final detection = await _dao.detectionById(detectionId);
    if (detection == null) {
      return jsonNotFound('No transient detection with id $detectionId');
    }

    final settings = await container.read(scienceSettingsProvider.future);
    final apiKey = await container
        .read(secretsStoreProvider)
        .read(SecretField.tnsApiKey);
    final creds = TnsCredentials(
      botId: settings.tnsBotId,
      botName: settings.tnsBotName,
      reportingGroupId: settings.tnsReportingGroupId,
      dataSourceId: settings.tnsDataSourceId,
      reporterName: settings.tnsReporterName.isNotEmpty
          ? settings.tnsReporterName
          : settings.observerName,
      apiKey: apiKey,
      useSandbox: settings.tnsUseSandbox,
    );
    if (!creds.isComplete) {
      return jsonBadRequest({
        'success': false,
        'message':
            'TNS credentials are not configured on the host. Set the bot '
            'id/name/group/source, reporter, and api key in '
            'Settings > Science on the rig host.',
      });
    }

    final result = await container
        .read(transientSubmissionServiceProvider)
        .submitToTns(detection: detection, creds: creds);
    return jsonOk({
      'success': result.success,
      'atName': result.atName,
      'reportId': result.reportId,
      'message': result.message,
    });
  }

  /// POST `/api/firstlight/<id>/export/aavso` — generate an ingestible AAVSO
  /// Extended File Format report and return it as a downloadable attachment.
  ///
  /// Requires a photometric zeropoint (passed in the body) and the host's
  /// observer code; without a calibrated magnitude the AAVSO format is
  /// disabled (returns 400), never a `na`-stuffed DIF row.
  Future<Response> handleExportAavso(Request request, String id) async {
    final detectionId = _requireDetectionId(id);
    _logInfo('[API] POST /api/firstlight/$detectionId/export/aavso');

    final detection = await _dao.detectionById(detectionId);
    if (detection == null) {
      return jsonNotFound('No transient detection with id $detectionId');
    }
    final payload = await readJsonObject(request);
    final magZeroPoint = (payload['magZeroPoint'] as num?)?.toDouble();
    final standardBand = optionalString(payload, 'standardBand');

    final settings = await container.read(scienceSettingsProvider.future);
    final reports = TransientReportService();
    final reason = reports.aavsoDisabledReason(
      detection,
      observerCode: settings.aavsoObserverCode,
      magZeroPoint: magZeroPoint,
    );
    if (reason != null) {
      return jsonBadRequest({'error': reason});
    }

    final content = reports.generateAavsoReport(
      detection: detection,
      observerCode: settings.aavsoObserverCode,
      magZeroPoint: magZeroPoint!,
      standardBand: standardBand,
    );
    return attachmentResponse(
      content,
      fileName: 'aavso_transient_$detectionId.txt',
      contentType: 'text/plain; charset=utf-8',
    );
  }

  /// POST `/api/firstlight/<id>/export/mpc` — generate an MPC ADES PSV
  /// astrometry report and return it as a downloadable attachment. Requires the
  /// host's 3-char observatory code.
  Future<Response> handleExportMpc(Request request, String id) async {
    final detectionId = _requireDetectionId(id);
    _logInfo('[API] POST /api/firstlight/$detectionId/export/mpc');

    final detection = await _dao.detectionById(detectionId);
    if (detection == null) {
      return jsonNotFound('No transient detection with id $detectionId');
    }
    final settings = await container.read(scienceSettingsProvider.future);
    final reports = TransientReportService();
    if (!reports.mpcAdesAvailable(
      observatoryCode: settings.mpcObservatoryCode,
    )) {
      return jsonBadRequest({
        'error':
            'Set your 3-character MPC observatory code in Settings > Science '
            'on the host first.',
      });
    }

    final content = reports.generateMpcAdesPsv(
      detection: detection,
      observatoryCode: settings.mpcObservatoryCode,
      observerName: settings.observerName,
      astrometricCatalog: settings.mpcAstrometricCatalog,
    );
    return attachmentResponse(
      content,
      fileName: 'mpc_ades_transient_$detectionId.psv',
      contentType: 'text/plain; charset=utf-8',
    );
  }

  /// Default page size for the across-sessions REST feed — the most-recent
  /// [_defaultCandidateLimit] detections, newest-first. A heavy multi-season
  /// run accumulates tens of thousands of rows, so an unbounded read would
  /// ship the whole all-time log on every poll. `offset`/`limit` page deeper
  /// on demand.
  static const int _defaultCandidateLimit = 200;
  static const int _maxCandidateLimit = 1000;

  /// GET `/api/firstlight/candidates?sessionId=&limit=&offset=` — newest-first
  /// transient detections. `sessionId` is optional; omit it for the
  /// across-sessions feed the standalone gallery and the export hub read.
  ///
  /// The across-sessions feed is **bounded** to the most-recent `limit`
  /// (default [_defaultCandidateLimit], capped at [_maxCandidateLimit]) so a
  /// poll is an index range over `idx_transient_detections_detected`, not a
  /// full sort of all history. `offset` pages older history on demand. A
  /// `sessionId` read stays scoped to one session (already bounded in practice).
  Future<Response> handleGetCandidates(Request request) async {
    final params = request.url.queryParameters;
    final raw = params['sessionId'];
    final limit = _boundedLimit(params['limit']);
    final offset = _nonNegativeOffset(params['offset']);
    _logInfo(
      '[API] GET /api/firstlight/candidates'
      '${raw == null ? '' : '?sessionId=$raw'}',
    );

    final List<TransientDetectionRow> rows;
    if (raw == null || raw.isEmpty) {
      rows = await _dao.recentDetections(limit: limit, offset: offset);
    } else {
      final sessionId = int.tryParse(raw);
      if (sessionId == null) {
        throw BadRequestError(
          field: 'sessionId',
          expected: 'integer',
          message: 'sessionId query parameter must be an integer when present',
        );
      }
      rows = await _dao.detectionsForSession(sessionId);
    }

    return jsonOk({
      'candidates': rows.map(_rowToWireJson).toList(),
      'unnamedCount': rows.where((r) => r.catalogMatch == null).length,
      'limit': limit,
      'offset': offset,
    });
  }

  /// Largest cross-night match radius a client may request, in degrees. Bounds
  /// the bounding-box scan and keeps an unrelated source from grouping in.
  static const double _maxNearRadiusDeg = 0.5;

  /// GET `/api/firstlight/near?ra=&dec=&radius=` — the cross-night history of a
  /// single transient: every persisted detection within `radius` degrees of
  /// (`ra`, `dec`), oldest-first. Backs the multi-night light-curve detail view
  /// so a slave groups the same source across nights instead of showing N
  /// unrelated cards. `ra`/`dec` are decimal degrees; `radius` defaults to
  /// 0.02° (~72") and is capped at [_maxNearRadiusDeg].
  Future<Response> handleGetNear(Request request) async {
    // ra/dec are required decimal degrees and must be finite and physical
    // (RA 0..360, Dec -90..90); radius is optional (default 0.02°). Validate
    // before the DAO read so a malformed request does no work.
    final params = request.url.queryParameters;
    final ra = requireQueryDouble(params, 'ra', min: 0, max: 360);
    final dec = requireQueryDouble(params, 'dec', min: -90, max: 90);

    // radius: absent/empty → 0.02° default. A supplied value must be a finite
    // positive number — a malformed / NaN / non-positive radius is a 400 rather
    // than silently becoming 0.02. A documented over-max value is still capped.
    final radiusRaw = params['radius'];
    final double radius;
    if (radiusRaw == null || radiusRaw.isEmpty) {
      radius = 0.02;
    } else {
      final parsed = double.tryParse(radiusRaw);
      if (parsed == null || !parsed.isFinite || parsed <= 0) {
        throw BadRequestError(
          field: 'radius',
          expected: 'positive number',
          message: 'radius must be a finite positive number (degrees)',
        );
      }
      radius = parsed > _maxNearRadiusDeg ? _maxNearRadiusDeg : parsed;
    }
    _logInfo('[API] GET /api/firstlight/near?ra=$ra&dec=$dec&radius=$radius');

    final rows = await _dao.detectionsNear(ra, dec, radiusDeg: radius);
    return jsonOk({
      'detections': rows.map(_rowToWireJson).toList(),
      'count': rows.length,
    });
  }

  /// Parse + clamp the `limit` query param to `[1, _maxCandidateLimit]`,
  /// defaulting to [_defaultCandidateLimit] when absent or unparseable.
  int _boundedLimit(String? raw) {
    if (raw == null || raw.isEmpty) return _defaultCandidateLimit;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) return _defaultCandidateLimit;
    return parsed > _maxCandidateLimit ? _maxCandidateLimit : parsed;
  }

  /// Parse the `offset` query param, flooring at 0.
  int _nonNegativeOffset(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) return 0;
    return parsed;
  }

  /// Crop stages the difference pass writes a real-pixel postage stamp for.
  static const _cropStages = {'template', 'science', 'residual'};

  /// GET `/api/firstlight/<id>/crops/<stage>` — the REAL per-detection pixel
  /// postage stamp (`template` | `science` | `residual`) the difference pass
  /// wrote, as PNG bytes. The host re-derives the deterministic crop filename
  /// from the persisted row (tile id + sky position) — the same key native used —
  /// so a companion tablet renders the actual pixels around the candidate via
  /// `Image.memory` instead of a schematic. 404 when the stamp is absent (an
  /// older detection from before crops were captured, or a scan that produced no
  /// crop) so the client falls back to the schematic.
  Future<Response> handleGetCrop(
    Request request,
    String id,
    String stage,
  ) async {
    final detectionId = _requireDetectionId(id);
    if (!_cropStages.contains(stage)) {
      throw BadRequestError(
        field: 'stage',
        expected: 'template | science | residual',
        message: 'unknown crop stage "$stage"',
      );
    }
    _logInfo('[API] GET /api/firstlight/$detectionId/crops/$stage');

    final detection = await _dao.detectionById(detectionId);
    if (detection == null) {
      return jsonNotFound('No transient detection with id $detectionId');
    }

    final atlasRoot = await defaultAtlasRoot();
    final name = firstLightCropName(
      tileId: detection.tileId,
      raDeg: detection.raDeg,
      decDeg: detection.decDeg,
      stage: stage,
    );
    final file = File('${firstLightCropDir(atlasRoot)}/$name');
    if (!await file.exists()) {
      return jsonNotFound(
        'No $stage crop for detection $detectionId (not captured)',
      );
    }
    final bytes = await file.readAsBytes();
    return contentResponse(
      bytes,
      contentType: 'image/png',
      contentLength: bytes.length,
      headers: const {'cache-control': 'public, max-age=86400'},
    );
  }

  /// POST `/api/firstlight/<id>/review` — mark a detection reviewed (confirmed).
  Future<Response> handleReview(Request request, String id) async {
    final detectionId = _requireDetectionId(id);
    _logInfo('[API] POST /api/firstlight/$detectionId/review');

    final existing = await _dao.detectionById(detectionId);
    if (existing == null) {
      return jsonNotFound('No transient detection with id $detectionId');
    }
    await _dao.markReviewed(detectionId, dismissed: false);
    final updated = await _dao.detectionById(detectionId);

    return jsonOk({
      'status': 'reviewed',
      'detection': updated == null ? null : _rowToWireJson(updated),
    });
  }

  /// POST `/api/firstlight/<id>/dismiss` — flag a detection as a triaged
  /// artefact so the next difference scan suppresses the same position.
  Future<Response> handleDismiss(Request request, String id) async {
    final detectionId = _requireDetectionId(id);
    _logInfo('[API] POST /api/firstlight/$detectionId/dismiss');

    final existing = await _dao.detectionById(detectionId);
    if (existing == null) {
      return jsonNotFound('No transient detection with id $detectionId');
    }
    await _dao.markReviewed(detectionId, dismissed: true);
    final updated = await _dao.detectionById(detectionId);

    return jsonOk({
      'status': 'dismissed',
      'detection': updated == null ? null : _rowToWireJson(updated),
    });
  }

  /// Serialize a persisted detection to the wire shape the client's
  /// `transientDetectionFromWireJson` reconstructs. Field names mirror the
  /// `TransientDetections` columns so the remote feed renders identically to the
  /// local one.
  Map<String, dynamic> _rowToWireJson(TransientDetectionRow row) => {
    'id': row.id,
    'sessionId': row.sessionId,
    'capturedImageId': row.capturedImageId,
    'tileId': row.tileId,
    'detectedAt': row.detectedAt.millisecondsSinceEpoch,
    'raDeg': row.raDeg,
    'decDeg': row.decDeg,
    'residualFlux': row.residualFlux,
    'deltaMag': row.deltaMag,
    'snr': row.snr,
    'fwhm': row.fwhm,
    'eccentricity': row.eccentricity,
    'positionAngleDeg': row.positionAngleDeg,
    'kind': row.kind,
    'catalogMatch': row.catalogMatch,
    'confidence': row.confidence,
    'reviewed': row.reviewed,
    'dismissed': row.dismissed,
  };
}

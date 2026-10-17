import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for mosaic generation
class MosaicHandlers {
  final ProviderContainer container;

  MosaicHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'MosaicHandlers');

  // Generate mosaic panels

  Future<Response> handleGeneratePanels(Request request) async {
    _logInfo('[API] POST /api/mosaic/generate-panels');
    final payload = await readJsonObject(request);
    final config = _parseMosaicConfig(requireObject(payload, 'config'));

    const service = MosaicService();
    final panels = service.generatePanels(config);

    return jsonOk({'panels': panels.map((p) => _panelToJson(p)).toList()});
  }

  // Generate mosaic sequence

  Future<Response> handleGenerateSequence(Request request) async {
    _logInfo('[API] POST /api/mosaic/generate-sequence');
    final payload = await readJsonObject(request);

    final mosaicName = optionalString(payload, 'mosaicName') ?? 'Mosaic';
    final config = _parseMosaicConfig(requireObject(payload, 'config'));
    final exposure = _parseExposureSettings(requireObject(payload, 'exposure'));
    final optionsJson = optionalObject(payload, 'options');
    final options = optionsJson != null
        ? _parseSequenceOptions(optionsJson)
        : const MosaicSequenceOptions();

    const service = MosaicService();
    final nodes = service.createMosaicSequence(
      mosaicName: mosaicName,
      config: config,
      exposure: exposure,
      options: options,
    );

    // Find the root node ID
    String? rootNodeId;
    for (final entry in nodes.entries) {
      if (entry.value is InstructionSetNode) {
        final node = entry.value as InstructionSetNode;
        if (node.parentId == null) {
          rootNodeId = node.id;
          break;
        }
      }
    }

    return jsonOk({
      'sequence': {
        'name': mosaicName,
        'rootNodeId': rootNodeId,
        'nodes': nodes.map((key, node) => MapEntry(key, _nodeToJson(node))),
        'totalPanels': config.totalPanels,
        'estimatedTimeSecs': service.estimateMosaicTime(config, exposure),
      },
    });
  }

  // Calculate mosaic area

  Future<Response> handleCalculateArea(Request request) async {
    _logInfo('[API] POST /api/mosaic/calculate-area');
    final payload = await readJsonObject(request);
    final config = _parseMosaicConfig(requireObject(payload, 'config'));

    const service = MosaicService();
    final area = service.calculateMosaicArea(config);

    return jsonOk({
      'areaSquareDegrees': area,
      'totalPanels': config.totalPanels,
    });
  }

  // Validate mosaic configuration

  Future<Response> handleValidateMosaic(Request request) async {
    _logInfo('[API] POST /api/mosaic/validate');
    final payload = await readJsonObject(request);
    final config = _parseMosaicConfig(requireObject(payload, 'config'));

    const service = MosaicService();
    final validation = service.validateMosaic(config);

    return jsonOk({
      'isValid': validation.isValid,
      'errors': validation.errors,
      'warnings': validation.warnings,
    });
  }

  // Estimate mosaic time

  Future<Response> handleEstimateTime(Request request) async {
    _logInfo('[API] POST /api/mosaic/estimate-time');
    final payload = await readJsonObject(request);

    final config = _parseMosaicConfig(requireObject(payload, 'config'));
    final exposure = _parseExposureSettings(requireObject(payload, 'exposure'));
    final overheadPerPanel =
        optionalDouble(payload, 'overheadPerPanelSecs') ?? 60.0;

    const service = MosaicService();
    final timeSecs = service.estimateMosaicTime(
      config,
      exposure,
      overheadPerPanelSecs: overheadPerPanel,
    );

    return jsonOk({
      'estimatedTimeSecs': timeSecs,
      'estimatedTimeHours': timeSecs / 3600,
      'totalPanels': config.totalPanels,
    });
  }

  Future<Response> handleRecommendExposure(Request request) async {
    _logInfo('[API] GET /api/mosaic/recommended-exposure');
    final context = await container.read(
      smartNightExposureContextProvider.future,
    );
    final exposure = smartNightMosaicExposureSettings(context);
    final recommendation = context?.recommendForFilter(exposure.filterName);

    return jsonOk({
      'exposureSeconds': exposure.exposureSeconds,
      'exposuresPerPanel': exposure.exposuresPerPanel,
      'filterName': exposure.filterName,
      'binning': exposure.binning,
      'source': context == null ? 'fallback' : 'smart_night',
      if (recommendation != null) 'rationale': recommendation.rationale,
      if (recommendation != null)
        'caveats': [...context!.caveats, ...recommendation.caveats],
    });
  }

  // Collaborative Sky mosaics — let an unattended rig drive the whole
  // distributed flow (publish/claim/upload/assemble) over the hub.

  CollaborativeMosaicService get _collab =>
      container.read(collaborativeMosaicServiceProvider);

  /// Map a failure from a collaborative-hub service call to a wire error.
  /// Client/validation faults stay 4xx; a hub that is offline or returns an
  /// upstream 5xx surfaces as 5xx so the remote client can distinguish
  /// "fix your request" from "hub unavailable, retry".
  Response _collabError({
    required String code,
    required String message,
    required Object error,
  }) {
    return jsonError(
      code: code,
      message: '$message: $error',
      statusCode: _collabStatusFor(error),
    );
  }

  int _collabStatusFor(Object error) {
    if (error is ArgumentError) return 400;
    // A StateError out of the collaborative services is always a PRECONDITION
    // the caller can act on — "not published to a hub", "no integrated master
    // to upload", "not plate-solved", "only the owner may assemble". Reporting
    // 500 tells a remote client the appliance is broken and invites a blind
    // retry, when the remedy is on the caller's side.
    if (error is StateError) return 409;
    if (error is ConstellationException) {
      return switch (error.kind) {
        // Same meanings as CoImagingHandlers / CalibrationLibraryHandlers —
        // one cause must not answer three codes across the pillars.
        // No answer from the hub at all — this appliance is the gateway.
        ConstellationErrorKind.network => 502,
        // The hub answered, but is itself unhealthy; retry later.
        ConstellationErrorKind.server => 503,
        ConstellationErrorKind.conflict => 409,
        ConstellationErrorKind.notFound => 404,
        // Not signed in / no hub configured is a client precondition, not an
        // upstream-gateway failure — return 401 so clients prompt a sign-in
        // instead of retrying a 5xx as transient (matches CoImagingHandlers).
        ConstellationErrorKind.auth => 401,
        // A geometry mismatch is semantically-invalid client data, not a server
        // fault — surface it as a conflict rather than a generic 502.
        ConstellationErrorKind.geometryMismatch => 409,
        // The hub rejected the request itself — the caller must change it.
        ConstellationErrorKind.protocol => 400,
        _ => error.statusCode ?? 502,
      };
    }
    return 500;
  }

  /// POST `/api/mosaic/projects/<projectId>/publish` — publish a durable
  /// panel grid to the hub as a claimable collaborative mosaic.
  Future<Response> handlePublishCollaborative(
    Request request,
    String projectId,
  ) async {
    _logInfo('[API] POST /api/mosaic/projects/$projectId/publish');
    final id = int.tryParse(projectId);
    if (id == null) {
      return jsonError(
        code: 'invalid_project_id',
        message: 'projectId must be an integer',
        statusCode: 400,
      );
    }
    try {
      final mosaic = await _collab.publishProject(id);
      return jsonOk({
        'mosaicId': mosaic.mosaicId,
        'status': mosaic.status,
        'rows': mosaic.rows,
        'cols': mosaic.cols,
        'panels': mosaic.panels.length,
      });
    } catch (e) {
      return _collabError(
        code: 'mosaic_publish_failed',
        message: 'Failed to publish mosaic',
        error: e,
      );
    }
  }

  /// POST `/api/mosaic/projects/<projectId>/panels/<panelIndex>/claim` — claim
  /// a panel of the published mosaic via the hub baton.
  Future<Response> handleClaimPanel(
    Request request,
    String projectId,
    String panelIndex,
  ) async {
    _logInfo(
      '[API] POST /api/mosaic/projects/$projectId/panels/$panelIndex/claim',
    );
    final id = int.tryParse(projectId);
    final idx = int.tryParse(panelIndex);
    if (id == null || idx == null) {
      return jsonError(
        code: 'invalid_params',
        message: 'projectId and panelIndex must be integers',
        statusCode: 400,
      );
    }
    try {
      final claims = await _collab.claimPanels(id, [idx]);
      if (claims.isEmpty) {
        return jsonError(
          code: 'mosaic_panel_held',
          message: 'panel $idx is held by another rig or already uploaded',
          statusCode: 409,
        );
      }
      final claim = claims.first;
      return jsonOk({
        'mosaicId': claim.mosaicId,
        'panelIndex': claim.panelIndex,
        'claimToken': claim.claimToken,
        'expiresAt': claim.expiresAt?.toUtc().toIso8601String(),
      });
    } catch (e) {
      return _collabError(
        code: 'mosaic_claim_failed',
        message: 'Failed to claim panel',
        error: e,
      );
    }
  }

  /// POST `/api/mosaic/projects/<projectId>/panels/<panelIndex>/force-release`
  /// — owner/admin eviction of a squatting claim or a poisoned upload the
  /// per-account release cannot recover. Resets the panel to `pending` on the
  /// hub so a fresh rig can take the slot; the hub enforces that only the mosaic
  /// owner or an admin may do this (403 otherwise), and 404 when nothing was
  /// held.
  Future<Response> handleForceReleasePanel(
    Request request,
    String projectId,
    String panelIndex,
  ) async {
    _logInfo(
      '[API] POST /api/mosaic/projects/$projectId/panels/$panelIndex/'
      'force-release',
    );
    final id = int.tryParse(projectId);
    final idx = int.tryParse(panelIndex);
    if (id == null || idx == null) {
      return jsonError(
        code: 'invalid_params',
        message: 'projectId and panelIndex must be integers',
        statusCode: 400,
      );
    }
    try {
      final released = await _collab.forceReleasePanel(id, idx);
      return jsonOk({'panelIndex': idx, 'released': released});
    } catch (e) {
      return jsonError(
        code: 'mosaic_force_release_failed',
        message: 'Failed to force-release panel: $e',
        statusCode: 400,
      );
    }
  }

  /// POST `/api/mosaic/projects/<projectId>/panels/<panelIndex>/upload` —
  /// upload the claimed panel's locally-integrated master FITS to the hub.
  ///
  /// Consent gate: a panel master leaves the device only under an explicit
  /// sharing license + attribution choice. The optional body
  /// `{"license": "cc-by", "attributionConsent": true}` supplies that choice
  /// per-request; with no body the service falls back to the operator's
  /// PERSISTED mosaic-upload consent and fails the upload closed when none is
  /// recorded (rather than defaulting to a silent ccBy).
  Future<Response> handleUploadPanel(
    Request request,
    String projectId,
    String panelIndex,
  ) async {
    _logInfo(
      '[API] POST /api/mosaic/projects/$projectId/panels/$panelIndex/upload',
    );
    final id = int.tryParse(projectId);
    final idx = int.tryParse(panelIndex);
    if (id == null || idx == null) {
      return jsonError(
        code: 'invalid_params',
        message: 'projectId and panelIndex must be integers',
        statusCode: 400,
      );
    }
    // Optional explicit consent: both fields, or neither (defer to the
    // persisted record). A partial body is rejected by the service.
    ContributionLicense? license;
    bool? attributionConsent;
    final rawBody = await request.readAsString();
    if (rawBody.trim().isNotEmpty) {
      final Object? decoded;
      try {
        decoded = jsonDecode(rawBody);
      } on FormatException catch (e) {
        throw BadRequestError(
          field: 'body',
          expected: 'valid_json',
          message: 'Malformed JSON: ${e.message}',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw BadRequestError(
          field: 'body',
          expected: 'json_object',
          message: 'Consent body must be a JSON object',
        );
      }
      final licenseWire = optionalString(decoded, 'license');
      if (licenseWire != null) {
        license = ContributionLicense.fromWire(
          licenseWire,
          fallback: ContributionLicense.private,
        );
      }
      attributionConsent = optionalBool(decoded, 'attributionConsent');
    }
    try {
      final panel = await _collab.uploadPanelMaster(
        id,
        idx,
        license: license,
        attributionConsent: attributionConsent,
      );
      return jsonOk({
        'panelIndex': panel.panelIndex,
        'status': panel.status,
        'uploaded': panel.uploaded,
      });
    } catch (e) {
      return _collabError(
        code: 'mosaic_upload_failed',
        message: 'Failed to upload panel master',
        error: e,
      );
    }
  }

  /// POST `/api/mosaic/projects/<projectId>/assemble` — owner-only central
  /// assembly: pull every panel master, stitch, and push the finished mosaic.
  Future<Response> handleAssembleMosaic(
    Request request,
    String projectId,
  ) async {
    _logInfo('[API] POST /api/mosaic/projects/$projectId/assemble');
    final id = int.tryParse(projectId);
    if (id == null) {
      return jsonError(
        code: 'invalid_project_id',
        message: 'projectId must be an integer',
        statusCode: 400,
      );
    }
    try {
      final outcome = await _collab.assembleMosaic(id);
      return jsonOk({
        'outputMasterId': outcome.outputMasterId,
        'panelCount': outcome.panelCount,
        'skipped': outcome.skips.length,
      });
    } catch (e) {
      return _collabError(
        code: 'mosaic_assemble_failed',
        message: 'Failed to assemble mosaic',
        error: e,
      );
    }
  }

  /// GET `/api/mosaic/collaborative` — discover open/claimable collaborative
  /// mosaics on the configured hub (the participant's entry point: pick a mosaic
  /// to join before claiming panels).
  Future<Response> handleListCollaborative(Request request) async {
    _logInfo('[API] GET /api/mosaic/collaborative');
    try {
      final mosaics = await _collab.listMosaics();
      return jsonOk({'mosaics': mosaics.map(_collabMosaicToJson).toList()});
    } catch (e) {
      return _collabError(
        code: 'mosaic_list_failed',
        message: 'Failed to list collaborative mosaics',
        error: e,
      );
    }
  }

  /// GET `/api/mosaic/collaborative/<mosaicId>` — one hub mosaic's live state
  /// (per-panel claim/upload/output), so a participant can inspect before
  /// joining or poll progress.
  Future<Response> handleGetCollaborative(
    Request request,
    String mosaicId,
  ) async {
    _logInfo('[API] GET /api/mosaic/collaborative/$mosaicId');
    if (mosaicId.trim().isEmpty) {
      return jsonError(
        code: 'invalid_mosaic_id',
        message: 'mosaicId is required',
        statusCode: 400,
      );
    }
    try {
      final mosaic = await _collab.getMosaic(mosaicId);
      return jsonOk(_collabMosaicToJson(mosaic));
    } catch (e) {
      return _collabError(
        code: 'mosaic_get_failed',
        message: 'Failed to get mosaic $mosaicId',
        error: e,
      );
    }
  }

  /// POST `/api/mosaic/projects/<projectId>/join` — link this local project to a
  /// hub mosaic as a PARTICIPANT (body: `{"hubMosaicId": "..."}`). Prerequisite
  /// for a non-owner rig: without it, claim/upload reject with "not published to
  /// a hub", so an unattended participant rig cannot contribute.
  Future<Response> handleJoinCollaborative(
    Request request,
    String projectId,
  ) async {
    _logInfo('[API] POST /api/mosaic/projects/$projectId/join');
    final id = int.tryParse(projectId);
    if (id == null) {
      return jsonError(
        code: 'invalid_project_id',
        message: 'projectId must be an integer',
        statusCode: 400,
      );
    }
    final payload = await readJsonObject(request);
    final hubMosaicId = requireString(payload, 'hubMosaicId');
    try {
      await _collab.joinAsParticipant(id, hubMosaicId);
      return jsonOk({
        'projectId': id,
        'hubMosaicId': hubMosaicId,
        'collabRole': 'participant',
      });
    } catch (e) {
      return _collabError(
        code: 'mosaic_join_failed',
        message: 'Failed to join mosaic',
        error: e,
      );
    }
  }

  /// POST `/api/mosaic/collaborative/<mosaicId>/join` — join a DISCOVERED hub
  /// mosaic as a participant, creating the local project + panel mirror the
  /// claim/upload/output flow needs, and returning its new local `projectId`.
  ///
  /// This is the participant entry point for a rig that has no local project
  /// for a peer's mosaic — i.e. every non-owner. The project-scoped
  /// `/api/mosaic/projects/<id>/join` only LINKS an existing local project, so
  /// on its own it leaves a headless participant with no way in.
  /// Idempotent: re-joining a mosaic this device already mirrors returns the
  /// existing project id and never downgrades an owner's role.
  Future<Response> handleJoinCollaborativeMosaic(
    Request request,
    String mosaicId,
  ) async {
    _logInfo('[API] POST /api/mosaic/collaborative/$mosaicId/join');
    if (mosaicId.trim().isEmpty) {
      return jsonError(
        code: 'invalid_mosaic_id',
        message: 'mosaicId is required',
        statusCode: 400,
      );
    }
    try {
      final mosaic = await _collab.getMosaic(mosaicId);
      final projectId = await _collab.joinMosaicAsParticipant(mosaic);
      return jsonOk({
        'projectId': projectId,
        'hubMosaicId': mosaicId,
        'collabRole': 'participant',
        'panels': mosaic.panels.length,
      });
    } catch (e) {
      return _collabError(
        code: 'mosaic_join_failed',
        message: 'Failed to join mosaic $mosaicId',
        error: e,
      );
    }
  }

  /// POST `/api/mosaic/projects/<projectId>/panels/<panelIndex>/release` —
  /// give a panel this rig holds back to the pool.
  ///
  /// The counterpart to `claim`: a rig that claimed a panel it cannot finish
  /// (clouded out, target set, operator changed plan) must be able to hand the
  /// slot back immediately. Without it the claim squats until its hub-side TTL
  /// expires and only the mosaic owner can recover the slot via `force-release`
  /// — which a participant, by definition, cannot call.
  Future<Response> handleReleasePanel(
    Request request,
    String projectId,
    String panelIndex,
  ) async {
    _logInfo(
      '[API] POST /api/mosaic/projects/$projectId/panels/$panelIndex/release',
    );
    final id = int.tryParse(projectId);
    final idx = int.tryParse(panelIndex);
    if (id == null || idx == null) {
      return jsonError(
        code: 'invalid_params',
        message: 'projectId and panelIndex must be integers',
        statusCode: 400,
      );
    }
    try {
      final released = await _collab.releasePanel(id, idx);
      return jsonOk({'panelIndex': idx, 'released': released});
    } catch (e) {
      return _collabError(
        code: 'mosaic_release_failed',
        message: 'Failed to release panel',
        error: e,
      );
    }
  }

  /// GET `/api/mosaic/projects/<projectId>/status` — refresh + return the
  /// project's hub-side collaborative lifecycle (the owner polling for
  /// `assembling`, or a participant polling for `complete`).
  Future<Response> handleCollaborativeStatus(
    Request request,
    String projectId,
  ) async {
    _logInfo('[API] GET /api/mosaic/projects/$projectId/status');
    final id = int.tryParse(projectId);
    if (id == null) {
      return jsonError(
        code: 'invalid_project_id',
        message: 'projectId must be an integer',
        statusCode: 400,
      );
    }
    try {
      final mosaic = await _collab.refreshStatus(id);
      if (mosaic == null) {
        return jsonError(
          code: 'mosaic_not_published',
          message: 'project $id is not published to a hub',
          statusCode: 404,
        );
      }
      return jsonOk(_collabMosaicToJson(mosaic));
    } catch (e) {
      return _collabError(
        code: 'mosaic_status_failed',
        message: 'Failed to refresh mosaic status',
        error: e,
      );
    }
  }

  /// POST `/api/mosaic/projects/<projectId>/output` — download the FINISHED
  /// mosaic the owner assembled + republished to the swarm, persist it as this
  /// project's output master, and mark it complete (the participant end of the
  /// "publish the finished mosaic to every participant" loop). The destination
  /// is fixed under the project's assembly dir: the seam deliberately exposes no
  /// caller-supplied output path, so an untrusted remote cannot steer the
  /// hub-served bytes to an arbitrary location on the appliance host.
  Future<Response> handleDownloadCollaborativeOutput(
    Request request,
    String projectId,
  ) async {
    _logInfo('[API] POST /api/mosaic/projects/$projectId/output');
    final id = int.tryParse(projectId);
    if (id == null) {
      return jsonError(
        code: 'invalid_project_id',
        message: 'projectId must be an integer',
        statusCode: 400,
      );
    }
    try {
      final path = await _collab.downloadOutput(id);
      return jsonOk({'projectId': id, 'outputPath': path});
    } catch (e) {
      return _collabError(
        code: 'mosaic_output_download_failed',
        message: 'Failed to download mosaic output',
        error: e,
      );
    }
  }

  // Helpers

  Map<String, dynamic> _collabMosaicToJson(CollabMosaic m) => {
    'mosaicId': m.mosaicId,
    if (m.ownerAccountId.isNotEmpty) 'ownerAccountId': m.ownerAccountId,
    if (m.ownerDisplayName != null) 'ownerDisplayName': m.ownerDisplayName,
    'name': m.name,
    'rows': m.rows,
    'cols': m.cols,
    'overlapPct': m.overlapPct,
    'positionAngleDeg': m.positionAngleDeg,
    'centerRaDeg': m.centerRaDeg,
    'centerDecDeg': m.centerDecDeg,
    'status': m.status,
    'outputPresent': m.outputPresent,
    'panels': m.panels.map(_collabPanelToJson).toList(),
  };

  Map<String, dynamic> _collabPanelToJson(CollabMosaicPanel p) => {
    'panelIndex': p.panelIndex,
    'centerRaDeg': p.centerRaDeg,
    'centerDecDeg': p.centerDecDeg,
    'status': p.status,
    if (p.assignedAccountId != null) 'assignedAccountId': p.assignedAccountId,
    if (p.assignedRigId != null) 'assignedRigId': p.assignedRigId,
    if (p.assignedDisplayName != null)
      'assignedDisplayName': p.assignedDisplayName,
    'uploaded': p.uploaded,
  };

  MosaicConfig _parseMosaicConfig(Map<String, dynamic> json) {
    return MosaicConfig(
      // Bound the centre here, at the one place every mosaic endpoint parses
      // config. POST /api/mosaic/validate already reports an out-of-range RA,
      // but calculate-area / generate-panels / estimate-time /
      // generate-sequence accepted it and silently WRAPPED it modulo 24 — a
      // centre of 83.822 (degrees mistaken for hours) produced panels at
      // 11.79h and a fully runnable sequence aimed at the wrong sky. Reject it
      // instead of planning a night against bogus coordinates.
      centerRa: requireDouble(json, 'centerRa', min: 0, max: 24),
      centerDec: requireDouble(json, 'centerDec', min: -90, max: 90),
      // A panel is a physical field of view: zero or negative produced a
      // "successful" plan with areaSquareDegrees: -2.67.
      panelWidthArcmin: requireDouble(json, 'panelWidthArcmin', min: 0.001),
      panelHeightArcmin: requireDouble(json, 'panelHeightArcmin', min: 0.001),
      // Overlap is a fraction of a panel, so it must stay under 100%: at
      // exactly 100 the inter-panel step is zero and every panel in the grid
      // collapsed onto the SAME centre (a 2x2 imaging one spot four times);
      // above 100 the step goes negative and the grid came out mirrored.
      overlapPercent:
          optionalDouble(json, 'overlapPercent', min: 0, max: 99) ?? 10.0,
      rotation: optionalDouble(json, 'rotation', min: -360, max: 360) ?? 0.0,
      panelsHorizontal: requireInt(json, 'panelsHorizontal', min: 1),
      panelsVertical: requireInt(json, 'panelsVertical', min: 1),
    );
  }

  MosaicExposureSettings _parseExposureSettings(Map<String, dynamic> json) {
    return MosaicExposureSettings(
      // An exposure is a duration. Unbounded, this emitted a runnable
      // ExposureNode with durationSecs: -300 (and estimatedTimeSecs: -540)
      // straight to the camera driver.
      exposureSeconds: requireDouble(json, 'exposureSeconds', min: 0.000001),
      exposuresPerPanel: requireInt(json, 'exposuresPerPanel', min: 1),
      filterName: optionalString(json, 'filterName'),
      binning: optionalInt(json, 'binning', min: 1, max: 16),
      gain: optionalDouble(json, 'gain', min: 0),
      offset: optionalDouble(json, 'offset', min: 0),
    );
  }

  MosaicSequenceOptions _parseSequenceOptions(Map<String, dynamic> json) {
    return MosaicSequenceOptions(
      serpentineOrdering: optionalBool(json, 'serpentineOrdering') ?? false,
      autofocusPerPanel: optionalBool(json, 'autofocusPerPanel') ?? false,
      autofocusInterval: optionalInt(json, 'autofocusInterval') ?? 0,
      centerAfterSlew: optionalBool(json, 'centerAfterSlew') ?? false,
      ditherBetweenExposures:
          optionalBool(json, 'ditherBetweenExposures') ?? false,
      ditherPixels: optionalDouble(json, 'ditherPixels'),
      minAltitude: optionalDouble(json, 'minAltitude'),
      maxAltitude: optionalDouble(json, 'maxAltitude'),
    );
  }

  Map<String, dynamic> _panelToJson(MosaicPanel panel) {
    return {
      'raHours': panel.raHours,
      'decDegrees': panel.decDegrees,
      'panelIndex': panel.panelIndex,
      'row': panel.row,
      'col': panel.col,
    };
  }

  Map<String, dynamic> _nodeToJson(SequenceNode node) {
    final base = {
      'id': node.id,
      'name': node.name,
      'type': node.runtimeType.toString(),
      'parentId': node.parentId,
      'orderIndex': node.orderIndex,
      'isEnabled': node.isEnabled,
    };

    // Add type-specific fields
    if (node is ExposureNode) {
      base['durationSecs'] = node.durationSecs;
      base['count'] = node.count;
      base['filter'] = node.filter;
      base['frameType'] = node.frameType.name;
    } else if (node is InstructionSetNode) {
      base['childIds'] = node.childIds;
    } else if (node is TargetHeaderNode) {
      base['targetName'] = node.targetName;
      base['raHours'] = node.raHours;
      base['decDegrees'] = node.decDegrees;
      base['childIds'] = node.childIds;
    } else if (node is LoopNode) {
      base['repeatCount'] = node.repeatCount;
      base['childIds'] = node.childIds;
    } else if (node is SlewNode) {
      base['customRa'] = node.customRa;
      base['customDec'] = node.customDec;
    }

    return base;
  }
}

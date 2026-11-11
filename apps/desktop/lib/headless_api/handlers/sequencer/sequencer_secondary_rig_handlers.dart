part of '../sequencer_handlers.dart';

extension _SequencerSecondaryRig on SequencerHandlers {
  // Dual-rig / secondary (piggyback) camera — monitoring and control.
  //
  // Lets a remote dashboard observe and drive the secondary capture loop. The
  // dither coordination is enforced natively (the primary's dither call sites
  // gate on the shared barrier), so these endpoints are thin wrappers over the
  // FRB bindings.

  /// GET /api/sequencer/secondary-rig — live status snapshot of the secondary
  /// rig (or `{armed: false}` when none is running).
  Future<Response> _handleSecondaryRigStatus(Request request) async {
    final s = await bridge_api.apiSecondaryRigGetStatus();
    return jsonOk({
      'armed': s.armed,
      'running': s.running,
      'cameraId': s.cameraId,
      'rigLabel': s.rigLabel,
      'framesCaptured': s.framesCaptured,
      'framesAborted': s.framesAborted,
      'plannedFrames': s.plannedFrames,
      'waitingForDither': s.waitingForDither,
      'exposing': s.exposing,
      'ditherPending': s.ditherPending,
      'forcedProceeds': s.forcedProceeds,
      'lastError': s.lastError,
    });
  }

  /// POST /api/sequencer/secondary-rig/start — arm + start the secondary loop.
  ///
  /// Body: { cameraId (required), exposureSecs (required), gain?, offset?,
  /// binX?, binY?, frameCount?, filterName?, targetTempC?, rigLabel?,
  /// ditherMaxWaitSecs?, inFlightPolicy?, saveBasePath?, targetName?,
  /// targetRaHours?, targetDecDegrees? }.
  Future<Response> _handleSecondaryRigStart(Request request) async {
    _logInfo('[API] POST /api/sequencer/secondary-rig/start');
    final body = await request.readAsString();
    final decoded = body.isEmpty ? null : jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw BadRequestError(field: 'body', expected: 'JSON object');
    }
    final cameraId = decoded['cameraId'];
    if (cameraId is! String || cameraId.trim().isEmpty) {
      throw BadRequestError(field: 'cameraId', expected: 'non-empty string');
    }
    final exposure = optionalDouble(decoded, 'exposureSecs');
    if (exposure == null ||
        !exposure.isFinite ||
        exposure < 0.001 ||
        exposure > 86400) {
      throw BadRequestError(
        field: 'exposureSecs',
        expected: 'finite number from 0.001 to 86400',
      );
    }
    final saveBasePath = decoded['saveBasePath'];
    if (saveBasePath is! String || saveBasePath.trim().isEmpty) {
      throw BadRequestError(
        field: 'saveBasePath',
        expected: 'non-empty host directory path',
      );
    }
    final binX = optionalInt(decoded, 'binX') ?? 1;
    final binY = optionalInt(decoded, 'binY') ?? 1;
    if (binX < 1 || binX > 16 || binY < 1 || binY > 16) {
      throw BadRequestError(
        field: 'binX/binY',
        expected: 'integers from 1 to 16',
      );
    }
    final frameCount = optionalInt(decoded, 'frameCount');
    if (frameCount != null && frameCount < 1) {
      throw BadRequestError(field: 'frameCount', expected: 'positive integer');
    }
    final ditherMaxWait = optionalDouble(decoded, 'ditherMaxWaitSecs') ?? 30.0;
    if (!ditherMaxWait.isFinite || ditherMaxWait < 0.1 || ditherMaxWait > 600) {
      throw BadRequestError(
        field: 'ditherMaxWaitSecs',
        expected: 'finite number from 0.1 to 600',
      );
    }
    final rawInFlightPolicy = decoded['inFlightPolicy'];
    if (rawInFlightPolicy != null && rawInFlightPolicy is! String) {
      throw BadRequestError(field: 'inFlightPolicy', expected: 'string');
    }
    final inFlightPolicy =
        (rawInFlightPolicy as String?) ?? 'complete_if_short';
    if (inFlightPolicy != 'complete_if_short' &&
        inFlightPolicy != 'abort_immediately') {
      throw BadRequestError(
        field: 'inFlightPolicy',
        expected: 'complete_if_short or abort_immediately',
      );
    }
    final commandId = commandCorrelator?.beginCommand(
      operation: 'sequencer.secondaryRig.start',
    );
    await bridge_api.apiSecondaryRigStart(
      config: bridge_api.SecondaryRigConfigApi(
        cameraId: cameraId,
        exposureSecs: exposure,
        gain: optionalInt(decoded, 'gain'),
        offset: optionalInt(decoded, 'offset'),
        binX: binX,
        binY: binY,
        frameCount: frameCount,
        filterName: decoded['filterName'] as String?,
        targetTempC: optionalDouble(decoded, 'targetTempC'),
        rigLabel: (decoded['rigLabel'] as String?) ?? 'Secondary',
        ditherMaxWaitSecs: ditherMaxWait,
        inFlightPolicy: inFlightPolicy,
        saveBasePath: saveBasePath,
        targetName: decoded['targetName'] as String?,
        targetRaHours: optionalDouble(decoded, 'targetRaHours'),
        targetDecDegrees: optionalDouble(decoded, 'targetDecDegrees'),
        observerName: decoded['observerName'] as String?,
        siteLatitudeDeg: optionalDouble(decoded, 'siteLatitudeDeg'),
        siteLongitudeDeg: optionalDouble(decoded, 'siteLongitudeDeg'),
        siteElevationM: optionalDouble(decoded, 'siteElevationM'),
      ),
    );
    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'started',
    });
  }

  /// POST /api/sequencer/secondary-rig/stop — stop the secondary loop.
  Future<Response> _handleSecondaryRigStop(Request request) async {
    _logInfo('[API] POST /api/sequencer/secondary-rig/stop');
    final commandId = commandCorrelator?.beginCommand(
      operation: 'sequencer.secondaryRig.stop',
    );
    await bridge_api.apiSecondaryRigStop();
    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'stopped',
    });
  }
}

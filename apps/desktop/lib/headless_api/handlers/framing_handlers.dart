import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:shelf/shelf.dart';

import '../job_manager.dart';
import '../response_helpers.dart';
import '../validation.dart';
import 'centering_request.dart';
import 'device_handlers.dart' show requestPrefersLegacyBlocking;
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

class FramingHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    FramingApi.slewToTarget: handleSlewToTarget,
    FramingApi.centerOnTarget: handleCenterOnTarget,
    FramingApi.syncMount: handleSyncMount,
    FramingApi.getCurrentPosition: handleGetCurrentPosition,
    FramingApi.rotateTo: handleRotateTo,
    FramingApi.abortSlew: handleAbortSlew,
    FramingApi.parkMount: handleParkMount,
    FramingApi.unparkMount: handleUnparkMount,
    FramingApi.setTarget: handleSetTarget,
    FramingApi.saveFraming: handleSaveFraming,
  };

  final ProviderContainer container;

  /// optional job manager. When wired, center-on-target
  /// returns `{jobId, status: queued}` immediately and the multi-step
  /// slew/solve/adjust loop runs in the background, with each iteration
  /// reported as a progress update on the same job.
  final JobManager? jobManager;

  FramingHandlers(this.container, {this.jobManager});

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'FramingHandlers');

  Future<Response> handleSlewToTarget(Request request) async {
    _logInfo('[API] POST /api/framing/slew-to-target');
    final payload = await readJsonObject(request);

    final ra = requireDouble(payload, 'ra', min: 0, max: 24);
    final dec = requireDouble(payload, 'dec', min: -90, max: 90);

    final backend = container.read(deviceBackendProvider);

    final connectedDevices = await backend.getConnectedDevices();
    final mount = connectedDevices
        .where((d) => d.deviceType == DeviceType.mount)
        .firstOrNull;

    if (mount == null) {
      return jsonBadRequest({'error': 'No mount connected'});
    }

    await backend.mountSlewToCoordinates(mount.id, ra, dec);

    return jsonOk({'status': 'slewing', 'targetRa': ra, 'targetDec': dec});
  }

  Future<Response> handleCenterOnTarget(Request request) async {
    _logInfo('[API] POST /api/framing/center-on-target');
    final payload = await readJsonObject(request);

    final ra = requireDouble(payload, 'ra', min: 0, max: 24);
    final dec = requireDouble(payload, 'dec', min: -90, max: 90);
    final centering = await centeringForRequest(container, payload);

    Map<String, Object?> resultToJson(CenteringResult result) => {
      'success': result.success,
      'iterations': result.iterations,
      'finalOffsetArcsec': result.finalOffsetArcsec,
      'errorMessage': result.errorMessage,
      'iterationHistory': result.iterationHistory
          .map(
            (i) => {
              'iterationNumber': i.iterationNumber,
              'solvedRa': i.solvedRa,
              'solvedDec': i.solvedDec,
              'targetRa': i.targetRa,
              'targetDec': i.targetDec,
              'offsetArcsec': i.offsetArcsec,
              'offsetArcmin': i.offsetArcmin,
              'plateSolveSuccess': i.plateSolveSuccess,
              'errorMessage': i.errorMessage,
              'timestamp': i.timestamp.millisecondsSinceEpoch,
            },
          )
          .toList(),
    };

    Future<CenteringResult> runCentering() =>
        container.read(centeringServiceProvider).centerOnTarget(
              targetRa: ra,
              targetDec: dec,
              solverConfig: centering.solver,
              config: centering.config,
            );

    final mgr = jobManager;
    final preferLegacy = requestPrefersLegacyBlocking(request);
    if (mgr != null && !preferLegacy) {
      final job = mgr.start(
        operation: 'framing.center-on-target',
        deviceId: null,
        work: (sink, cancellation) async {
          sink.update(0.0, 'Centering on RA=$ra DEC=$dec');
          final centeringService = container.read(centeringServiceProvider);
          final workFuture = runCentering();
          final raced = await Future.any<dynamic>([
            workFuture,
            cancellation.whenCancelled.then(
              (_) => _CenteringCancelled.instance,
            ),
          ]);
          if (raced is _CenteringCancelled) {
            await centeringService.stop();
            try {
              await workFuture;
            } catch (e) {
              _logger.debug(
                'Centering exited with the expected cancellation error: $e',
                source: 'FramingHandlers',
              );
            }
            throw const JobCancelledException(
              'Center-on-target cancellation requested by client',
            );
          }
          final result = raced as CenteringResult;
          if (!result.success) {
            throw JobFailedException(
              code: 'centering_failed',
              message:
                  result.errorMessage ?? 'Centering did not reach the target.',
              details: resultToJson(result),
            );
          }
          return resultToJson(result);
        },
      );
      return jsonOk({
        'jobId': job.jobId,
        'status': job.state.wireName,
        'operation': job.operation,
      });
    }

    final result = await runCentering();
    return jsonOk(resultToJson(result));
  }

  Future<Response> handleSyncMount(Request request) async {
    _logInfo('[API] POST /api/framing/sync');
    final payload = await readJsonObject(request);

    final ra = requireDouble(payload, 'ra', min: 0, max: 24);
    final dec = requireDouble(payload, 'dec', min: -90, max: 90);

    final backend = container.read(deviceBackendProvider);

    final connectedDevices = await backend.getConnectedDevices();
    final mount = connectedDevices
        .where((d) => d.deviceType == DeviceType.mount)
        .firstOrNull;

    if (mount == null) {
      return jsonBadRequest({'error': 'No mount connected'});
    }

    await backend.mountSync(mount.id, ra, dec);

    return jsonOk({'status': 'synced', 'ra': ra, 'dec': dec});
  }

  Future<Response> handleGetCurrentPosition(Request request) async {
    final backend = container.read(deviceBackendProvider);

    final connectedDevices = await backend.getConnectedDevices();
    final mount = connectedDevices
        .where((d) => d.deviceType == DeviceType.mount)
        .firstOrNull;

    if (mount == null) {
      return jsonBadRequest({'error': 'No mount connected'});
    }

    final status = await backend.getMountStatus(mount.id);

    return jsonOk({
      'ra': status.rightAscension,
      'dec': status.declination,
      'altitude': status.altitude,
      'azimuth': status.azimuth,
      'tracking': status.tracking,
      'sideOfPier': status.sideOfPier.name,
      'slewing': status.slewing,
      'atPark': status.parked,
      'atHome': status.atHome,
      'trackingRate': status.trackingRate.name,
    });
  }

  Future<Response> handleRotateTo(Request request) async {
    _logInfo('[API] POST /api/framing/rotate-to');
    final payload = await readJsonObject(request);

    final angle = requireDouble(payload, 'angle');

    final backend = container.read(deviceBackendProvider);

    final connectedDevices = await backend.getConnectedDevices();
    final rotator = connectedDevices
        .where((d) => d.deviceType == DeviceType.rotator)
        .firstOrNull;

    if (rotator == null) {
      return jsonBadRequest({'error': 'No rotator connected'});
    }

    await backend.rotatorMoveTo(rotator.id, angle);

    return jsonOk({'status': 'rotating', 'targetAngle': angle});
  }

  Future<Response> handleAbortSlew(Request request) async {
    _logInfo('[API] POST /api/framing/abort-slew');
    final backend = container.read(deviceBackendProvider);

    final connectedDevices = await backend.getConnectedDevices();
    final mount = connectedDevices
        .where((d) => d.deviceType == DeviceType.mount)
        .firstOrNull;

    if (mount == null) {
      return jsonBadRequest({'error': 'No mount connected'});
    }

    // Shared stop/abort no-op contract — see [kWasRunningField]. Observed live
    // with no slew in progress:
    //   POST /api/framing/abort-slew -> 200 {"status":"aborted"}
    // An operator hitting abort in a hurry reads that as "the mount was
    // stopped". This is the most dangerous instance of the pattern, because it
    // can mask the fact that a slew is still running somewhere else.
    //
    // Never skip a mount abort because we could not confirm motion: a failed
    // status read still issues the abort.
    var wasRunning = true;
    try {
      final status = await backend.getMountStatus(mount.id);
      wasRunning = status.slewing;
    } catch (error) {
      _logInfo(
        'abort-slew precondition check skipped for ${mount.id}: '
        'mount status read failed ($error)',
      );
    }

    if (!wasRunning) {
      return jsonOk({
        'status': 'aborted',
        kWasRunningField: false,
        'message':
            'The mount was not slewing; nothing to abort. Its motion state '
            'is unchanged.',
      });
    }

    await backend.mountAbort(mount.id);

    return jsonOk({'status': 'aborted', kWasRunningField: true});
  }

  Future<Response> handleParkMount(Request request) async {
    _logInfo('[API] POST /api/framing/park');
    final backend = container.read(deviceBackendProvider);

    final connectedDevices = await backend.getConnectedDevices();
    final mount = connectedDevices
        .where((d) => d.deviceType == DeviceType.mount)
        .firstOrNull;

    if (mount == null) {
      return jsonBadRequest({'error': 'No mount connected'});
    }

    await backend.mountPark(mount.id);

    return jsonOk({'status': 'parking'});
  }

  Future<Response> handleUnparkMount(Request request) async {
    _logInfo('[API] POST /api/framing/unpark');
    final backend = container.read(deviceBackendProvider);

    final connectedDevices = await backend.getConnectedDevices();
    final mount = connectedDevices
        .where((d) => d.deviceType == DeviceType.mount)
        .firstOrNull;

    if (mount == null) {
      return jsonBadRequest({'error': 'No mount connected'});
    }

    await backend.mountUnpark(mount.id);

    return jsonOk({'status': 'unparking'});
  }

  /// POST /api/framing/set-target
  ///
  /// Updates the host framing assistant when a remote companion sends a target
  /// from Plan Tonight / planetarium so the desktop framing screen matches.
  Future<Response> handleSetTarget(Request request) async {
    _logInfo('[API] POST /api/framing/set-target');
    final payload = await readJsonObject(request);
    final ra = requireDouble(payload, 'ra', min: 0, max: 24);
    final dec = requireDouble(payload, 'dec', min: -90, max: 90);
    final name = requireString(payload, 'name');

    // Linked clients get the target from the framingTarget runtime channel,
    // as they do one picked on the host's own screen.
    container
        .read(framingProvider.notifier)
        .setTargetCoordinates(ra, dec, name: name);

    return jsonOk({'status': 'ok', 'ra': ra, 'dec': dec, 'name': name});
  }

  /// POST /api/framing/save
  ///
  /// Persists RA/Dec/position angle on an existing target or creates a new
  /// catalog row when [targetId] is omitted.
  Future<Response> handleSaveFraming(Request request) async {
    _logInfo('[API] POST /api/framing/save');
    final payload = await readJsonObject(request);
    final ra = requireDouble(payload, 'ra', min: 0, max: 24);
    final dec = requireDouble(payload, 'dec', min: -90, max: 90);
    final positionAngle = requireDouble(
      payload,
      'positionAngle',
      min: 0,
      max: 360,
    );
    final name = requireString(payload, 'name');
    final targetId = optionalInt(payload, 'targetId', min: 1);

    final database = container.read(databaseProvider);

    if (targetId != null) {
      final existing = await database.targetsDao.getTargetById(targetId);
      if (existing == null) {
        return jsonNotFound({'error': 'Target not found: $targetId'});
      }
      final updated = existing.copyWith(
        name: name,
        ra: ra,
        dec: dec,
        positionAngle: Value(positionAngle),
      );
      await database.targetsDao.updateTarget(updated);
      publishHostMutationFromContainer(
        container,
        entityType: HostMutationEntity.target,
        action: HostMutationAction.updated,
        entityId: targetId.toString(),
        extra: {
          'name': name,
          'ra': ra,
          'dec': dec,
          'positionAngle': positionAngle,
        },
      );
      return jsonOk({
        'status': 'updated',
        'id': targetId,
        'name': name,
        'ra': ra,
        'dec': dec,
        'positionAngle': positionAngle,
      });
    }

    final companion = TargetsCompanion(
      name: Value(name),
      ra: Value(ra),
      dec: Value(dec),
      positionAngle: Value(positionAngle),
      minAltitude: const Value(30.0),
    );
    final id = await database.targetsDao.createTarget(companion);
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.target,
      action: HostMutationAction.created,
      entityId: id.toString(),
      extra: {
        'name': name,
        'ra': ra,
        'dec': dec,
        'positionAngle': positionAngle,
      },
    );
    return jsonOk({
      'status': 'created',
      'id': id,
      'name': name,
      'ra': ra,
      'dec': dec,
      'positionAngle': positionAngle,
    });
  }
}

/// Sentinel marking the cancellation branch of a Future.any race against
/// the multi-step centering loop. Library-private — see the analogous
/// sentinels in imaging_handlers / device_handlers.
class _CenteringCancelled {
  const _CenteringCancelled._();
  static const _CenteringCancelled instance = _CenteringCancelled._();
}

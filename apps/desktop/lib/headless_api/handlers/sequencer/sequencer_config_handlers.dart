part of '../sequencer_handlers.dart';

/// Configuration setters and updaters pushed into the running executor.
extension _SequencerConfig on SequencerHandlers {
  Future<Response> _handleSequencerSetSimulationMode(Request request) async {
    _logInfo('[API] POST /api/sequencer/simulation');
    final payload = await readJsonObject(request);
    final enabled = requireBool(payload, 'enabled');

    final backend = container.read(sequencerBackendProvider);
    try {
      await backend.sequencerSetSimulationMode(enabled);
    } on bridge_api.SkotiqError catch (e) {
      // Release/appliance builds refuse simulation mode with a typed
      // NotSupported so a shipped rig never drives mock hardware. That one
      // refusal is a policy answer the caller can act on. Every other backend
      // error — bridge not loaded, executor lock unavailable, a serialisation
      // fault — is rethrown so the error translator reports what actually
      // failed instead of dressing a fault up as a policy refusal.
      final refused = e.maybeMap(
        notSupported: (_) => true,
        orElse: () => false,
      );
      if (!refused) rethrow;
      _logInfo('[API] POST /api/sequencer/simulation refused: $e');
      return jsonBadRequest({
        'error': 'simulation_mode_unavailable',
        'message':
            'Simulation mode is not available on this build (production '
            'appliances run real hardware only).',
      });
    }
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerSetDevices(Request request) async {
    _logInfo('[API] POST /api/sequencer/devices');
    final payload = await readJsonObject(request);

    final cameraId = optionalString(payload, 'cameraId');
    final mountId = optionalString(payload, 'mountId');
    final focuserId = optionalString(payload, 'focuserId');
    final filterwheelId = optionalString(payload, 'filterwheelId');
    final rotatorId = optionalString(payload, 'rotatorId');

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerSetDevices(
      cameraId: cameraId,
      mountId: mountId,
      focuserId: focuserId,
      filterwheelId: filterwheelId,
      rotatorId: rotatorId,
      filterNames: optionalList<String>(payload, 'filterNames'),
    );

    // Remember the assignment. `POST /api/sequencer/start` rebuilds the
    // executor's device ids from the connected-device list, and without this
    // record it would overwrite everything set here with null — making this
    // endpoint a no-op that still answers `{"status":"ok"}`. Recorded only
    // after the backend accepted the call, so a failed assignment leaves no
    // phantom behind.
    _explicitlyAssignedDeviceIds[DeviceType.camera] = cameraId;
    _explicitlyAssignedDeviceIds[DeviceType.mount] = mountId;
    _explicitlyAssignedDeviceIds[DeviceType.focuser] = focuserId;
    _explicitlyAssignedDeviceIds[DeviceType.filterWheel] = filterwheelId;
    _explicitlyAssignedDeviceIds[DeviceType.rotator] = rotatorId;
    return jsonOk({'status': 'ok'});
  }

  /// POST /api/sequencer/save-path.
  ///
  /// The save path is where a run's science frames land, so an unusable value
  /// is data loss with a delay — a full night captured and every frame
  /// discarded. Nothing is forwarded to the backend until this host has proved
  /// it can create the directory and write into it.
  Future<Response> _handleSequencerSetSavePath(Request request) async {
    _logInfo('[API] POST /api/sequencer/save-path');
    final payload = await readJsonObject(request);
    final requested = optionalString(payload, 'path')?.trim();
    if (requested == null || requested.isEmpty) {
      return jsonBadRequest({
        'error':
            'path is required and must name a directory this host can write '
            'to. Captured frames are written there; without it a run would '
            'discard every frame.',
        'code': 'save_path_required',
      });
    }

    final directory = Directory(requested);
    try {
      await directory.create(recursive: true);
      final probe = File(
        '${directory.path}${Platform.pathSeparator}'
        '.skotiq-write-probe-${DateTime.now().microsecondsSinceEpoch}',
      );
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException catch (error) {
      return jsonBadRequest({
        'error':
            'Save path "$requested" is not usable: ${error.message}. Choose a '
            'directory this host can write to.',
        'code': 'save_path_unwritable',
      });
    }

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerSetSavePath(requested);

    // Point the host's own capture-folder setting at the same directory.
    //
    // These are two separate settings: `sequencerSetSavePath` is the NATIVE
    // executor's output directory, while the free-space guard, the disk-space
    // watchdog and the capture-folder UI all read
    // `appSettings.imageOutputPath`. A headless-only operator has no other way
    // to set the second, so unlinked the guard watches nothing while the disk
    // fills — and pointed at a different volume it is worse than inert,
    // reporting healthy space on the wrong disk.
    //
    // Non-fatal: the run's frames go where the caller asked either way, and
    // refusing a valid save path because a monitoring setting could not be
    // persisted would trade a working night for a bookkeeping one.
    try {
      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .setImageOutputPath(requested);
    } catch (error) {
      _logWarning(
        '[API] POST /api/sequencer/save-path: frames will be written to '
        '"$requested" but the host capture-folder setting could not be '
        'updated ($error); disk-space monitoring may watch a different volume',
      );
    }
    return jsonOk({'status': 'ok', 'path': requested});
  }

  Future<Response> _handleSequencerSetActiveSequenceRunId(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/active-sequence-run-id');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerSetActiveSequenceRunId(
      optionalInt(payload, 'sequence_run_id'),
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerUpdatePendingIntegrationCarryOver(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-pending-integration-carry-over');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdatePendingIntegrationCarryOver(
      optionalNestedDoubleMap(payload, 'carry_over'),
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerUpdateSkyBrightness(Request request) async {
    _logInfo('[API] POST /api/sequencer/update-sky-brightness');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateSkyBrightness(
      mag: optionalDouble(payload, 'mag'),
    );
    return jsonOk({'status': 'ok'});
  }
}

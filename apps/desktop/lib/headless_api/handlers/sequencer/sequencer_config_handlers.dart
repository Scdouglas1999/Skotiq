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
    } on bridge_api.NightshadeError catch (e) {
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

    // Why: filterFocusOffsets has dynamic-typed JSON object keys; validate
    // each value is numeric since requireList can't express map<string,int>
    // and we want a precise per-key error path instead of a ClassCastException.
    Map<String, int>? filterFocusOffsets;
    final rawOffsets = payload['filterFocusOffsets'];
    if (rawOffsets != null) {
      if (rawOffsets is! Map) {
        throw BadRequestError(field: 'filterFocusOffsets', expected: 'object');
      }
      filterFocusOffsets = <String, int>{};
      rawOffsets.forEach((key, value) {
        if (value is! num) {
          throw BadRequestError(
            field: 'filterFocusOffsets.$key',
            expected: 'integer',
          );
        }
        filterFocusOffsets![key.toString()] = value.toInt();
      });
    }

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
      filterFocusOffsets: filterFocusOffsets,
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

  Future<Response> _handleSequencerSetSafetyFailMode(Request request) async {
    _logInfo('[API] POST /api/sequencer/safety-fail-mode');
    final payload = await readJsonObject(request);
    final mode = requireString(payload, 'mode');

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerSetSafetyFailMode(mode);
    return jsonOk({'status': 'ok'});
  }

  /// POST /api/sequencer/park-policy: whether the executor's standard weather
  /// and dawn triggers may park the mount and close the cover and dome.
  Future<Response> _handleSequencerSetParkPolicy(Request request) async {
    _logInfo('[API] POST /api/sequencer/park-policy');
    final payload = await readJsonObject(request);
    final parkOnUnsafeWeather = requireBool(payload, 'parkOnUnsafeWeather');
    final parkBeforeDawn = requireBool(payload, 'parkBeforeDawn');

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerSetParkPolicy(
      parkOnUnsafeWeather: parkOnUnsafeWeather,
      parkBeforeDawn: parkBeforeDawn,
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerSetSafetyCheckInterval(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/safety-check-interval');
    final payload = await readJsonObject(request);
    final seconds = requireInt(payload, 'seconds', min: 5, max: 3600);

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerSetSafetyCheckIntervalSeconds(seconds);
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
        '.nightshade-write-probe-${DateTime.now().microsecondsSinceEpoch}',
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

  Future<Response> _handleSequencerSetDecisionLoggingEnabled(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/decision-logging-enabled');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerSetDecisionLoggingEnabled(
      requireBool(payload, 'enabled'),
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerUpdateDitherConfig(Request request) async {
    _logInfo('[API] POST /api/sequencer/update-dither-config');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateDitherConfig(
      pixels: requireDouble(payload, 'pixels'),
      settlePixels: requireDouble(payload, 'settlePixels'),
      settleTime: requireDouble(payload, 'settleTime'),
      settleTimeout: requireDouble(payload, 'settleTimeout'),
      raOnly: optionalBool(payload, 'raOnly') ?? false,
    );
    return jsonOk({'status': 'ok'});
  }

  /// POST /api/sequencer/update-meridian-flip-config.
  ///
  /// Lets a paired controller push the operator's meridian-flip settings onto
  /// the master's `meridian_flip` trigger, which otherwise runs on Rust
  /// defaults for the whole night regardless of the Settings panel.
  Future<Response> _handleSequencerUpdateMeridianFlipConfig(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-meridian-flip-config');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateMeridianFlipConfig(
      requireString(payload, 'configJson'),
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerUpdateLocation(Request request) async {
    _logInfo('[API] POST /api/sequencer/update-location');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateLocation(
      latitude: requireDouble(payload, 'latitude'),
      longitude: requireDouble(payload, 'longitude'),
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerUpdateFilterOffsets(Request request) async {
    _logInfo('[API] POST /api/sequencer/update-filter-offsets');
    final payload = await readJsonObject(request);
    final rawOffsets = payload['offsets'];
    // Why: same as set-devices — Dart's Map<String,int> can't be expressed
    // through requireList; we validate per-entry to give callers a precise
    // error path rather than a generic ClassCastException.
    final offsets = <String, int>{};
    if (rawOffsets != null) {
      if (rawOffsets is! Map) {
        throw BadRequestError(field: 'offsets', expected: 'object');
      }
      rawOffsets.forEach((key, value) {
        if (value is! num) {
          throw BadRequestError(field: 'offsets.$key', expected: 'integer');
        }
        offsets[key.toString()] = value.toInt();
      });
    }

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateFilterOffsets(offsets);
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

  /// Push the live autofocus cadence into the running executor.
  ///
  /// Why: the Settings UI's autofocus-cadence field calls this through
  /// `backend.sequencerUpdateAutofocusInterval`; the standard AutofocusInterval
  /// trigger reads its target frame count from `RuntimeConfig` and the running
  /// sequencer must be told to re-evaluate without restarting. Values < 1 are
  /// rejected as a structured 400 (the Rust bridge enforces the same gate).
  Future<Response> _handleSequencerUpdateAutofocusInterval(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-autofocus-interval');
    final payload = await readJsonObject(request);
    final everyNFrames = requireInt(payload, 'everyNFrames', min: 1);

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateAutofocusInterval(everyNFrames);
    return jsonOk({'status': 'ok', 'everyNFrames': everyNFrames});
  }

  /// Push the operator's autofocus tuning so trigger-fired refocus uses it
  /// instead of library defaults when the sequence carries no Autofocus node.
  /// The body is the same JSON shape an Autofocus node carries, so the remote
  /// client and the local FFI path share one serializer.
  Future<Response> _handleSequencerUpdateAutofocusConfig(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-autofocus-config');
    final payload = await readJsonObject(request);
    final configJson = requireString(payload, 'configJson');

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateAutofocusConfig(configJson);
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerUpdateDefaultQualityCheck(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-default-quality-check');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateDefaultQualityCheck(
      hfrThreshold: optionalDouble(payload, 'hfrThreshold'),
      hfrBaselinePercent: optionalDouble(payload, 'hfrBaselinePercent'),
      eccentricityThreshold: optionalDouble(payload, 'eccentricityThreshold'),
      starCountMin: optionalInt(payload, 'starCountMin', min: 0),
      maxConsecutiveRejects: requireInt(
        payload,
        'maxConsecutiveRejects',
        min: 1,
      ),
      enabled: requireBool(payload, 'enabled'),
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerUpdateRejectFolderPath(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-reject-folder-path');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateRejectFolderPath(
      optionalString(payload, 'path'),
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerUpdateObserverProfile(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-observer-profile');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateObserverProfile(
      observerName: optionalString(payload, 'observerName'),
      siteElevationM: optionalDouble(payload, 'siteElevationM'),
      cameraMake: optionalString(payload, 'cameraMake'),
      cameraModel: optionalString(payload, 'cameraModel'),
      telescopeName: optionalString(payload, 'telescopeName'),
      telescopeFocalLengthMm: optionalDouble(payload, 'telescopeFocalLengthMm'),
      telescopeApertureMm: optionalDouble(payload, 'telescopeApertureMm'),
    );
    // Echo which fields were understood, so a key the endpoint dropped — say
    // `focalLengthMm` for `telescopeFocalLengthMm` — is visible in the reply
    // instead of in a later FITS header missing FOCALLEN. See [fieldReport].
    return jsonOk({
      'status': 'ok',
      ...fieldReport(payload, const {
        'observerName',
        'siteElevationM',
        'cameraMake',
        'cameraModel',
        'telescopeName',
        'telescopeFocalLengthMm',
        'telescopeApertureMm',
      }),
    });
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

  Future<Response> _handleSequencerUpdateDefaultAdaptiveExposure(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-default-adaptive-exposure');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateDefaultAdaptiveExposure(
      enabled: requireBool(payload, 'enabled'),
      targetSnr: requireDouble(payload, 'targetSnr', min: 0),
      referenceSkyBrightnessMag: requireDouble(
        payload,
        'referenceSkyBrightnessMag',
      ),
      minExposureSecs: requireDouble(payload, 'minExposureSecs', min: 0),
      maxExposureSecs: requireDouble(payload, 'maxExposureSecs', min: 0),
      perFilterEnabled: optionalStringBoolMap(payload, 'perFilterEnabled'),
      perFilterMinSecs: optionalStringDoubleMap(payload, 'perFilterMinSecs'),
      perFilterMaxSecs: optionalStringDoubleMap(payload, 'perFilterMaxSecs'),
    );
    return jsonOk({'status': 'ok'});
  }

  Future<Response> _handleSequencerClearDefaultAdaptiveExposure(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/clear-default-adaptive-exposure');
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerClearDefaultAdaptiveExposure();
    return jsonOk({'status': 'ok'});
  }
}

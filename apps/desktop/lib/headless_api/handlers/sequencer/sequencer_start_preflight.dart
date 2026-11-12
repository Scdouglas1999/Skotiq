part of '../sequencer_handlers.dart';

/// Host-side pre-flight for the headless `load -> start` path: the save-path
/// restore, the unassignable-role refusal, wire validation and native device
/// wiring. The launch itself is `SequenceExecutor.startLoadedRun`.

/// A refusal the role gate raised inside `SequenceExecutor.startLoadedRun`,
/// carrying the answer to return.
class _StartRefused implements Exception {
  const _StartRefused(this.response);
  final Response response;
}

extension _SequencerStartPreflight on SequencerHandlers {
  /// Push the host's configured capture folder into the native executor.
  ///
  /// The native save path is per-process state; `imageOutputPath` is durable.
  /// Restart the appliance with the capture folder already configured and,
  /// without this restore:
  ///
  /// ```
  /// GET  /api/system/disk-space -> {"configured": true, "path": "C:\\", ...}
  /// POST /api/sequencer/start   -> 400 preflight_rejected
  ///        "This sequence captures frames but no image save path is
  ///         configured. Set the sequencer save path before starting ..."
  /// ```
  ///
  /// The appliance knew the folder and refused the run anyway. On an unattended
  /// rig, any restart — a power blip, the updater, a crash-and-relaunch —
  /// therefore costs the whole night, and the refusal names a setting the
  /// operator has already set.
  ///
  /// `_startNativeExecution` has always done this for the editor path
  /// (`sequence_executor.dart`, "only override the checkpoint's restored path
  /// when the user actually has one configured"). This is the same step,
  /// missing from the same seam as L22 and L29. The empty-path guard is kept
  /// for the same reason it exists there: pushing null would clobber a good
  /// checkpoint-restored path with "don't save".
  Future<void> _restoreNativeSavePath(SequencerBackend backend) async {
    try {
      await container.read(appSettingsProvider.future);
      final configured =
          container.read(appSettingsProvider).valueOrNull?.imageOutputPath ??
          '';
      if (configured.isEmpty) return;
      await backend.sequencerSetSavePath(configured);
    } catch (error) {
      // Non-fatal: the native save-path pre-flight is the backstop, and it
      // refuses the run with an operator-facing reason rather than capturing
      // frames into nowhere.
      _logWarning(
        '[API] POST /api/sequencer/start: could not restore the configured '
        'capture folder into the native executor ($error)',
      );
    }
  }

  /// The answer for a start refused because the operator's settings could not
  /// be pushed to the executor. A 5xx on purpose: unlike the bookkeeping rows,
  /// this is not recoverable after the fact, and it is the host that failed.
  Response _runConfigSeedRefusal(Object error) {
    _logWarning(
      '[API] POST /api/sequencer/start refused: the run configuration could '
      'not be pushed to the executor ($error)',
    );
    return jsonInternalServerError({
      'error': 'runtime_config_seed_failed',
      'message':
          'This run was not started because your sequencer settings could '
          'not be applied to the executor: $error. Starting anyway would '
          'have run the night on library defaults — image grading, the '
          'reject folder, the autofocus cadence and the dither settings all '
          'ignored — with nothing on the run record to say so.',
    });
  }

  /// Refuse a start whose sequence needs a guider, dome or cover calibrator
  /// that is not connected, returning the same `preflight_rejected` 400 the
  /// native refusals use.
  ///
  /// The Rust `collect_required_devices` walk gates the five roles
  /// `sequencerSetDevices` carries. These three are reached through
  /// `device_ops` with no id, so that walk structurally cannot see them and a
  /// `Dither`, `StartGuiding` or `CalibratorOn` node answers
  /// `{"status":"started"}` and then fails mid-run. Waiting cannot conjure a
  /// device nobody connected, so the
  /// recovery retries are futile by construction: refuse at Start, in the
  /// operator's terms, while there is still a night to save.
  ///
  /// The host is the only place with the answer, because it is the only place
  /// that knows what is connected.
  ///
  /// Returns null when the run may proceed. A device-listing failure also
  /// returns null: this gate exists to convert a mid-run death into an
  /// up-front refusal, and it must never become a new way to lose a night.
  Future<Response?> _refuseUnassignableRoles() async {
    final required = _lastLoadedWire?.unassignableRoleRequirements;
    if (required == null || required.isEmpty) return null;

    final Set<DeviceType> connected;
    try {
      final devices = await container
          .read(deviceBackendProvider)
          .getConnectedDevices();
      connected = devices.map((d) => d.deviceType).toSet();
    } catch (error) {
      _logWarning(
        '[API] POST /api/sequencer/start: could not list connected devices to '
        'pre-flight the guider/dome/cover roles ($error); letting the run '
        'proceed',
      );
      return null;
    }

    final missing = <DeviceType, String>{
      for (final entry in required.entries)
        if (!connected.contains(entry.key)) entry.key: entry.value,
    };
    if (missing.isEmpty) return null;

    final refusals = missing.entries
        .map((e) => _unassignableRoleRefusal(e.key, e.value))
        .join(' ');
    _logWarning('[API] POST /api/sequencer/start refused: $refusals');
    return jsonBadRequest({
      'error': 'preflight_rejected',
      'code': 'preflight_rejected',
      'message': refusals,
      'missingDevices': missing.keys.map((t) => t.name).toList(growable: false),
    });
  }

  /// Name the missing thing, then the consequence in the operator's terms —
  /// the same shape as the native `device_refusal` messages this joins.
  String _unassignableRoleRefusal(DeviceType role, String nodeName) =>
      switch (role) {
        DeviceType.guider =>
          'This sequence guides or dithers at "$nodeName", but no guider is '
              'connected. Connect the guider before starting — the step would '
              'otherwise fail mid-run and the recovery loop would wait for a '
              'guider that was never configured.',
        DeviceType.dome =>
          'This sequence moves the dome at "$nodeName", but no dome is '
              'connected. Connect it before starting — an unattended run would '
              'otherwise image into a closed dome or stall waiting for one.',
        DeviceType.coverCalibrator =>
          'This sequence drives the cover or flat panel at "$nodeName", but no '
              'cover calibrator is connected. Connect it before starting — the '
              'step would otherwise fail and any flats it was taking would be '
              'unusable.',
        _ =>
          'This sequence needs a ${role.name} at "$nodeName", but none is '
              'connected.',
      };

  /// Run the wire pre-flight and turn any blocking finding into the same 400
  /// body `SequenceValidationException` produces, so both start paths answer a
  /// remote dashboard identically. Returns null when the sequence may proceed;
  /// warnings are logged, never blocking.
  Response? _rejectInvalidWireSequence(String json) {
    final issues = validateSequenceWireJson(json);
    if (issues.isEmpty) return null;
    final errors = issues.where((i) => i.isError).toList(growable: false);
    for (final issue in issues.where((i) => !i.isError)) {
      _logger.warning(
        'sequencer load: ${issue.title} — ${issue.description}',
        source: 'SequencerHandlers',
      );
    }
    if (errors.isEmpty) return null;
    _logInfo(
      '[API] sequencer load rejected: ${errors.length} validation '
      'errors (${errors.map((e) => e.code).join(', ')})',
    );
    return jsonBadRequest(sequenceWireValidationBody(issues));
  }

  /// Turn a refusal raised by the native `SequenceExecutor::start()` into the
  /// structured answer the save-path endpoint already gives, instead of
  /// `500 internal_error`.
  ///
  /// Everything `start()` can return an `Err` for is a precondition it checks
  /// BEFORE launching the run — executor not idle, no sequence loaded, no
  /// device ops, no save path, no camera, no plate solver. None is a host
  /// fault, so none may carry a 5xx: a dashboard renders that as "internal
  /// error" and an unattended controller retries it, turning an
  /// operator-fixable setup mistake into a phantom appliance fault. The
  /// refusal text is already the right words; only the envelope changes.
  Response _nativeStartRefusal(Object error) {
    final native = error is bridge_api.SkotiqError
        ? error.maybeMap(
            operationFailed: (failure) => failure.field0,
            orElse: () => null,
          )
        : null;
    final message = native ?? error.toString();
    _logInfo('[API] POST /api/sequencer/start refused by pre-flight: $message');

    // "Cannot start: executor is Running" is a state conflict, not a bad
    // request: the caller's payload was fine, the appliance is simply busy.
    if (message.contains('Cannot start: executor is')) {
      return jsonConflict({'error': 'sequencer_busy', 'message': message});
    }
    return jsonBadRequest({
      'error': 'preflight_rejected',
      'code': 'preflight_rejected',
      'message': message,
    });
  }

  /// Push the currently-connected camera / mount / focuser / filter wheel /
  /// rotator into the native executor.
  ///
  /// The native executor resolves hardware through the ids handed to it by
  /// `sequencerSetDevices`, NOT through the device manager's connection table
  /// and NOT through the equipment profile. Those two can therefore disagree,
  /// and on the headless `load -> start` path they always did: nothing ever
  /// called `sequencerSetDevices`, so the executor's ids were all null while
  /// `GET /api/devices/connected` happily listed live hardware.
  ///
  /// [DeviceBackend.getConnectedDevices] is the same source
  /// `GET /api/devices/connected` renders, so after this call the executor and
  /// that endpoint agree by construction. First device of each type wins, which
  /// matches the single-rig assumption the rest of the headless API makes.
  ///
  /// A connected device wins, but where none is connected an id the caller
  /// assigned through `POST /api/sequencer/devices` is kept rather than
  /// overwritten with null. Without that fallback this method silently undid
  /// that endpoint — reproduced against the Linux appliance on 2026-08-09:
  ///
  /// ```
  /// POST /api/sequencer/devices {"cameraId":"sim_camera_1"} -> {"status":"ok"}
  /// POST /api/sequencer/start -> 400 {"error":"preflight_rejected",
  ///   "message":"... no camera is assigned to the run ..."}
  /// ```
  ///
  /// A camera *was* assigned, through the one endpoint that assigns it, and the
  /// appliance discarded it a line before reading it back and reporting it
  /// missing. `POST /api/sequencer/devices` is the only way a headless-only
  /// operator can assign hardware at all (see L9: `POST /api/profiles` cannot
  /// be driven), so a silent no-op there strands them with no path forward.
  ///
  /// A failure here is not fatal on its own: the native camera preflight in
  /// `SequenceExecutor::start()` refuses a capture sequence with no camera
  /// assigned, so a run that could not be wired is rejected loudly a moment
  /// later with an operator-facing reason rather than dying here with a 500.
  Future<void> _wireConnectedDevicesIntoNativeExecutor(
    SequencerBackend backend,
  ) async {
    final List<DeviceInfo> connected;
    try {
      connected = await container
          .read(deviceBackendProvider)
          .getConnectedDevices();
    } catch (e) {
      _logInfo(
        '[API] POST /api/sequencer/start: could not read connected devices '
        '($e); leaving the native executor device ids untouched',
      );
      return;
    }

    String? idFor(DeviceType type) {
      for (final device in connected) {
        if (device.deviceType == type) return device.id;
      }
      return _explicitlyAssignedDeviceIds[type];
    }

    final cameraId = idFor(DeviceType.camera);
    _logInfo(
      '[API] POST /api/sequencer/start: wiring devices into the native '
      'executor (camera=$cameraId)',
    );
    await backend.sequencerSetDevices(
      cameraId: cameraId,
      mountId: idFor(DeviceType.mount),
      focuserId: idFor(DeviceType.focuser),
      filterwheelId: idFor(DeviceType.filterWheel),
      rotatorId: idFor(DeviceType.rotator),
    );
  }
}

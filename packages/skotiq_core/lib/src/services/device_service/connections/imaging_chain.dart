part of '../../device_service.dart';

extension _DeviceServiceImagingChainConnections on DeviceService {
  Future<void> _bringUpCamera(String deviceId, String deviceName) async {
    final notifier = _ref.read(cameraStateProvider.notifier);
    notifier.setConnected();

    // A DSLR or mirrorless body keeps the ISO it is set to: the capture
    // settings take it from the body (syncExposureFromProfileProvider), and a
    // profile gain written over it would change the body behind the owner's
    // back. A camera without an offset control is not sent one.
    CameraCapabilities? capabilities;
    try {
      capabilities = await _backend.getCameraCapabilities(deviceId);
    } catch (e) {
      logSafely(
        _ref,
        (l) => l.warning(
          'Camera capabilities unknown at connect; keeping the camera\'s '
          'current gain or ISO and offset: $e',
          source: 'DeviceService',
        ),
      );
    }
    final takesGain =
        capabilities != null &&
        capabilities.canSetGain &&
        capabilities.isoSpeeds.isEmpty;
    final takesOffset = capabilities?.canSetOffset ?? false;

    // Apply active profile's cooling target temperature if available
    // and auto-start cooling if coolOnConnect is enabled
    try {
      final activeProfile = _ref.read(activeEquipmentProfileProvider);
      if (activeProfile?.defaultGain != null && takesGain) {
        try {
          await _backend.cameraSetGain(deviceId, activeProfile!.defaultGain!);
        } catch (e) {
          logSafely(
            _ref,
            (l) => l.warning(
              'Profile gain could not be applied on connect: $e',
              source: 'DeviceService',
            ),
          );
        }
      }
      if (activeProfile?.defaultOffset != null && takesOffset) {
        try {
          await _backend.cameraSetOffset(
            deviceId,
            activeProfile!.defaultOffset!,
          );
        } catch (e) {
          logSafely(
            _ref,
            (l) => l.warning(
              'Profile offset could not be applied on connect: $e',
              source: 'DeviceService',
            ),
          );
        }
      }
      if (activeProfile?.defaultCoolingTemp != null) {
        notifier.setTargetTemp(activeProfile!.defaultCoolingTemp!);

        if (activeProfile.coolOnConnect) {
          await _backend.cameraSetCooling(
            deviceId: deviceId,
            enabled: true,
            targetTemp: activeProfile.defaultCoolingTemp,
          );
          notifier.setCooling(true);
        }
      }
    } catch (e) {
      logSafely(
        _ref,
        (l) => l.warning(
          'Cool-on-connect failed (profile lookup or cooling command): $e',
          source: 'DeviceService',
        ),
      );
    }

    // Auto-detect manufacturer-recommended gain/offset from the
    // camera SDK and populate the active equipment profile when the user
    // has NOT explicitly set those values. We never overwrite an existing
    // profile value — the SDK recommendation is a starting point, not an
    // override of the user's deliberate choice.
    //
    // Failures here are non-fatal: connection has already succeeded, and
    // a missing recommendation is the honest "the SDK didn't tell us"
    // answer (most ASCOM/Alpaca/INDI cameras, and several native vendors,
    // don't expose this). The user can still set values manually.
    await _autoApplyRecommendedCameraSettings(deviceId, deviceName);

    // Start temperature polling (this will immediately poll and update)
    _temperaturePoller.start(deviceId);
  }

  /// Public re-entry point: re-query the SDK for the recommendation. Used by
  /// the equipment-screen "Auto-detect" button.
  ///
  /// Returns the raw [CameraRecommendedSettings] from the backend so the UI
  /// can present the values BEFORE deciding whether to apply them.
  Future<CameraRecommendedSettings> _queryRecommendedCameraSettings(
    String deviceId,
  ) {
    return _backend.cameraGetRecommendedSettings(deviceId);
  }

  /// Public re-entry point: apply a recommendation to the active profile,
  /// overwriting whatever was there. Used by the equipment-screen
  /// "Auto-detect" UI when the user explicitly confirms the apply.
  ///
  /// Returns true if at least one field was updated.
  Future<bool> _applyRecommendedCameraSettings(
    CameraRecommendedSettings rec,
  ) async {
    final activeProfile = _ref.read(activeEquipmentProfileProvider);
    if (activeProfile == null || activeProfile.id == null) {
      return false;
    }
    if (rec.unityGain == null && rec.defaultOffset == null) {
      return false;
    }

    final updated = activeProfile.copyWith(
      defaultGain: rec.unityGain ?? activeProfile.defaultGain,
      defaultOffset: rec.defaultOffset ?? activeProfile.defaultOffset,
    );
    final notifier = _ref.read(equipmentProfilesProvider.notifier);
    await notifier.saveProfile(updated);
    return true;
  }

  Future<void> _setCameraCooling({
    required bool enabled,
    double? targetTemp,
  }) async {
    // Defense-in-depth: reject a non-finite setpoint before it reaches the
    // driver. The GUI dialog already validates its text field, but non-UI
    // callers (headless API, sequencer instructions, tests) route through here
    // too, and a NaN/±∞ setpoint would either be silently coerced by the
    // driver or corrupt the cooler control loop. A null target is the valid
    // "disable cooling" / "keep current setpoint" case and is left untouched.
    if (targetTemp != null && !targetTemp.isFinite) {
      throw ArgumentError.value(
        targetTemp,
        'targetTemp',
        'Cooling target temperature must be a finite value',
      );
    }

    final cameraState = _ref.read(cameraStateProvider);
    if (cameraState.connectionState != DeviceConnectionState.connected) {
      throw const ConnectionException(
        message: 'Camera not connected',
        userMessage: 'The camera is not connected',
      );
    }

    // Use the connected device's ID from state, not the profile
    final deviceId = cameraState.deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      throw const ConnectionException(
        message: 'No camera device ID available',
        userMessage: 'The camera device is not available',
      );
    }

    await _backend.cameraSetCooling(
      deviceId: deviceId,
      enabled: enabled,
      targetTemp: targetTemp,
    );
    if (enabled && targetTemp != null) {
      _ref.read(cameraCoolingGoalProvider.notifier).state = targetTemp;
    }
  }

  /// Gradually warm the camera by stepping the target temperature up
  /// until the cooler power drops near 0%, then disabling the cooler.
  ///
  /// Delegates to [CameraWarmupController] — see that class for the full
  /// algorithm and rationale.
  ///
  /// On a remote client the host runs the ramp, next to the camera, so it
  /// continues when this client leaves and any client can cancel it.
  Future<CameraWarmupOutcome> _warmCamera({double ratePerMin = 2.0}) async {
    final host = _hostDevices;
    if (host == null) {
      return _warmupController.start(ratePerMin: ratePerMin);
    }
    final name = await host.cameraStartHostWarmUp(ratePerMin: ratePerMin);
    final outcome = CameraWarmupOutcome.values.firstWhere(
      (value) => value.name == name,
      orElse: () => CameraWarmupOutcome.started,
    );
    if (outcome == CameraWarmupOutcome.started) {
      _ref.read(cameraStateProvider.notifier).setWarming(true);
      _followHostWarmUp(host);
    }
    return outcome;
  }

  /// Cancel an in-progress gradual warm-up. See [CameraWarmupController.cancel].
  ///
  /// On a remote client only an operator's cancel (restoring the prior
  /// set-point) reaches the host. The other callers send their own cooler
  /// command next, which the host treats as replacing its warm-up, or are
  /// tearing this client down, which must leave the host's warm-up running.
  void _cancelWarmCamera({bool restorePriorSetting = true}) {
    final host = _hostDevices;
    if (host == null) {
      _warmupController.cancel(restorePriorSetting: restorePriorSetting);
      return;
    }
    if (!restorePriorSetting) return;
    _hostWarmUpWatch?.cancel();
    _hostWarmUpWatch = null;
    _ref.read(cameraStateProvider.notifier).setWarming(false);
    unawaited(
      host.cameraCancelHostWarmUp(restorePriorSetting: true).catchError((
        Object e,
      ) {
        _ref
            .read(loggingServiceProvider)
            .error(
              'Could not cancel the warm-up on the imaging host: $e',
              source: 'DeviceService',
            );
      }),
    );
  }

  /// Show the host's warm-up as running until the host reports it over.
  void _followHostWarmUp(HostDeviceControl host) {
    _hostWarmUpWatch?.cancel();
    _hostWarmUpWatch = Timer.periodic(const Duration(seconds: 10), (_) async {
      bool warming;
      try {
        warming = await host.cameraHostIsWarming();
      } catch (_) {
        return;
      }
      if (_disposed || warming) return;
      _hostWarmUpWatch?.cancel();
      _hostWarmUpWatch = null;
      _ref.read(cameraStateProvider.notifier).setWarming(false);
    });
  }

  Future<void> _coolerOffForDisconnect(String deviceId) async {
    final notifier = _ref.read(cameraStateProvider.notifier);
    final state = _ref.read(cameraStateProvider);
    // Best-effort cooler shutdown: ASCOM/INDI driver-side coolers keep
    // running after the client disconnects, so an intentional
    // disconnect with the cooler at setpoint would silently keep
    // pulling power (and surprise the user packing up the rig).
    // Fail-soft — an unreachable driver must not block the disconnect.
    if (state.isCooling) {
      try {
        await _backend.cameraSetCooling(deviceId: deviceId, enabled: false);
        notifier.setCooling(false);
        logSafely(
          _ref,
          (l) => l.info(
            'Cooler disabled as part of camera disconnect',
            source: 'DeviceService',
          ),
        );
      } catch (e) {
        logSafely(
          _ref,
          (l) => l.warning(
            'Could not disable cooler during disconnect: $e',
            source: 'DeviceService',
          ),
        );
      }
    }
  }

  Future<void> _bringUpMount(String deviceId, String deviceName) async {
    final notifier = _ref.read(mountStateProvider.notifier);
    notifier.setConnected();

    // Fetch actual mount status from hardware instead of hardcoding defaults
    try {
      final status = await _backend.getMountStatus(deviceId);
      notifier.updatePosition(
        status.rightAscension,
        status.declination,
        status.altitude,
        status.azimuth,
      );
      notifier.setParked(status.parked);
      notifier.setTracking(status.tracking);
      notifier.setSlewing(status.slewing);
    } catch (e) {
      // If status query fails, log but don't fail the connection
      logSafely(
        _ref,
        (l) => l.warning(
          'Failed to get initial mount status for ($deviceId): $e',
          source: 'DeviceService',
        ),
      );
    }

    // Compare the mount's idea of where and when it is against this
    // computer's. Entirely fail-soft: a mount that cannot answer, a
    // driver that has no site commands, or a serial hiccup must never
    // turn a working connection into a failed one, so everything here
    // is inside its own guard and nothing rethrows.
    unawaited(_reconcileMountSite(deviceId, deviceName));
  }

  /// Read the mount's site/time and either apply the operator's standing
  /// preference or raise a comparison for them to decide on.
  ///
  /// Runs detached from the connect future: the operator should not wait on a
  /// serial site query to see their mount come up, and a mount that never
  /// answers must not hold the connection open.
  Future<void> _reconcileMountSite(String deviceId, String deviceName) async {
    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings == null) return;

      final mode = settings.mountSiteSyncMode;
      if (mode == 'never') return;

      final comparison = await _ref
          .read(mountSiteReconcilerProvider)
          .compare(
            deviceId: deviceId,
            deviceName: deviceName,
            computerLatitudeDeg: settings.latitude,
            computerLongitudeDeg: settings.longitude,
            computerElevationM: settings.elevation,
          );

      final elevation = comparison.elevationToAdopt;
      if (elevation != null) {
        await _ref
            .read(appSettingsProvider.notifier)
            .updateLocation(elevation: elevation);
        logSafely(
          _ref,
          (l) => l.info(
            'The site elevation was not set; using the '
            '${elevation.toStringAsFixed(0)} m that $deviceName reports',
            source: 'DeviceService',
          ),
        );
      }

      if (!comparison.needsAttention) return;

      switch (mode) {
        case 'computerToMount':
          await _applyStandingPreference(
            comparison,
            MountSiteSyncDirection.computerToMount,
          );
        case 'mountToComputer':
          await _applyStandingPreference(
            comparison,
            MountSiteSyncDirection.mountToComputer,
          );
        default:
          _ref
              .read(pendingMountSiteReconciliationProvider.notifier)
              .raise(comparison);
      }
    } catch (e) {
      logSafely(
        _ref,
        (l) => l.warning(
          'Mount site/time reconciliation skipped for ($deviceId): $e',
          source: 'DeviceService',
        ),
      );
    }
  }

  Future<void> _applyStandingPreference(
    MountSiteReconciliation comparison,
    MountSiteSyncDirection direction,
  ) async {
    if (!comparison.canApply(direction)) {
      // The operator asked for a direction this mount cannot do. Say so once
      // rather than silently doing nothing every single connect.
      logSafely(
        _ref,
        (l) => l.warning(
          'Mount ${comparison.deviceId} cannot sync '
          '${direction.name}: ${comparison.unavailableReason(direction)}',
          source: 'DeviceService',
        ),
      );
      return;
    }

    final failures = await _ref
        .read(mountSiteReconcilerProvider)
        .apply(comparison, direction);
    if (failures.isEmpty) {
      logSafely(
        _ref,
        (l) => l.info(
          'Mount ${comparison.deviceId} site/time synced ${direction.name}',
          source: 'DeviceService',
        ),
      );
    } else {
      logSafely(
        _ref,
        (l) => l.warning(
          'Mount ${comparison.deviceId} site/time sync '
          '${direction.name} partially failed: ${failures.join('; ')}',
          source: 'DeviceService',
        ),
      );
    }
  }

  Future<void> _bringUpFocuser(String deviceId) async {
    final notifier = _ref.read(focuserStateProvider.notifier);
    // Get actual focuser status from the backend (now typed FocuserStatus).
    // Some drivers (notably INDI) stream device properties asynchronously
    // AFTER the connection is established, so an immediate status read can
    // race the property stream and throw ("Position not available") even
    // though the focuser is connected and movable. The connection itself is
    // up — retry the initial snapshot for a couple of seconds before giving
    // up, mirroring the filter-wheel encoder-settle poll.
    FocuserStatus? status;
    Object? lastStatusError;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        status = await _backend.getFocuserStatus(deviceId);
        break;
      } catch (e) {
        lastStatusError = e;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    if (status == null) {
      throw StateError(
        'The focuser opened but did not report its position: '
        '${connectFailureReason(lastStatusError!)}',
      );
    }

    notifier.setConnected(
      maxPosition: status.maxPosition,
      stepSize: status.stepSize,
      isAbsolute: status.isAbsolute,
      hasTemperature: status.hasTemperature,
    );
    notifier.updatePosition(status.position);
    notifier.setMoving(status.moving);
    if (status.temperature != null) {
      notifier.updateTemperature(status.temperature!);
    }
  }

  Future<void> _bringUpFilterWheel(String deviceId, String deviceName) async {
    final notifier = _ref.read(filterWheelStateProvider.notifier);
    final logger = _ref.read(loggingServiceProvider);
    // Give the filter wheel firmware time to synchronise the actual
    // encoder position after the USB/COM connection is established.
    // Some SDKs (ZWO EFW, ASCOM wrappers) report position 0 or -1
    // immediately after opening before the firmware has read the encoder.
    // Allow up to 10 s for a stable reading. Empirical testing on a ZWO
    // EFW after an unclean process restart showed that the SDK can remain
    // at -1 for more than 3 s even though the wheel is healthy; rejecting
    // it that early caused a noisy disconnect/reconnect cycle at startup.
    FilterWheelStatus status;
    int pollAttempts = 0;
    const maxPolls = 20;
    const pollDelay = Duration(milliseconds: 500);

    status = await _backend.getFilterWheelStatus(deviceId);
    logger.debug(
      'Filter wheel poll #0: position=${status.position}, '
      'moving=${status.moving}',
      source: 'DeviceService',
    );

    // Keep polling while position is -1 (moving/initializing)
    while (status.position < 0 && pollAttempts < maxPolls) {
      pollAttempts++;
      await Future.delayed(pollDelay);
      status = await _backend.getFilterWheelStatus(deviceId);
      logger.debug(
        'Filter wheel poll #$pollAttempts: position=${status.position}, '
        'moving=${status.moving}',
        source: 'DeviceService',
      );
    }

    logger.debug(
      'Filter wheel final status: ${status.filterNames.length} filter '
      'names=${status.filterNames}, position=${status.position}',
      source: 'DeviceService',
    );
    if (status.position < 0) {
      throw StateError(
        'Filter wheel connected but did not report a valid position '
        'after ${maxPolls + 1} status reads',
      );
    }

    notifier.setConnected(filterNames: status.filterNames);
    notifier.setDeviceName(deviceName);
    notifier.updatePosition(status.position);
    notifier.setMoving(status.moving);
    // Seed the per-wheel "last applied offset" baseline with the CURRENT
    // filter's configured offset. The map entry is cleared on disconnect,
    // so without this seed the first filter change after a reconnect
    // computes its focuser delta against 0 — double-applying an offset
    // that is already physically embodied in the focuser position (the
    // rig was focused with the current filter in place).
    if (status.position >= 0 && status.position < status.filterNames.length) {
      _lastAppliedFilterOffsetByWheel[deviceId] =
          _resolveConfiguredFilterOffset(status.filterNames[status.position]);
    }

    // After connection, sync profile/session filter names to the native
    // driver so user-defined names (Ha, OIII, SII, etc.) are used in
    // sequences and UI instead of generic "Filter 1", "Filter 2".
    await _syncFilterNamesToDriver(status.filterNames);
  }
}

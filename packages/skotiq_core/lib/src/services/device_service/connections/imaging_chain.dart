part of '../../device_service.dart';

extension _DeviceServiceImagingChainConnections on DeviceService {
  /// Connect to a camera
  Future<void> _connectCamera(String deviceId) {
    return _trackInFlight(() async {
      final notifier = _ref.read(cameraStateProvider.notifier);

      // Structural format check only — discovery is not a precondition for
      // connect. The backend's `connectDevice` decides reachability; see
      // [InvalidDeviceIdException].
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('camera', deviceId);
      }

      final deviceName = await _resolveDeviceDisplayName(
        DeviceType.camera,
        deviceId,
      );
      // Hand the type slot over cleanly rather than orphaning the
      // incumbent's driver connection (see [_releaseDisplacedDevice]).
      await _releaseDisplacedDevice(DeviceType.camera, deviceId);

      notifier.setConnecting(deviceId, deviceName);

      try {
        // Connect via native bridge
        await _backend.connectDevice(DeviceType.camera, deviceId);

        notifier.setConnected();

        // Apply active profile's cooling target temperature if available
        // and auto-start cooling if coolOnConnect is enabled
        try {
          final activeProfile = _ref.read(activeEquipmentProfileProvider);
          if (activeProfile?.defaultGain != null) {
            try {
              await _backend.cameraSetGain(
                deviceId,
                activeProfile!.defaultGain!,
              );
            } catch (e) {
              _safeLog(
                (l) => l.warning(
                  'Profile gain could not be applied on connect: $e',
                  source: 'DeviceService',
                ),
                'profile-gain-on-connect',
              );
            }
          }
          if (activeProfile?.defaultOffset != null) {
            try {
              await _backend.cameraSetOffset(
                deviceId,
                activeProfile!.defaultOffset!,
              );
            } catch (e) {
              _safeLog(
                (l) => l.warning(
                  'Profile offset could not be applied on connect: $e',
                  source: 'DeviceService',
                ),
                'profile-offset-on-connect',
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
          _safeLog(
            (l) => l.warning(
              'Cool-on-connect failed (profile lookup or cooling command): $e',
              source: 'DeviceService',
            ),
            'cool-on-connect',
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

        // Start heartbeat monitoring (10 second interval). Optional —
        // failures inside DeviceHeartbeatRouter.start are logged but
        // never thrown so connect cannot fail on a missing heartbeat.
        await _heartbeat.start(
          deviceType: DeviceType.camera,
          deviceId: deviceId,
          intervalMs: 10000,
        );
      } catch (e) {
        notifier.setDisconnected();
        rethrow;
      }
    });
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
    await notifier.updateProfile(updated);
    return true;
  }

  /// Set camera cooling
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
  }

  /// Gradually warm the camera by stepping the target temperature up
  /// until the cooler power drops near 0%, then disabling the cooler.
  ///
  /// Delegates to [CameraWarmupController] — see that class for the full
  /// algorithm and rationale.
  Future<void> _warmCamera({double ratePerMin = 2.0}) =>
      _warmupController.start(ratePerMin: ratePerMin);

  /// Cancel an in-progress gradual warm-up.
  /// The cooler remains in whatever state it was in at the time of cancellation.
  void _cancelWarmCamera() => _warmupController.cancel();

  /// Disconnect camera
  Future<void> _disconnectCamera() {
    return _trackInFlight(() async {
      // Cancel any warming in progress
      _cancelWarmCamera();
      // Stop temperature polling first
      _temperaturePoller.stop();

      final notifier = _ref.read(cameraStateProvider.notifier);
      final state = _ref.read(cameraStateProvider);

      // Audit surface "nothing connected" as a typed precondition
      // instead of a silent no-op so the equipment screen's bulk-disconnect
      // sweep can distinguish "already disconnected" (skip cleanly) from
      // "real disconnect failure" (toast + log).
      final deviceId = state.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        throw const DeviceNotConnectedException('camera');
      }

      _markUserInitiatedDisconnect(deviceId);
      try {
        // Best-effort cooler shutdown: ASCOM/INDI driver-side coolers keep
        // running after the client disconnects, so an intentional
        // disconnect with the cooler at setpoint would silently keep
        // pulling power (and surprise the user packing up the rig).
        // Fail-soft — an unreachable driver must not block the disconnect.
        if (state.isCooling) {
          try {
            await _backend.cameraSetCooling(deviceId: deviceId, enabled: false);
            notifier.setCooling(false);
            _safeLog(
              (l) => l.info(
                'Cooler disabled as part of camera disconnect',
                source: 'DeviceService',
              ),
              'disconnect-cooler-off',
            );
          } catch (e) {
            _safeLog(
              (l) => l.warning(
                'Could not disable cooler during disconnect: $e',
                source: 'DeviceService',
              ),
              'disconnect-cooler-off',
            );
          }
        }

        // Stop heartbeat monitoring. DeviceHeartbeatRouter.stop is
        // fail-soft: it logs and swallows so the disconnect proceeds
        // even if the driver is already gone.
        await _heartbeat.stop(
          deviceType: DeviceType.camera,
          deviceId: deviceId,
        );

        // Disconnect device
        await _backend.disconnectDevice(DeviceType.camera, deviceId);
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        _temperaturePoller.start(deviceId);
        await _heartbeat.start(
          deviceType: DeviceType.camera,
          deviceId: deviceId,
          intervalMs: 10000,
        );
        rethrow;
      }
      notifier.setDisconnected();
    });
  }

  /// Connect to a mount
  Future<void> _connectMount(String deviceId) {
    return _trackInFlight(() async {
      final notifier = _ref.read(mountStateProvider.notifier);

      // Format check only; backend is the source of truth for
      // reachability. See [connectCamera] for the full rationale.
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('mount', deviceId);
      }

      final deviceName = await _resolveDeviceDisplayName(
        DeviceType.mount,
        deviceId,
      );
      // Hand the type slot over cleanly rather than orphaning the
      // incumbent's driver connection (see [_releaseDisplacedDevice]).
      await _releaseDisplacedDevice(DeviceType.mount, deviceId);

      notifier.setConnecting(deviceId, deviceName);

      try {
        await _backend.connectDevice(DeviceType.mount, deviceId);

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
          _safeLog(
            (l) => l.warning(
              'Failed to get initial mount status for ($deviceId): $e',
              source: 'DeviceService',
            ),
            'mount-initial-status-fail',
          );
        }

        // Start heartbeat monitoring (10 second interval) for critical
        // device. Fail-soft inside DeviceHeartbeatRouter.start so a
        // missing heartbeat cannot abort connect.
        await _heartbeat.start(
          deviceType: DeviceType.mount,
          deviceId: deviceId,
          intervalMs: 10000,
        );

        // Compare the mount's idea of where and when it is against this
        // computer's. Entirely fail-soft: a mount that cannot answer, a
        // driver that has no site commands, or a serial hiccup must never
        // turn a working connection into a failed one, so everything here
        // is inside its own guard and nothing rethrows.
        unawaited(_reconcileMountSite(deviceId, deviceName));
      } catch (e) {
        notifier.setDisconnected();
        rethrow;
      }
    });
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
      _safeLog(
        (l) => l.warning(
          'Mount site/time reconciliation skipped for ($deviceId): $e',
          source: 'DeviceService',
        ),
        'mount-site-reconcile-fail',
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
      _safeLog(
        (l) => l.warning(
          'Mount ${comparison.deviceId} cannot sync '
          '${direction.name}: ${comparison.unavailableReason(direction)}',
          source: 'DeviceService',
        ),
        'mount-site-direction-unavailable',
      );
      return;
    }

    final failures = await _ref
        .read(mountSiteReconcilerProvider)
        .apply(comparison, direction);
    if (failures.isEmpty) {
      _safeLog(
        (l) => l.info(
          'Mount ${comparison.deviceId} site/time synced ${direction.name}',
          source: 'DeviceService',
        ),
        'mount-site-synced',
      );
    } else {
      _safeLog(
        (l) => l.warning(
          'Mount ${comparison.deviceId} site/time sync '
          '${direction.name} partially failed: ${failures.join('; ')}',
          source: 'DeviceService',
        ),
        'mount-site-sync-partial',
      );
    }
  }

  /// Disconnect mount
  Future<void> _disconnectMount() {
    return _trackInFlight(() async {
      final notifier = _ref.read(mountStateProvider.notifier);
      final state = _ref.read(mountStateProvider);

      // Audit see [disconnectCamera] for the rationale.
      final deviceId = state.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        throw const DeviceNotConnectedException('mount');
      }

      // A card asking about this mount must not outlive it.
      _ref
          .read(pendingMountSiteReconciliationProvider.notifier)
          .clearFor(deviceId);
      _markUserInitiatedDisconnect(deviceId);

      try {
        // Stop heartbeat monitoring; fail-soft inside the router so the
        // matching disconnectDevice call below proceeds regardless.
        await _heartbeat.stop(deviceType: DeviceType.mount, deviceId: deviceId);

        await _backend.disconnectDevice(DeviceType.mount, deviceId);
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        await _heartbeat.start(
          deviceType: DeviceType.mount,
          deviceId: deviceId,
          intervalMs: 10000,
        );
        rethrow;
      }
      notifier.setDisconnected();
    });
  }

  /// Connect to a focuser
  Future<void> _connectFocuser(String deviceId) {
    return _trackInFlight(() async {
      final notifier = _ref.read(focuserStateProvider.notifier);

      // Format check only; backend is the source of truth for
      // reachability. See [connectCamera] for the full rationale.
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('focuser', deviceId);
      }

      final deviceName = await _resolveDeviceDisplayName(
        DeviceType.focuser,
        deviceId,
      );
      // Hand the type slot over cleanly rather than orphaning the
      // incumbent's driver connection (see [_releaseDisplacedDevice]).
      await _releaseDisplacedDevice(DeviceType.focuser, deviceId);

      notifier.setConnecting(deviceId, deviceName);

      try {
        await _backend.connectDevice(DeviceType.focuser, deviceId);

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
            'Focuser connected but did not report status in time '
            '(driver property stream too slow): $lastStatusError',
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
        await _heartbeat.start(
          deviceType: DeviceType.focuser,
          deviceId: deviceId,
          intervalMs: 10000,
        );
      } catch (e) {
        try {
          await _backend.disconnectDevice(DeviceType.focuser, deviceId);
        } catch (_) {
          // The connect itself may have failed before the backend registered
          // the device. Preserve the original, more useful failure.
        }
        notifier.setDisconnected();
        rethrow;
      }
    });
  }

  /// Disconnect focuser
  Future<void> _disconnectFocuser() {
    return _trackInFlight(() async {
      final notifier = _ref.read(focuserStateProvider.notifier);
      final state = _ref.read(focuserStateProvider);

      // Audit see [disconnectCamera] for the rationale.
      final deviceId = state.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        throw const DeviceNotConnectedException('focuser');
      }

      _markUserInitiatedDisconnect(deviceId);
      _focuserVerifyGeneration++;

      try {
        await _heartbeat.stop(
          deviceType: DeviceType.focuser,
          deviceId: deviceId,
        );
        await _backend.disconnectDevice(DeviceType.focuser, deviceId);
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        await _heartbeat.start(
          deviceType: DeviceType.focuser,
          deviceId: deviceId,
          intervalMs: 10000,
        );
        rethrow;
      }
      notifier.setDisconnected();
    });
  }

  /// Connect to a filter wheel
  Future<void> _connectFilterWheel(String deviceId) {
    return _trackInFlight(() async {
      final notifier = _ref.read(filterWheelStateProvider.notifier);
      final logger = _ref.read(loggingServiceProvider);

      // Format check only; backend is the source of truth for
      // reachability. See [connectCamera] for the full rationale.
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('filter wheel', deviceId);
      }

      // Derive a friendly name without running discovery.
      // Discovery opens/closes hardware (e.g. ZWO EFW via native SDK) which
      // can interfere with subsequent position reads.  The device manager will
      // register the full DeviceInfo during api_connect_device anyway.
      final deviceName = await _resolveDeviceDisplayName(
        DeviceType.filterWheel,
        deviceId,
      );

      // Hand the type slot over cleanly rather than orphaning the
      // incumbent's driver connection (see [_releaseDisplacedDevice]).
      await _releaseDisplacedDevice(DeviceType.filterWheel, deviceId);

      notifier.setConnecting(deviceId, deviceName);

      try {
        await _backend.connectDevice(DeviceType.filterWheel, deviceId);

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
        await _heartbeat.start(
          deviceType: DeviceType.filterWheel,
          deviceId: deviceId,
          intervalMs: 10000,
        );

        // Seed the per-wheel "last applied offset" baseline with the CURRENT
        // filter's configured offset. The map entry is cleared on disconnect,
        // so without this seed the first filter change after a reconnect
        // computes its focuser delta against 0 — double-applying an offset
        // that is already physically embodied in the focuser position (the
        // rig was focused with the current filter in place).
        if (status.position >= 0 &&
            status.position < status.filterNames.length) {
          _lastAppliedFilterOffsetByWheel[deviceId] =
              _resolveConfiguredFilterOffset(
                status.filterNames[status.position],
              );
        }

        // After connection, sync profile/session filter names to the native
        // driver so user-defined names (Ha, OIII, SII, etc.) are used in
        // sequences and UI instead of generic "Filter 1", "Filter 2".
        await _syncFilterNamesToDriver(status.filterNames);
      } catch (e) {
        try {
          await _backend.disconnectDevice(DeviceType.filterWheel, deviceId);
        } catch (_) {
          // Preserve the original connect/status failure.
        }
        notifier.setDisconnected();
        rethrow;
      }
    });
  }

  /// Disconnect filter wheel
  Future<void> _disconnectFilterWheel() {
    return _trackInFlight(() async {
      final notifier = _ref.read(filterWheelStateProvider.notifier);
      final state = _ref.read(filterWheelStateProvider);

      // Audit see [disconnectCamera] for the rationale.
      final deviceId = state.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        throw const DeviceNotConnectedException('filter wheel');
      }

      _markUserInitiatedDisconnect(deviceId);
      _filterWheelVerifyGeneration++;

      try {
        await _heartbeat.stop(
          deviceType: DeviceType.filterWheel,
          deviceId: deviceId,
        );
        await _backend.disconnectDevice(DeviceType.filterWheel, deviceId);
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        await _heartbeat.start(
          deviceType: DeviceType.filterWheel,
          deviceId: deviceId,
          intervalMs: 10000,
        );
        rethrow;
      }
      _lastAppliedFilterOffsetByWheel.remove(deviceId);
      notifier.setDisconnected();
    });
  }
}

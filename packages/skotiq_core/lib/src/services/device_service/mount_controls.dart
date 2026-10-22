part of '../device_service.dart';

extension _DeviceServiceMountControls on DeviceService {
  // Mount control

  /// Get the currently connected mount device ID.
  Future<String?> _getMountDeviceId() async {
    final mountState = _ref.read(mountStateProvider);
    if (mountState.connectionState == DeviceConnectionState.connected &&
        mountState.deviceId != null &&
        mountState.deviceId!.isNotEmpty) {
      return mountState.deviceId;
    }
    // An active profile identifies the mount the user intends to connect; it
    // does not prove that device is live on the current backend. Falling back
    // to it here allowed a command admitted just before a disconnect/backend
    // swap to target a disconnected or different host.
    return null;
  }

  /// Slew the mount to J2000 coordinates and wait until it is there.
  ///
  /// The backend call returns once the driver has accepted the slew, not when
  /// the mount arrives, so completion is decided by [MountSlewWatcher] from the
  /// mount's own status. While it watches, [mountSlewProgressProvider] and the
  /// slew operation's step say how far the mount still has to go.
  Future<void> _slewMountToCoordinates(double ra, double dec) async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    final mountNotifier = _ref.read(mountStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);
    final progressNotifier = _ref.read(mountSlewProgressProvider.notifier);
    _slewWatchReleasedReason = null;
    final generation = ++_slewWatchGeneration;

    mountNotifier.setSlewing(true);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.slewToTarget,
      description:
          'Slewing to RA '
          '${CoordinateFormat.raHm(ra, style: SexagesimalStyle.plainLetters)}, '
          'Dec ${CoordinateFormat.decDecimal(dec)}',
      canCancel: true,
    );

    try {
      await _backend.mountSlewToCoordinates(deviceId, ra, dec);
      mountNotifier.setParked(false);
      final watcher = _ref.read(mountSlewWatcherFactoryProvider)(
        readStatus: () => _backend.getMountStatus(deviceId),
        targetRa: ra,
        targetDec: dec,
        isCancelled: () =>
            _disposed ||
            generation != _slewWatchGeneration ||
            _ref.read(mountStateProvider).deviceId != deviceId,
        onProgress: (progress) {
          if (_disposed || generation != _slewWatchGeneration) return;
          progressNotifier.state = progress;
          operationsNotifier.updateProgress(
            OperationType.slewToTarget,
            progress: progress.fraction,
            currentStep:
                'Slewing, ${formatSlewDistance(progress.remainingDegrees)} '
                'to go',
            operationId: operationId,
          );
        },
      );
      final MountStatus arrived;
      try {
        arrived = await watcher.watch();
      } on MountSlewException {
        final released = _slewWatchReleasedReason;
        if (generation != _slewWatchGeneration && released != null) {
          throw MountSlewException(released);
        }
        rethrow;
      }
      mountNotifier.updatePosition(
        arrived.rightAscension,
        arrived.declination,
        arrived.altitude,
        arrived.azimuth,
      );
    } finally {
      if (!_disposed && generation == _slewWatchGeneration) {
        mountNotifier.setSlewing(false);
        progressNotifier.state = null;
      }
      operationsNotifier.completeOperation(
        OperationType.slewToTarget,
        operationId: operationId,
      );
    }
  }

  /// Format RA for display (hours:minutes)
  /// Sync mount to coordinates
  Future<void> _syncMountToCoordinates(double ra, double dec) async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    await _backend.mountSync(deviceId, ra, dec);

    // Update local state
    final mountNotifier = _ref.read(mountStateProvider.notifier);
    mountNotifier.updatePosition(ra, dec, 0.0, 0.0);
  }

  /// Park the mount
  Future<void> _parkMount() async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    final mountNotifier = _ref.read(mountStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);

    mountNotifier.setSlewing(true);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.parkMount,
      description: 'Parking mount',
    );

    try {
      await _backend.mountPark(deviceId);
      mountNotifier.setParked(true);
      mountNotifier.setTracking(false);
    } finally {
      mountNotifier.setSlewing(false);
      operationsNotifier.completeOperation(
        OperationType.parkMount,
        operationId: operationId,
      );
    }
  }

  /// Unpark the mount
  Future<void> _unparkMount() async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.unparkMount,
      description: 'Unparking mount',
    );

    try {
      await _backend.mountUnpark(deviceId);
      final mountNotifier = _ref.read(mountStateProvider.notifier);
      mountNotifier.setParked(false);
    } finally {
      operationsNotifier.completeOperation(
        OperationType.unparkMount,
        operationId: operationId,
      );
    }
  }

  /// Enable or disable mount tracking
  Future<void> _setMountTracking(bool enabled) async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    await _backend.mountSetTracking(deviceId, enabled);
    final mountNotifier = _ref.read(mountStateProvider.notifier);
    mountNotifier.setTracking(enabled);
  }

  /// Set mount tracking rate
  Future<void> _setMountTrackingRate(int rate) async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    await _backend.mountSetTrackingRate(deviceId, rate);
    final mountNotifier = _ref.read(mountStateProvider.notifier);
    // Update the state with the new tracking rate
    mountNotifier.setTrackingRate(TrackingRate.values[rate]);
  }

  /// Abort mount slew (emergency stop)
  Future<void> _abortMountSlew() async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    final mountNotifier = _ref.read(mountStateProvider.notifier);
    // Ends a home in progress too: the home watcher reads this flag and stops
    // waiting for a mount the operator has just stopped.
    mountNotifier.setHoming(false);
    // Ends a slew watch the same way: the slew command then reports that it
    // was stopped instead of waiting for an arrival that will not come.
    _slewWatchReleasedReason = null;
    _slewWatchGeneration++;
    _ref.read(mountSlewProgressProvider.notifier).state = null;
    await _backend.mountAbort(deviceId);
    mountNotifier.setSlewing(false);
  }

  /// Slew mount to horizontal (alt/az) coordinates
  Future<void> _slewMountToAltAz(double altitude, double azimuth) async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    final mountNotifier = _ref.read(mountStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);

    mountNotifier.setSlewing(true);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.slewToTarget,
      description:
          'Slewing to Alt ${altitude.toStringAsFixed(1)}, Az ${azimuth.toStringAsFixed(1)}',
      canCancel: true,
    );

    try {
      await _backend.mountSlewAltAz(deviceId, altitude, azimuth);
      mountNotifier.setParked(false);
    } finally {
      mountNotifier.setSlewing(false);
      operationsNotifier.completeOperation(
        OperationType.slewToTarget,
        operationId: operationId,
      );
    }
  }

  /// Send the mount home and watch until it is there.
  ///
  /// Homing never parks and never unparks: a parked mount is refused here
  /// rather than unparked behind the operator's back, and the parked flag is
  /// left alone afterward. Tracking is left as the driver leaves it.
  ///
  /// Completes only once [MountHomeWatcher] has seen the mount move and stop;
  /// a driver that accepts FindHome and does nothing is reported as a failure,
  /// not a home. Abort slew stops it (see [_abortMountSlew]).
  Future<MountHomeOutcome> _findMountHome() async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }

    final mountNotifier = _ref.read(mountStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);

    final before = await _backend.getMountStatus(deviceId);
    if (before.parked) {
      throw const MountHomeException(
        'The mount is parked. Unpark it before sending it home.',
      );
    }

    mountNotifier.setHoming(true);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.homeMount,
      description: 'Sending the mount to its home position',
      canCancel: true,
    );

    try {
      await _backend.mountFindHome(deviceId);
      final watcher = _ref.read(mountHomeWatcherFactoryProvider)(
        readStatus: () => _backend.getMountStatus(deviceId),
        // Abort slew clears the homing flag; that is the operator stopping it.
        isCancelled: () => !_ref.read(mountStateProvider).isHoming,
      );
      final MountHomeOutcome outcome;
      try {
        outcome = await watcher.watch(before);
      } on MountHomeException catch (e) {
        if (e.message == MountHomeWatcher.didNotMoveMessage) {
          // A driver that ignored Home may still start late; stop it so it
          // cannot move unwatched. Best effort: the report that it did not
          // move is the error the operator needs.
          try {
            await _backend.mountAbort(deviceId);
          } catch (abortError) {
            _safeLog(
              (l) => l.warning(
                'Mount $deviceId ignored Home; the follow-up abort also '
                'failed: $abortError',
                source: 'DeviceService',
              ),
              'mount-home-abort',
            );
          }
        }
        rethrow;
      }
      mountNotifier.setHomeUnconfirmed(outcome == MountHomeOutcome.unconfirmed);
      return outcome;
    } finally {
      mountNotifier.setHoming(false);
      operationsNotifier.completeOperation(
        OperationType.homeMount,
        operationId: operationId,
      );
    }
  }

  /// Store the mount's current position as its park position. Nothing moves
  /// and the parked flag is untouched; the native side refuses a driver that
  /// cannot set park and a mount that is slewing.
  Future<void> _setMountParkHere() async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No mount connected');
    }
    await _backend.mountSetPark(deviceId);
  }

  /// Pulse guide the mount in a given direction for a duration
  Future<void> _pulseGuidMount({
    required String direction,
    required int durationMs,
  }) async {
    final deviceId = await _getMountDeviceId();
    if (deviceId == null) {
      throw Exception('No mount connected');
    }

    await _backend.mountPulseGuide(
      deviceId: deviceId,
      direction: direction,
      durationMs: durationMs,
    );
  }
}

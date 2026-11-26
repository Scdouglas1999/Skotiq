part of 'demo_backend.dart';

/// The demo mount, focuser, filter wheel and rotator.
mixin _DemoMotionOps on _DemoRigCore {
  // ---------------------------------------------------------------------------
  // Mount.

  void _requireMount(String deviceId) {
    if (deviceId != DemoDeviceIds.mount) throw demoRigUnknownDevice(deviceId);
    if (!_mount.connected) throw demoRigNotConnected(deviceId);
  }

  void _requireUnparked() {
    if (_mount.parked) {
      throw const ValidationException(
        message: 'The demo mount is parked',
        userMessage: 'The mount is parked. Unpark it first.',
      );
    }
  }

  /// A move stops guiding first, as the host's guider rule does.
  GuiderForMove _guiderForMove() {
    if (!_guider.guiding) return GuiderForMove.idle;
    _stopGuiding(reason: 'mount_move');
    return GuiderForMove.stopped;
  }

  Future<GuiderForMove> mountSlewToCoordinates(
    String deviceId,
    double ra,
    double dec, {
    bool guiderSilentOk = false,
  }) async {
    _requireMount(deviceId);
    _requireUnparked();
    if (!ra.isFinite || ra < 0 || ra >= 24) {
      throw ValidationException.outOfRange('Right ascension', ra, 0, 24);
    }
    if (!dec.isFinite || dec < -90 || dec > 90) {
      throw ValidationException.outOfRange('Declination', dec, -90, 90);
    }
    final guider = _guiderForMove();
    _startSlew(_mount.slewTo(ra, dec), ra, dec);
    return guider;
  }

  void _startSlew(Duration duration, double ra, double dec) {
    _cancel(_slewTimer);
    _emitEquipment(
      bridge.EquipmentEvent.mountSlewStarted(
        deviceId: DemoDeviceIds.mount,
        ra: ra,
        dec: dec,
      ),
      deviceId: DemoDeviceIds.mount,
    );
    _slewTimer = _after(duration, () {
      _slewTimer = null;
      _emitEquipment(
        bridge.EquipmentEvent.mountSlewCompleted(
          deviceId: DemoDeviceIds.mount,
          ra: ra,
          dec: dec,
        ),
        deviceId: DemoDeviceIds.mount,
      );
    });
  }

  Future<GuiderForMove> mountSlewAltAz(
    String deviceId,
    double altitude,
    double azimuth, {
    bool guiderSilentOk = false,
  }) async {
    _requireMount(deviceId);
    _requireUnparked();
    if (!altitude.isFinite || altitude < 0 || altitude > 90) {
      throw ValidationException.outOfRange('Altitude', altitude, 0, 90);
    }
    if (!azimuth.isFinite || azimuth < 0 || azimuth >= 360) {
      throw ValidationException.outOfRange('Azimuth', azimuth, 0, 360);
    }
    final target = raDecOf(
      altitudeDeg: altitude,
      azimuthDeg: azimuth,
      latitudeDeg: _mount.latitudeDeg,
      lstHours: _mount.lstNow(),
    );
    final guider = _guiderForMove();
    _startSlew(
      _mount.slewTo(target.raHours, target.decDeg),
      target.raHours,
      target.decDeg,
    );
    return guider;
  }

  Future<void> mountSync(String deviceId, double ra, double dec) async {
    _requireMount(deviceId);
    _requireUnparked();
    if (!ra.isFinite || ra < 0 || ra >= 24) {
      throw ValidationException.outOfRange('Right ascension', ra, 0, 24);
    }
    if (!dec.isFinite || dec < -90 || dec > 90) {
      throw ValidationException.outOfRange('Declination', dec, -90, 90);
    }
    _mount.sync(ra, dec);
  }

  Future<GuiderForMove> mountPark(
    String deviceId, {
    bool forSafety = false,
  }) async {
    _requireMount(deviceId);
    final guider = _guiderForMove();
    if (_mount.parked && !_mount.slewing) return guider;
    _cancel(_slewTimer);
    _slewTimer = null;
    final duration = _mount.park();
    _emitEquipment(
      const bridge.EquipmentEvent.mountTrackingStopped(
        deviceId: DemoDeviceIds.mount,
      ),
      deviceId: DemoDeviceIds.mount,
    );
    _emitEquipment(
      const bridge.EquipmentEvent.mountParkStarted(
        deviceId: DemoDeviceIds.mount,
      ),
      deviceId: DemoDeviceIds.mount,
    );
    _slewTimer = _after(duration, () {
      _slewTimer = null;
      _mount.position();
      _emitEquipment(
        const bridge.EquipmentEvent.mountParkCompleted(
          deviceId: DemoDeviceIds.mount,
        ),
        deviceId: DemoDeviceIds.mount,
      );
    });
    return guider;
  }

  Future<void> mountUnpark(String deviceId) async {
    _requireMount(deviceId);
    if (_mount.slewing) {
      throw const ValidationException(
        message: 'The demo mount is still parking',
        userMessage: 'Wait for the mount to finish parking',
      );
    }
    if (!_mount.parked) return;
    _mount.unpark();
    _emitEquipment(
      const bridge.EquipmentEvent.mountUnparked(deviceId: DemoDeviceIds.mount),
      deviceId: DemoDeviceIds.mount,
    );
  }

  Future<GuiderForMove> mountFindHome(String deviceId) async {
    _requireMount(deviceId);
    _requireUnparked();
    final guider = _guiderForMove();
    _cancel(_slewTimer);
    final duration = _mount.home();
    final home = _mount.homePosition();
    _startSlew(duration, home.raHours, home.decDeg);
    return guider;
  }

  Future<void> mountSetTracking(String deviceId, bool enabled) async {
    _requireMount(deviceId);
    if (enabled) _requireUnparked();
    if (_mount.tracking == enabled) return;
    _mount.setTracking(enabled);
    _emitEquipment(
      enabled
          ? const bridge.EquipmentEvent.mountTrackingStarted(
              deviceId: DemoDeviceIds.mount,
            )
          : const bridge.EquipmentEvent.mountTrackingStopped(
              deviceId: DemoDeviceIds.mount,
            ),
      deviceId: DemoDeviceIds.mount,
    );
  }

  Future<void> mountSetTrackingRate(String deviceId, int rate) async {
    _requireMount(deviceId);
    if (rate < 0 || rate > 3) {
      throw ValidationException.outOfRange('Tracking rate', rate, 0, 3);
    }
    _mount.trackingRate = rate;
  }

  Future<void> mountPulseGuide({
    required String deviceId,
    required String direction,
    required int durationMs,
  }) async {
    _requireMount(deviceId);
    _requireUnparked();
    if (durationMs < 0 || durationMs > 10000) {
      throw ValidationException.outOfRange(
        'Pulse duration',
        durationMs,
        0,
        10000,
      );
    }
    _mount.pulse(direction, durationMs);
  }

  Future<void> mountMoveAxis(String deviceId, int axis, double rate) async {
    _requireMount(deviceId);
    if (rate != 0) _requireUnparked();
    if (axis != 0 && axis != 1) {
      throw ValidationException.outOfRange('Axis', axis, 0, 1);
    }
    if (!rate.isFinite || rate.abs() > 4) {
      throw ValidationException.outOfRange('Axis rate', rate, -4, 4);
    }
    _mount.moveAxis(axis, rate);
  }

  Future<void> mountAbort(String deviceId) async {
    _requireMount(deviceId);
    final wasSlewing = _mount.slewing;
    _cancel(_slewTimer);
    _slewTimer = null;
    _mount.abort();
    if (wasSlewing) {
      final p = _mount.position();
      _emitEquipment(
        bridge.EquipmentEvent.mountSlewCompleted(
          deviceId: DemoDeviceIds.mount,
          ra: p.raHours,
          dec: p.decDeg,
        ),
        deviceId: DemoDeviceIds.mount,
      );
    }
  }

  /// The demo mount has no site or clock of its own to read or set.
  Future<MountSiteCapabilities> mountSiteCapabilities(String deviceId) async {
    _requireMount(deviceId);
    return const MountSiteCapabilities(
      canReadSite: false,
      canWriteSite: false,
      canReadTime: false,
      canWriteTime: false,
    );
  }

  Future<MountStatus> getMountStatus(String deviceId) async {
    if (deviceId != DemoDeviceIds.mount) throw demoRigUnknownDevice(deviceId);
    return _mount.status();
  }

  Future<MountCapabilities?> getMountCapabilities(String deviceId) async {
    if (deviceId != DemoDeviceIds.mount || !_mount.connected) return null;
    return MountCapabilities(
      canSlew: true,
      canSlewAsync: true,
      canSync: true,
      canPark: true,
      canUnpark: true,
      canPulseGuide: true,
      canGetSideOfPier: true,
      canSetTracking: true,
      canSetTrackingRate: true,
      supportedTrackingRates: const [
        TrackingRate.sidereal,
        TrackingRate.lunar,
        TrackingRate.solar,
        TrackingRate.king,
      ],
      isEquatorial: true,
      supportsAltAz: true,
      canFindHome: true,
      tracking: _mount.tracking,
      trackingRate: TrackingRate.values[_mount.trackingRate.clamp(0, 3)],
      canAbortSlew: true,
      maxSlewRate: 8,
      canMoveAxis: true,
      minPulseGuideMs: 0,
      maxPulseGuideMs: 10000,
    );
  }

  // ---------------------------------------------------------------------------
  // Focuser.

  void _requireFocuser(String deviceId) {
    if (deviceId != DemoDeviceIds.focuser) throw demoRigUnknownDevice(deviceId);
    if (!_focuser.connected) throw demoRigNotConnected(deviceId);
  }

  Future<void> focuserMoveTo(String deviceId, int position) async {
    _requireFocuser(deviceId);
    if (position < 0 || position > DemoFocuser.maxPosition) {
      throw ValidationException.outOfRange(
        'Focuser position',
        position,
        0,
        DemoFocuser.maxPosition,
      );
    }
    _startFocuserMove(position);
  }

  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    _requireFocuser(deviceId);
    final target = _focuser.positionAt(_clock()) + delta;
    if (target < 0 || target > DemoFocuser.maxPosition) {
      throw ValidationException.outOfRange(
        'Focuser position',
        target,
        0,
        DemoFocuser.maxPosition,
      );
    }
    _startFocuserMove(target);
  }

  void _startFocuserMove(int target) {
    _cancel(_focuserTimer);
    final duration = _focuser.moveTo(target, _clock());
    _emitEquipment(
      bridge.EquipmentEvent.focuserMoveStarted(
        deviceId: DemoDeviceIds.focuser,
        targetPosition: target,
      ),
      deviceId: DemoDeviceIds.focuser,
    );
    _focuserTimer = _after(duration, () {
      _focuserTimer = null;
      _emitEquipment(
        bridge.EquipmentEvent.focuserMoveCompleted(
          deviceId: DemoDeviceIds.focuser,
          position: _focuser.positionAt(_clock()),
        ),
        deviceId: DemoDeviceIds.focuser,
      );
    });
  }

  Future<void> focuserHalt(String deviceId) async {
    _requireFocuser(deviceId);
    final t = _clock();
    final wasMoving = _focuser.movingAt(t);
    _cancel(_focuserTimer);
    _focuserTimer = null;
    _focuser.halt(t);
    if (wasMoving) {
      _emitEquipment(
        bridge.EquipmentEvent.focuserMoveCompleted(
          deviceId: DemoDeviceIds.focuser,
          position: _focuser.positionAt(t),
        ),
        deviceId: DemoDeviceIds.focuser,
      );
    }
  }

  /// No autofocus runs on the demo rig, so there is nothing to cancel.
  Future<void> autofocusCancel() async {}

  Future<FocuserStatus> getFocuserStatus(String deviceId) async {
    if (deviceId != DemoDeviceIds.focuser) throw demoRigUnknownDevice(deviceId);
    return _focuser.statusAt(_clock());
  }

  Future<FocuserCapabilities?> getFocuserCapabilities(String deviceId) async {
    if (deviceId != DemoDeviceIds.focuser || !_focuser.connected) return null;
    return _focuser.capabilitiesAt(_clock());
  }

  // ---------------------------------------------------------------------------
  // Filter wheel.

  void _requireFilterWheel(String deviceId) {
    if (deviceId != DemoDeviceIds.filterWheel) {
      throw demoRigUnknownDevice(deviceId);
    }
    if (!_filterWheel.connected) throw demoRigNotConnected(deviceId);
  }

  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    _requireFilterWheel(deviceId);
    if (position < 0 || position >= _filterWheel.slotCount) {
      throw ValidationException.outOfRange(
        'Filter slot',
        position,
        0,
        _filterWheel.slotCount - 1,
      );
    }
    final t = _clock();
    final from = _filterWheel.positionAt(t);
    if (from == position && !_filterWheel.movingAt(t)) return;
    _cancel(_filterTimer);
    final duration = _filterWheel.moveTo(position, t);
    _emitEquipment(
      bridge.EquipmentEvent.filterChanging(
        deviceId: deviceId,
        fromPosition: from,
        toPosition: position,
        filterName: _filterWheel.nameOf(position),
        fromFilterName: _filterWheel.nameOf(from),
      ),
      deviceId: deviceId,
    );
    _filterTimer = _after(duration, () {
      _filterTimer = null;
      _emitEquipment(
        bridge.EquipmentEvent.filterChanged(
          deviceId: deviceId,
          position: _filterWheel.positionAt(_clock()),
          filterName: _filterWheel.nameOf(position),
        ),
        deviceId: deviceId,
      );
    });
    // A filter change completes before the caller moves on, as a driver's
    // blocking move does.
    await Future<void>.delayed(duration);
  }

  Future<List<String>> filterWheelGetNames(String deviceId) async {
    _requireFilterWheel(deviceId);
    return List.unmodifiable(_filterWheel.names);
  }

  Future<void> filterWheelSetNames(String deviceId, List<String> names) async {
    _requireFilterWheel(deviceId);
    if (names.length != _filterWheel.slotCount) {
      throw ValidationException(
        message:
            'The demo filter wheel has ${_filterWheel.slotCount} slots, '
            'got ${names.length} names',
        userMessage:
            'Give a name for each of the ${_filterWheel.slotCount} slots',
      );
    }
    _filterWheel.names = List.of(names);
  }

  Future<void> filterWheelSetByName(String deviceId, String name) async {
    _requireFilterWheel(deviceId);
    final slot = _filterWheel.names.indexWhere(
      (n) => n.toLowerCase() == name.toLowerCase(),
    );
    if (slot < 0) {
      throw ValidationException(
        message: 'The demo filter wheel has no filter "$name"',
        userMessage: 'The filter wheel has no filter named $name',
      );
    }
    await filterWheelSetPosition(deviceId, slot);
  }

  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    if (deviceId != DemoDeviceIds.filterWheel) {
      throw demoRigUnknownDevice(deviceId);
    }
    return _filterWheel.statusAt(_clock());
  }

  Future<FilterWheelCapabilities?> getFilterWheelCapabilities(
    String deviceId,
  ) async {
    if (deviceId != DemoDeviceIds.filterWheel || !_filterWheel.connected) {
      return null;
    }
    return _filterWheel.capabilitiesAt(_clock());
  }

  // ---------------------------------------------------------------------------
  // Rotator.

  void _requireRotator(String deviceId) {
    if (deviceId != DemoDeviceIds.rotator) throw demoRigUnknownDevice(deviceId);
    if (!_rotator.connected) throw demoRigNotConnected(deviceId);
  }

  Future<void> rotatorMoveTo(String deviceId, double angle) async {
    _requireRotator(deviceId);
    if (!angle.isFinite) {
      throw ValidationException.outOfRange('Rotator angle', angle, 0, 360);
    }
    _cancel(_rotatorTimer);
    final duration = _rotator.moveTo(angle, _clock());
    _emitEquipment(
      bridge.EquipmentEvent.rotatorMoveStarted(
        deviceId: deviceId,
        targetAngle: angle % 360,
      ),
      deviceId: deviceId,
    );
    _rotatorTimer = _after(duration, () {
      _rotatorTimer = null;
      _emitEquipment(
        bridge.EquipmentEvent.rotatorMoveCompleted(
          deviceId: deviceId,
          angle: _rotator.positionAt(_clock()),
        ),
        deviceId: deviceId,
      );
    });
  }

  Future<void> rotatorMoveRelative(String deviceId, double delta) async {
    _requireRotator(deviceId);
    await rotatorMoveTo(deviceId, _rotator.positionAt(_clock()) + delta);
  }

  Future<double> rotatorGetAngle(String deviceId) async {
    _requireRotator(deviceId);
    return _rotator.positionAt(_clock());
  }

  Future<void> rotatorHalt(String deviceId) async {
    _requireRotator(deviceId);
    final t = _clock();
    final wasMoving = _rotator.movingAt(t);
    _cancel(_rotatorTimer);
    _rotatorTimer = null;
    _rotator.halt(t);
    if (wasMoving) {
      _emitEquipment(
        bridge.EquipmentEvent.rotatorMoveCompleted(
          deviceId: deviceId,
          angle: _rotator.positionAt(t),
        ),
        deviceId: deviceId,
      );
    }
  }

  Future<void> rotatorSetReverse(String deviceId, bool reverse) async {
    _requireRotator(deviceId);
    _rotator.reverse = reverse;
  }

  Future<void> rotatorSyncToPa(String deviceId, double pa) async {
    _requireRotator(deviceId);
    if (!pa.isFinite) {
      throw ValidationException.outOfRange('Position angle', pa, 0, 360);
    }
    _rotator.syncTo(pa, _clock());
  }

  Future<RotatorStatus> getRotatorStatus(String deviceId) async {
    if (deviceId != DemoDeviceIds.rotator) throw demoRigUnknownDevice(deviceId);
    return _rotator.statusAt(_clock());
  }

  Future<RotatorCapabilities?> getRotatorCapabilities(String deviceId) async {
    if (deviceId != DemoDeviceIds.rotator || !_rotator.connected) return null;
    return _rotator.capabilitiesAt(_clock());
  }
}

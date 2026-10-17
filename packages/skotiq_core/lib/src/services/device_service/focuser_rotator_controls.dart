part of '../device_service.dart';

extension _DeviceServiceFocuserRotatorControls on DeviceService {
  // Device ID Helpers

  /// Get the connected camera device ID.
  ///
  /// An equipment profile is connection intent, not live command authority.
  /// Falling back to it while disconnected can send an autofocus command to a
  /// stale device on the current backend.
  Future<String?> _getCameraDeviceId() async =>
      _connectedDeviceIdFor(DeviceType.camera);

  // Focuser control

  /// Get the connected focuser device ID. Active-profile IDs are deliberately
  /// not used here; only the connected state has authority to move hardware.
  Future<String?> _getFocuserDeviceId() async =>
      _connectedDeviceIdFor(DeviceType.focuser);

  bool _isStillConnectedToFocuser(String deviceId) =>
      _isStillConnectedTo(DeviceType.focuser, deviceId);

  void _validateFocuserMoveAdmission({bool requireAbsolute = false}) {
    final state = _ref.read(focuserStateProvider);
    if (state.connectionState != DeviceConnectionState.connected ||
        state.deviceId == null ||
        state.deviceId!.isEmpty) {
      throw Exception('No focuser connected');
    }
    if (_isAutofocusRunning) {
      throw StateError(
        'Cannot move the focuser manually while autofocus is running.',
      );
    }
    if (_isFocuserMoveRunning || state.isMoving) {
      throw StateError('Another focuser move is already in progress.');
    }
    if (requireAbsolute && !state.isAbsolute) {
      throw UnsupportedError(
        'This focuser does not support absolute positioning.',
      );
    }
  }

  Future<bool> _recoverFocuserMovingState(String deviceId) async {
    if (!_isStillConnectedToFocuser(deviceId)) return false;
    final notifier = _ref.read(focuserStateProvider.notifier);
    try {
      final status = await _backend.getFocuserStatus(deviceId);
      if (!_isStillConnectedToFocuser(deviceId)) return false;
      notifier.updatePosition(status.position);
      notifier.setMoving(status.moving);
      if (status.temperature != null) {
        notifier.updateTemperature(status.temperature!);
      }
      return status.moving;
    } catch (e) {
      // The focuser move already failed; this is the follow-up status read that
      // decides whether the hardware is still travelling. If that read also
      // fails we cannot know, so we report "not moving" and clear the spinner —
      // but the operator must see that the state is assumed, not measured.
      _safeLog(
        (l) => l.warning(
          'Could not read focuser $deviceId status after a failed move; '
          'assuming it is stopped (moving state may be stale): $e',
          source: 'DeviceService',
        ),
        'focuser-recover-moving-state',
      );
      return false;
    }
  }

  /// Move focuser to absolute position
  Future<void> _moveFocuserTo(int position) async {
    if (position < 0) {
      throw ArgumentError.value(position, 'position', 'Must be non-negative');
    }
    _validateFocuserMoveAdmission(requireAbsolute: true);
    final initialState = _ref.read(focuserStateProvider);
    final maxPosition = initialState.maxPosition;
    if (maxPosition != null && maxPosition > 0 && position > maxPosition) {
      throw RangeError.range(position, 0, maxPosition, 'position');
    }

    _isFocuserMoveRunning = true;
    final deviceId = await _getFocuserDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      _isFocuserMoveRunning = false;
      throw Exception('No focuser connected');
    }

    final focuserNotifier = _ref.read(focuserStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);

    focuserNotifier.setMoving(true);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.focuserMove,
      description: 'Moving focuser to $position',
    );

    var commandWasSent = false;
    var hardwareStillMoving = false;
    try {
      if (!_isStillConnectedToFocuser(deviceId)) {
        throw StateError('Focuser connection changed; move was not sent.');
      }
      final verifyGeneration = ++_focuserVerifyGeneration;
      await _backend.focuserMoveTo(deviceId, position);
      commandWasSent = true;
      await _verifyFocuserPosition(
        deviceId: deviceId,
        targetPosition: position,
        generation: verifyGeneration,
      );
    } catch (e) {
      _safeLog(
        (l) => l.error(
          'Focuser $deviceId absolute move to $position failed '
          '(command sent: $commandWasSent): $e',
          source: 'DeviceService',
        ),
        'focuser-move-to',
      );
      if (commandWasSent) {
        hardwareStillMoving = await _recoverFocuserMovingState(deviceId);
      }
      rethrow;
    } finally {
      _isFocuserMoveRunning = false;
      if (!hardwareStillMoving) {
        focuserNotifier.setMoving(false);
      }
      operationsNotifier.completeOperation(
        OperationType.focuserMove,
        operationId: operationId,
      );
    }
  }

  /// Move focuser by relative amount
  /// Uses the backend's native relative move which queries actual device position
  Future<void> _moveFocuserRelative(int delta) async {
    if (delta == 0) {
      throw ArgumentError.value(delta, 'delta', 'Must not be zero');
    }
    _validateFocuserMoveAdmission();
    _isFocuserMoveRunning = true;
    final deviceId = await _getFocuserDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      _isFocuserMoveRunning = false;
      throw Exception('No focuser connected');
    }

    final focuserNotifier = _ref.read(focuserStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);

    focuserNotifier.setMoving(true);
    final direction = delta > 0 ? 'out' : 'in';
    final operationId = operationsNotifier.startOperation(
      type: OperationType.focuserMove,
      description: 'Moving focuser ${delta.abs()} steps $direction',
    );

    var commandWasSent = false;
    var hardwareStillMoving = false;
    try {
      // Get current position to compute target
      final currentStatus = await _backend.getFocuserStatus(deviceId);
      if (!_isStillConnectedToFocuser(deviceId)) {
        throw StateError('Focuser connection changed; move was not sent.');
      }
      if (!currentStatus.connected) {
        throw StateError('Focuser disconnected before the move was sent.');
      }
      if (currentStatus.moving) {
        throw StateError('The focuser is already moving.');
      }
      final targetPosition = currentStatus.position + delta;
      if (targetPosition < 0) {
        throw RangeError.value(
          targetPosition,
          'targetPosition',
          'Relative move would pass position 0',
        );
      }
      if (currentStatus.maxPosition > 0 &&
          targetPosition > currentStatus.maxPosition) {
        throw RangeError.range(
          targetPosition,
          0,
          currentStatus.maxPosition,
          'targetPosition',
        );
      }

      FocuserCapabilities? capabilities;
      try {
        capabilities = await _backend.getFocuserCapabilities(deviceId);
      } catch (e) {
        // Capability lookup is advisory. The status and command endpoints
        // remain authoritative for drivers that do not expose capabilities.
        // Logged because losing it also loses the maxIncrement clamp below.
        _safeLog(
          (l) => l.info(
            'Focuser $deviceId capability lookup failed; proceeding without '
            'the driver maxIncrement clamp: $e',
            source: 'DeviceService',
          ),
          'focuser-capabilities',
        );
      }
      if (!_isStillConnectedToFocuser(deviceId)) {
        throw StateError('Focuser connection changed; move was not sent.');
      }
      final maxIncrement = capabilities?.maxIncrement ?? 0;
      if (maxIncrement > 0 && delta.abs() > maxIncrement) {
        throw RangeError.range(
          delta.abs(),
          1,
          maxIncrement,
          'delta',
          'Relative move exceeds the driver maximum increment',
        );
      }

      // Use backend's native relative move which queries actual device position
      final verifyGeneration = ++_focuserVerifyGeneration;
      await _backend.focuserMoveRelative(deviceId, delta);
      commandWasSent = true;
      await _verifyFocuserPosition(
        deviceId: deviceId,
        targetPosition: targetPosition,
        generation: verifyGeneration,
      );
    } catch (e) {
      _safeLog(
        (l) => l.error(
          'Focuser $deviceId relative move of $delta steps failed '
          '(command sent: $commandWasSent): $e',
          source: 'DeviceService',
        ),
        'focuser-move-relative',
      );
      if (commandWasSent) {
        hardwareStillMoving = await _recoverFocuserMovingState(deviceId);
      }
      rethrow;
    } finally {
      _isFocuserMoveRunning = false;
      if (!hardwareStillMoving) {
        focuserNotifier.setMoving(false);
      }
      operationsNotifier.completeOperation(
        OperationType.focuserMove,
        operationId: operationId,
      );
    }
  }

  /// Halt focuser movement
  Future<void> _haltFocuser() async {
    final deviceId = await _getFocuserDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No focuser connected');
    }

    final focuserNotifier = _ref.read(focuserStateProvider.notifier);
    _focuserVerifyGeneration++;

    try {
      if (!_isStillConnectedToFocuser(deviceId)) {
        throw StateError('Focuser connection changed; halt was not sent.');
      }
      await _backend.focuserHalt(deviceId);
      // Query actual position from device after halt
      final status = await _backend.getFocuserStatus(deviceId);
      focuserNotifier.updatePosition(status.position);
    } finally {
      focuserNotifier.setMoving(false);
    }
  }

  // Rotator control

  /// Get the connected rotator device ID. Active-profile IDs are deliberately
  /// excluded because they describe intended equipment, not a live connection.
  Future<String?> _getRotatorDeviceId() async =>
      _connectedDeviceIdFor(DeviceType.rotator);

  bool _isStillConnectedToRotator(String deviceId) =>
      _isStillConnectedTo(DeviceType.rotator, deviceId);

  Future<RotatorCapabilities?> _getRotatorCapabilities(String deviceId) async {
    try {
      return await _backend.getRotatorCapabilities(deviceId);
    } catch (e) {
      // Null means "capabilities unknown"; every caller then skips its
      // canReverse/canMoveAbsolute/canSync guard and lets the driver reject
      // the command instead. Log it so an unexpected permissive path is
      // traceable rather than looking like the driver advertised support.
      _safeLog(
        (l) => l.info(
          'Rotator $deviceId capability lookup failed; capability guards will '
          'be skipped and the driver becomes the authority: $e',
          source: 'DeviceService',
        ),
        'rotator-capabilities',
      );
      return null;
    }
  }

  void _validateRotatorCommandAdmission() {
    final state = _ref.read(rotatorStateProvider);
    if (state.connectionState != DeviceConnectionState.connected ||
        state.deviceId == null ||
        state.deviceId!.isEmpty) {
      throw Exception('No rotator connected');
    }
    if (_isRotatorCommandRunning || state.isMoving) {
      throw StateError('Another rotator command is already in progress.');
    }
  }

  Future<bool> _recoverRotatorMovingState(String deviceId) async {
    if (!_isStillConnectedToRotator(deviceId)) return false;
    final notifier = _ref.read(rotatorStateProvider.notifier);
    try {
      final status = await _backend.getRotatorStatus(deviceId);
      if (!_isStillConnectedToRotator(deviceId)) return false;
      notifier.updatePosition(
        status.position,
        mechanicalPosition: status.mechanicalPosition,
      );
      final moving = status.moving || status.isMoving;
      notifier.setMoving(moving);
      return moving;
    } catch (e) {
      // Same shape as the focuser recovery read: the move already failed and
      // this status read is what decides whether the rotator is still turning.
      // Failing it means we clear the spinner on an assumption, not a reading.
      _safeLog(
        (l) => l.warning(
          'Could not read rotator $deviceId status after a failed move; '
          'assuming it is stopped (moving state may be stale): $e',
          source: 'DeviceService',
        ),
        'rotator-recover-moving-state',
      );
      return false;
    }
  }

  /// Write the rotator's reverse-direction flag to the driver, then mirror
  /// it into local state so the equipment card reflects the new setting.
  Future<void> _setRotatorReversed(bool reversed) async {
    _validateRotatorCommandAdmission();
    _isRotatorCommandRunning = true;
    final deviceId = await _getRotatorDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      _isRotatorCommandRunning = false;
      throw Exception('No rotator connected');
    }
    try {
      final capabilities = await _getRotatorCapabilities(deviceId);
      if (!_isStillConnectedToRotator(deviceId)) {
        throw StateError(
          'Rotator connection changed; reverse was not written.',
        );
      }
      if (capabilities != null && !capabilities.canReverse) {
        throw UnsupportedError(
          'This rotator does not support reversing direction.',
        );
      }
      await _backend.rotatorSetReverse(deviceId, reversed);
      if (!_isStillConnectedToRotator(deviceId)) {
        throw StateError('Rotator connection changed after reverse was set.');
      }
      _ref.read(rotatorStateProvider.notifier).setReversed(reversed);
    } finally {
      _isRotatorCommandRunning = false;
    }
  }

  /// Move rotator to an absolute angle (0-360 degrees).
  Future<void> _moveRotatorTo(double angle) async {
    if (!angle.isFinite) {
      throw ArgumentError.value(angle, 'angle', 'Must be finite');
    }
    _validateRotatorCommandAdmission();
    _isRotatorCommandRunning = true;
    final deviceId = await _getRotatorDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      _isRotatorCommandRunning = false;
      throw Exception('No rotator connected');
    }

    final rotatorNotifier = _ref.read(rotatorStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);

    rotatorNotifier.setMoving(true);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.rotatorMove,
      description: 'Moving rotator to ${angle.toStringAsFixed(1)}°',
    );

    var commandWasSent = false;
    var hardwareStillMoving = false;
    try {
      final capabilities = await _getRotatorCapabilities(deviceId);
      if (!_isStillConnectedToRotator(deviceId)) {
        throw StateError('Rotator connection changed; move was not sent.');
      }
      if (capabilities != null && !capabilities.canMoveAbsolute) {
        throw UnsupportedError(
          'This rotator does not support absolute positioning.',
        );
      }
      final min = capabilities?.minAngleDeg;
      final max = capabilities?.maxAngleDeg;
      final hasDriverRange =
          min != null &&
          max != null &&
          min.isFinite &&
          max.isFinite &&
          min < max;
      final lower = hasDriverRange ? min : 0.0;
      final upper = hasDriverRange ? max : 360.0;
      if (angle < lower || angle > upper) {
        throw RangeError.value(
          angle,
          'angle',
          'Must be between $lower and $upper degrees',
        );
      }

      final verifyGeneration = ++_rotatorVerifyGeneration;
      await _backend.rotatorMoveTo(deviceId, angle);
      commandWasSent = true;
      // Poll until movement completes
      await _verifyRotatorPosition(
        deviceId: deviceId,
        targetAngle: angle,
        generation: verifyGeneration,
      );
    } catch (e) {
      _safeLog(
        (l) => l.error(
          'Rotator $deviceId absolute move to ${angle.toStringAsFixed(1)}° '
          'failed (command sent: $commandWasSent): $e',
          source: 'DeviceService',
        ),
        'rotator-move-to',
      );
      if (commandWasSent) {
        hardwareStillMoving = await _recoverRotatorMovingState(deviceId);
      }
      rethrow;
    } finally {
      _isRotatorCommandRunning = false;
      if (!hardwareStillMoving) {
        rotatorNotifier.setMoving(false);
      }
      operationsNotifier.completeOperation(
        OperationType.rotatorMove,
        operationId: operationId,
      );
    }
  }

  /// Move rotator by a relative angle (degrees).
  Future<void> _moveRotatorRelative(double delta) async {
    if (!delta.isFinite || delta == 0) {
      throw ArgumentError.value(delta, 'delta', 'Must be finite and non-zero');
    }
    _validateRotatorCommandAdmission();
    _isRotatorCommandRunning = true;
    final deviceId = await _getRotatorDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      _isRotatorCommandRunning = false;
      throw Exception('No rotator connected');
    }

    final rotatorNotifier = _ref.read(rotatorStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);

    final direction = delta > 0 ? 'CW' : 'CCW';
    rotatorNotifier.setMoving(true);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.rotatorMove,
      description: 'Rotating ${delta.abs().toStringAsFixed(1)}° $direction',
    );

    var commandWasSent = false;
    var hardwareStillMoving = false;
    try {
      // Get current angle to compute target for verification
      final currentStatus = await _backend.getRotatorStatus(deviceId);
      if (!_isStillConnectedToRotator(deviceId)) {
        throw StateError('Rotator connection changed; move was not sent.');
      }
      if (!currentStatus.connected) {
        throw StateError('Rotator disconnected before the move was sent.');
      }
      if (currentStatus.moving || currentStatus.isMoving) {
        throw StateError('The rotator is already moving.');
      }
      final currentAngle = currentStatus.position;
      final targetAngle = (currentAngle + delta) % 360.0;

      final verifyGeneration = ++_rotatorVerifyGeneration;
      await _backend.rotatorMoveRelative(deviceId, delta);
      commandWasSent = true;
      await _verifyRotatorPosition(
        deviceId: deviceId,
        targetAngle: targetAngle,
        generation: verifyGeneration,
      );
    } catch (e) {
      _safeLog(
        (l) => l.error(
          'Rotator $deviceId relative move of ${delta.toStringAsFixed(1)}° '
          'failed (command sent: $commandWasSent): $e',
          source: 'DeviceService',
        ),
        'rotator-move-relative',
      );
      if (commandWasSent) {
        hardwareStillMoving = await _recoverRotatorMovingState(deviceId);
      }
      rethrow;
    } finally {
      _isRotatorCommandRunning = false;
      if (!hardwareStillMoving) {
        rotatorNotifier.setMoving(false);
      }
      operationsNotifier.completeOperation(
        OperationType.rotatorMove,
        operationId: operationId,
      );
    }
  }

  /// Halt rotator movement.
  Future<void> _haltRotator() async {
    final deviceId = await _getRotatorDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No rotator connected');
    }

    final rotatorNotifier = _ref.read(rotatorStateProvider.notifier);
    _rotatorVerifyGeneration++;

    try {
      if (!_isStillConnectedToRotator(deviceId)) {
        throw StateError('Rotator connection changed; halt was not sent.');
      }
      await _backend.rotatorHalt(deviceId);
      // Query actual angle from device after halt
      final angle = await _backend.rotatorGetAngle(deviceId);
      rotatorNotifier.updatePosition(angle);
    } finally {
      rotatorNotifier.setMoving(false);
    }
  }

  Future<void> _syncRotatorToPa(double positionAngle) async {
    if (!positionAngle.isFinite || positionAngle < 0 || positionAngle > 360) {
      throw RangeError.range(positionAngle, 0, 360, 'positionAngle');
    }
    _validateRotatorCommandAdmission();
    _isRotatorCommandRunning = true;
    final deviceId = await _getRotatorDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      _isRotatorCommandRunning = false;
      throw Exception('No rotator connected');
    }

    try {
      final capabilities = await _getRotatorCapabilities(deviceId);
      if (!_isStillConnectedToRotator(deviceId)) {
        throw StateError('Rotator connection changed; sync was not sent.');
      }
      if (capabilities != null && !capabilities.canSync) {
        throw UnsupportedError('This rotator does not support sky-PA sync.');
      }
      await _backend.rotatorSyncToPa(deviceId, positionAngle);
      final status = await _backend.getRotatorStatus(deviceId);
      if (!_isStillConnectedToRotator(deviceId)) {
        throw StateError('Rotator connection changed after sync.');
      }
      _ref
          .read(rotatorStateProvider.notifier)
          .updatePosition(
            status.position,
            mechanicalPosition: status.mechanicalPosition,
          );
    } finally {
      _isRotatorCommandRunning = false;
    }
  }

  /// Verify rotator reached target angle with polling and timeout.
  ///
  /// Polls the rotator angle every 500ms until it reaches the target
  /// (within 0.5 degree tolerance). Times out after 120 seconds.
  static const Duration _rotatorMoveTimeout = Duration(seconds: 120);
  static const Duration _rotatorMovePollInterval = Duration(milliseconds: 500);

  Future<void> _verifyRotatorPosition({
    required String deviceId,
    required double targetAngle,
    required int generation,
  }) async {
    final deadline = DateTime.now().add(_rotatorMoveTimeout);
    final rotatorNotifier = _ref.read(rotatorStateProvider.notifier);

    while (true) {
      if (_disposed || generation != _rotatorVerifyGeneration) {
        throw StateError('Rotator verification was cancelled.');
      }

      final status = await _backend.getRotatorStatus(deviceId);
      if (_disposed || generation != _rotatorVerifyGeneration) {
        throw StateError('Rotator verification was cancelled.');
      }
      rotatorNotifier.updatePosition(
        status.position,
        mechanicalPosition: status.mechanicalPosition,
      );
      rotatorNotifier.setMoving(status.moving);

      // Check if we're within tolerance (handle wraparound at 0/360)
      final diff = (status.position - targetAngle).abs();
      final wrappedDiff = (360.0 - diff).abs();
      final effectiveDiff = diff < wrappedDiff ? diff : wrappedDiff;

      if (effectiveDiff < 0.5) {
        rotatorNotifier.setMoving(false);
        return;
      }

      // Check if rotator stopped moving but hasn't reached target (stall)
      if (!status.moving && effectiveDiff >= 0.5) {
        throw Exception(
          'Rotator stalled at ${status.position.toStringAsFixed(1)}°, '
          'target was ${targetAngle.toStringAsFixed(1)}° '
          '(diff: ${effectiveDiff.toStringAsFixed(1)}°).',
        );
      }

      if (DateTime.now().isAfter(deadline)) {
        throw Exception(
          'Rotator did not reach ${targetAngle.toStringAsFixed(1)}° within '
          '${_rotatorMoveTimeout.inSeconds}s '
          '(last reported angle: ${status.position.toStringAsFixed(1)}°).',
        );
      }

      await Future.delayed(_rotatorMovePollInterval);
    }
  }
}

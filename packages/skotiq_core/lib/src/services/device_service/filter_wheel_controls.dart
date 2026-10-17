part of '../device_service.dart';

extension _DeviceServiceFilterWheelControls on DeviceService {
  // Filter wheel control

  /// Get the connected filter wheel device ID. An active profile is connection
  /// intent, not permission to command disconnected hardware.
  Future<String?> _getFilterWheelDeviceId() async =>
      _connectedDeviceIdFor(DeviceType.filterWheel);

  bool _isStillConnectedToFilterWheel(String deviceId) =>
      _isStillConnectedTo(DeviceType.filterWheel, deviceId);

  /// Set filter wheel position
  ///
  /// Changes the filter wheel to the specified position and automatically
  /// applies focus offset if configured for the selected filter.
  Future<void> _setFilterWheelPosition(
    int position, {
    bool requireFocusOffset = false,
    bool allowDuringAutofocus = false,
  }) async {
    if (position < 0) {
      throw ArgumentError.value(position, 'position', 'Must be non-negative');
    }
    final initialState = _ref.read(filterWheelStateProvider);
    if (initialState.connectionState != DeviceConnectionState.connected ||
        initialState.deviceId == null ||
        initialState.deviceId!.isEmpty) {
      throw Exception('No filter wheel connected');
    }
    if (_isAutofocusRunning && !allowDuringAutofocus) {
      throw StateError(
        'Cannot change filters manually while autofocus is running.',
      );
    }
    if (_isFilterWheelCommandRunning || initialState.isMoving) {
      throw StateError('Another filter wheel command is already in progress.');
    }
    if (initialState.filterNames.isNotEmpty &&
        position >= initialState.filterNames.length) {
      throw RangeError.range(
        position,
        0,
        initialState.filterNames.length - 1,
        'position',
      );
    }

    _isFilterWheelCommandRunning = true;
    final deviceId = await _getFilterWheelDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      _isFilterWheelCommandRunning = false;
      throw Exception('No filter wheel connected');
    }

    final filterWheelNotifier = _ref.read(filterWheelStateProvider.notifier);
    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);

    // Get filter name for display
    final filterWheelState = _ref.read(filterWheelStateProvider);
    final filterNames = filterWheelState.filterNames;
    final filterName = position >= 0 && position < filterNames.length
        ? filterNames[position]
        : 'Position $position';

    filterWheelNotifier.setMoving(true);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.filterChange,
      description: 'Changing filter to $filterName',
    );

    var commandWasSent = false;
    var hardwareStillMoving = false;
    try {
      FilterWheelCapabilities? capabilities;
      try {
        capabilities = await _backend.getFilterWheelCapabilities(deviceId);
      } catch (e) {
        // Older drivers may not expose capabilities; the status/command path
        // remains authoritative in that case. Logged because losing it also
        // loses the positionCount range check below, so an out-of-range slot
        // would reach the driver instead of being rejected here.
        _safeLog(
          (l) => l.info(
            'Filter wheel $deviceId capability lookup failed; the slot-count '
            'range check will be skipped for this move: $e',
            source: 'DeviceService',
          ),
          'filter-wheel-capabilities',
        );
      }
      if (!_isStillConnectedToFilterWheel(deviceId)) {
        throw StateError(
          'Filter wheel connection changed; command was not sent.',
        );
      }
      final positionCount = capabilities?.positionCount ?? 0;
      if (positionCount > 0 && position >= positionCount) {
        throw RangeError.range(position, 0, positionCount - 1, 'position');
      }

      // Move the filter wheel
      _ref
          .read(loggingServiceProvider)
          .debug(
            'Changing filter wheel $deviceId to $filterName '
            '(position $position)',
            source: 'DeviceService',
          );
      final verifyGeneration = ++_filterWheelVerifyGeneration;
      await _backend.filterWheelSetPosition(deviceId, position);
      commandWasSent = true;

      await _verifyFilterWheelPosition(
        deviceId: deviceId,
        expectedPosition: position,
        filterNames: filterNames,
        generation: verifyGeneration,
      );

      // Apply focus offset only after position is verified.
      if (position >= 0 && position < filterNames.length) {
        await _applyFilterFocusOffset(
          filterNames[position],
          rethrowOnFailure: requireFocusOffset,
        );
      }
    } catch (e) {
      if (commandWasSent) {
        hardwareStillMoving = await _recoverFilterWheelMovingState(
          deviceId,
          filterWheelNotifier,
        );
      }
      rethrow;
    } finally {
      _isFilterWheelCommandRunning = false;
      if (!hardwareStillMoving) {
        filterWheelNotifier.setMoving(false);
      }
      operationsNotifier.completeOperation(
        OperationType.filterChange,
        operationId: operationId,
      );
    }
  }

  Future<void> _setFilterWheelNames(List<String> names) async {
    final state = _ref.read(filterWheelStateProvider);
    final deviceId = state.connectionState == DeviceConnectionState.connected
        ? state.deviceId
        : null;
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No filter wheel connected');
    }
    if (_isAutofocusRunning) {
      throw StateError(
        'Cannot rename filter slots while autofocus is running.',
      );
    }
    if (_isFilterWheelCommandRunning || state.isMoving) {
      throw StateError('Another filter wheel command is already in progress.');
    }

    final normalized = names.map((name) => name.trim()).toList(growable: false);
    if (normalized.isEmpty || normalized.any((name) => name.isEmpty)) {
      throw ArgumentError('Every filter wheel slot must have a name.');
    }

    _isFilterWheelCommandRunning = true;
    try {
      FilterWheelCapabilities? capabilities;
      try {
        capabilities = await _backend.getFilterWheelCapabilities(deviceId);
      } catch (e) {
        // Capability lookup is advisory for older drivers, but losing it also
        // drops the canSetFilterNames guard and falls back to the cached slot
        // count for the length check, so record that we are writing blind.
        _safeLog(
          (l) => l.info(
            'Filter wheel $deviceId capability lookup failed; writing slot '
            'names without the driver canSetFilterNames guard: $e',
            source: 'DeviceService',
          ),
          'filter-wheel-capabilities',
        );
      }
      if (!_isStillConnectedToFilterWheel(deviceId)) {
        throw StateError(
          'Filter wheel connection changed; names were not written.',
        );
      }
      if (capabilities != null && !capabilities.canSetFilterNames) {
        throw UnsupportedError(
          'This filter wheel does not support changing slot names.',
        );
      }
      final expectedCount =
          capabilities?.positionCount ??
          (state.filterNames.isNotEmpty ? state.filterNames.length : 0);
      if (expectedCount > 0 && normalized.length != expectedCount) {
        throw ArgumentError(
          'Expected $expectedCount filter names, got ${normalized.length}.',
        );
      }

      await _backend.filterWheelSetNames(deviceId, normalized);
      if (!_isStillConnectedToFilterWheel(deviceId)) {
        throw StateError(
          'Filter wheel connection changed after names were written.',
        );
      }
      _ref
          .read(filterWheelStateProvider.notifier)
          .setConnected(filterNames: normalized);
    } finally {
      _isFilterWheelCommandRunning = false;
    }
  }
}

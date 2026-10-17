part of '../../device_service.dart';

extension _DeviceServiceGuiderRotatorConnections on DeviceService {
  /// Connect to a guider
  Future<void> _connectGuider(String deviceId, {String? host, int? port}) {
    return _trackInFlight(() async {
      final notifier = _ref.read(guiderStateProvider.notifier);
      // PHD2 recognition is centralized in `utils/device_id.dart` so the
      // several representations a profile may have stored ('phd2',
      // 'phd2_guider', 'phd2:host:port', 'phd2://…') are handled identically
      // everywhere.
      final isPhd2 = isPhd2DeviceId(deviceId);

      // Release whatever guider currently owns the slot (see
      // [_releaseDisplacedDevice]); PHD2 normalises to its canonical id.
      await _releaseDisplacedDevice(
        DeviceType.guider,
        isPhd2 ? kPhd2CanonicalId : deviceId,
      );

      // Special handling for PHD2 guider - uses different connection method
      if (isPhd2) {
        notifier.setConnecting(kPhd2CanonicalId, 'PHD2 Guiding');
        try {
          final settings = await _ref.read(appSettingsProvider.future);
          // The caller may pin the endpoint (guiding controller's
          // `connect(host, port)`); otherwise fall back to the configured
          // PHD2 host/port. Either way the launch path uses `settings.phd2Path`
          // — the override only steers where we open the socket, never whether
          // we honour the host-authoritative NetworkBackend rule below.
          final requestedHost = host ?? settings.phd2Host;
          final requestedPort = port ?? settings.phd2Port;
          // Auto-launch PHD2 on the imaging host when the socket is local.
          // Remote companions (NetworkBackend) must not spawn processes here —
          // they delegate launch to the desktop via POST /api/phd2/connect.
          // For remote PHD2 hosts (host != localhost/127.0.0.1) we never spawn.
          final connectHost = resolvePhd2ConnectHost(requestedHost);
          if (_backend is! NetworkBackend &&
              _phd2Launcher.isLocalHost(requestedHost)) {
            await _phd2Launcher.ensureRunning(
              executablePath: settings.phd2Path,
              host: connectHost,
              port: requestedPort,
            );
          }
          await _backend.phd2Connect(host: connectHost, port: requestedPort);
          await pollPhd2Connected(_backend);
          notifier.setConnected();
        } catch (e) {
          notifier.setDisconnected();
          try {
            await _backend.phd2Disconnect();
          } catch (_) {
            // Best-effort cleanup after a failed connect attempt.
          }
          rethrow;
        }
        return;
      }

      // Standard guider connection (ASCOM/Alpaca/INDI).
      // Format check only; backend is the source of truth for
      // reachability. See [connectCamera] for the full rationale.
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('guider', deviceId);
      }

      notifier.setConnecting(
        deviceId,
        await _resolveDeviceDisplayName(DeviceType.guider, deviceId),
      );

      try {
        await _backend.connectDevice(DeviceType.guider, deviceId);
        notifier.setConnected();
      } catch (e) {
        notifier.setDisconnected();
        rethrow;
      }
    });
  }

  /// Disconnect guider
  Future<void> _disconnectGuider() {
    return _trackInFlight(() async {
      final notifier = _ref.read(guiderStateProvider.notifier);
      final state = _ref.read(guiderStateProvider);

      // Audit see [disconnectCamera] for the rationale.
      final deviceId = state.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        throw const DeviceNotConnectedException('guider');
      }

      _markUserInitiatedDisconnect(deviceId);

      try {
        // Special handling for PHD2 (recognition centralized in device_id.dart)
        if (isPhd2DeviceId(deviceId)) {
          await _backend.phd2Disconnect();
        } else {
          await _backend.disconnectDevice(DeviceType.guider, deviceId);
        }
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        rethrow;
      }
      notifier.setDisconnected();
    });
  }

  /// Connect to a rotator
  Future<void> _connectRotator(String deviceId) {
    return _trackInFlight(() async {
      final notifier = _ref.read(rotatorStateProvider.notifier);

      // Format check only; backend is the source of truth for
      // reachability. See [connectCamera] for the full rationale.
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('rotator', deviceId);
      }

      // Hand the type slot over cleanly rather than orphaning the
      // incumbent's driver connection (see [_releaseDisplacedDevice]).
      await _releaseDisplacedDevice(DeviceType.rotator, deviceId);

      notifier.setConnecting(
        deviceId,
        await _resolveDeviceDisplayName(DeviceType.rotator, deviceId),
      );

      try {
        await _backend.connectDevice(DeviceType.rotator, deviceId);
        notifier.setConnected();

        // Seed the real angle immediately. Otherwise a newly connected local
        // rotator displays "---" until the first movement event, even though
        // the driver already knows its position.
        try {
          final status = await _backend.getRotatorStatus(deviceId);
          notifier.updatePosition(
            status.position,
            mechanicalPosition: status.mechanicalPosition,
          );
          notifier.setMoving(status.moving || status.isMoving);
        } catch (e) {
          _safeLog(
            (logger) => logger.warning(
              'Failed to get initial rotator status for $deviceId: $e',
              source: 'DeviceService',
            ),
            'rotator-initial-status-fail',
          );
        }
      } catch (e) {
        notifier.setDisconnected();
        rethrow;
      }
    });
  }

  /// Disconnect rotator
  Future<void> _disconnectRotator() {
    return _trackInFlight(() async {
      final notifier = _ref.read(rotatorStateProvider.notifier);
      final state = _ref.read(rotatorStateProvider);

      // Audit see [disconnectCamera] for the rationale.
      final deviceId = state.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        throw const DeviceNotConnectedException('rotator');
      }

      _markUserInitiatedDisconnect(deviceId);
      _rotatorVerifyGeneration++;

      try {
        await _backend.disconnectDevice(DeviceType.rotator, deviceId);
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        rethrow;
      }
      notifier.setDisconnected();
    });
  }

  /// Connect to a cover calibrator (flat panel)
  Future<void> _connectCoverCalibrator(String deviceId) {
    return _trackInFlight(() async {
      final notifier = _ref.read(coverCalibratorStateProvider.notifier);

      // Format check only; backend is the source of truth for
      // reachability. See [connectCamera] for the full rationale.
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('cover calibrator', deviceId);
      }

      // Hand the type slot over cleanly rather than orphaning the
      // incumbent's driver connection (see [_releaseDisplacedDevice]).
      await _releaseDisplacedDevice(DeviceType.coverCalibrator, deviceId);

      notifier.setConnecting(
        deviceId,
        await _resolveDeviceDisplayName(DeviceType.coverCalibrator, deviceId),
      );

      try {
        await _backend.connectDevice(DeviceType.coverCalibrator, deviceId);
        notifier.setConnected();
      } catch (e) {
        notifier.setDisconnected();
        rethrow;
      }
    });
  }

  /// Disconnect cover calibrator
  Future<void> _disconnectCoverCalibrator() {
    return _trackInFlight(() async {
      final notifier = _ref.read(coverCalibratorStateProvider.notifier);
      final state = _ref.read(coverCalibratorStateProvider);

      // Audit see [disconnectCamera] for the rationale.
      final deviceId = state.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        throw const DeviceNotConnectedException('cover calibrator');
      }

      _markUserInitiatedDisconnect(deviceId);

      try {
        await _backend.disconnectDevice(DeviceType.coverCalibrator, deviceId);
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        rethrow;
      }
      notifier.setDisconnected();
    });
  }
}

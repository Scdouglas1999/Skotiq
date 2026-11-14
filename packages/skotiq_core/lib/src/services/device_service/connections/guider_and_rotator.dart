part of '../../device_service.dart';

extension _DeviceServiceGuiderRotatorConnections on DeviceService {
  /// PHD2 is reached over its own socket, not as a device. Every spelling a
  /// profile may hold for it ('phd2', 'phd2_guider', 'phd2:host:port',
  /// 'phd2://…') is recognized in `utils/device_id.dart` and lands on
  /// [kPhd2CanonicalId].
  ///
  /// [host] / [port] pin the endpoint for this connect; otherwise the
  /// configured PHD2 host and port are used.
  Future<void> _connectPhd2({String? host, int? port}) async {
    final notifier = _ref.read(guiderStateProvider.notifier);
    await _releaseDisplacedDevice(DeviceType.guider, kPhd2CanonicalId);
    notifier.setConnecting(kPhd2CanonicalId, kPhd2DisplayName);
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final requestedHost = host ?? settings.phd2Host;
      final requestedPort = port ?? settings.phd2Port;
      // PHD2 is launched only on the imaging host, and only when the socket
      // is local. A linked client asks the host to launch it instead.
      final connectHost = resolvePhd2ConnectHost(requestedHost);
      if (!_hostOwnsDevices && _phd2Launcher.isLocalHost(requestedHost)) {
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
      // A linked client's connect can time out while the host is connecting
      // or already connected; tearing down here would drop the host's
      // guider. Only the host cleans up its own failed attempt.
      if (!_hostOwnsDevices) {
        try {
          await _backend.phd2Disconnect();
        } catch (_) {
          // The connect failure is the one to report.
        }
      }
      rethrow;
    }
  }

  /// Connect the camera the built-in guider takes its frames with. The
  /// imaging camera's slot is left alone; this is a second camera.
  Future<void> _connectGuideCamera(String deviceId) {
    return _trackInFlight(() async {
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException('guide camera', deviceId);
      }
      if (deviceId == _ref.read(cameraStateProvider).deviceId) {
        throw StateError(
          'The guide camera is the imaging camera. Choose a second camera '
          'for guiding in the equipment profile.',
        );
      }
      await _backend.connectDevice(
        DeviceType.camera,
        deviceId,
        expectedModel: _expectedModelFor('guide camera', deviceId),
      );
    });
  }

  Future<void> _bringUpRotator(String deviceId) async {
    final notifier = _ref.read(rotatorStateProvider.notifier);
    notifier.setConnected();
    try {
      final status = await _backend.getRotatorStatus(deviceId);
      notifier.updatePosition(
        status.position,
        mechanicalPosition: status.mechanicalPosition,
      );
      notifier.setMoving(status.moving || status.isMoving);
    } catch (e) {
      logSafely(
        _ref,
        (logger) => logger.warning(
          'Failed to get initial rotator status for $deviceId: $e',
          source: 'DeviceService',
        ),
      );
    }
  }
}

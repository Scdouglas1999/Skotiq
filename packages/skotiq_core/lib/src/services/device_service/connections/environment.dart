part of '../../device_service.dart';

extension _DeviceServiceEnvironmentConnections on DeviceService {
  /// A failed first read is not a failed connect: the dome is connected and
  /// commandable, its readouts stay unknown, and the poll reports the error.
  Future<void> _bringUpDome(String deviceId) async {
    _ref.read(domeStateProvider.notifier).setConnected();
    if (_backend is DomeStatusBackend) {
      try {
        await _readDomeStatusInto(_backend as DomeStatusBackend, deviceId);
      } catch (_) {
        // Reported by the poll loop.
      }
    }
    _ensureEnvironmentPolling();
  }

  Future<void> _bringUpWeather(String deviceId) async {
    final notifier = _ref.read(weatherStateProvider.notifier);
    if (_backend is EnvironmentalStatusBackend) {
      final environmental = _backend as EnvironmentalStatusBackend;
      final conditions = await environmental.getHardwareWeatherConditions(
        deviceId,
      );
      notifier.updateConditions(
        temperature: conditions.temperature,
        humidity: conditions.humidity,
        pressure: conditions.pressure,
        cloudCover: conditions.cloudCover,
        dewPoint: conditions.dewPoint,
        windSpeed: conditions.windSpeed,
        windDirection: conditions.windDirection,
        skyQuality: conditions.skyQuality,
        skyTemperature: conditions.skyTemperature,
        rainRate: conditions.rainRate,
      );
    }
    notifier.setConnected();
    _ensureEnvironmentPolling();
  }

  Future<void> _bringUpSafetyMonitor(String deviceId) async {
    final notifier = _ref.read(safetyMonitorStateProvider.notifier);
    if (_backend is EnvironmentalStatusBackend) {
      final environmental = _backend as EnvironmentalStatusBackend;
      final isSafe = await environmental.getHardwareSafetyStatus(deviceId);
      notifier.updateSafetyStatus(isSafe);
    }
    notifier.setConnected();
    _ensureEnvironmentPolling();
  }

  void _ensureEnvironmentPolling() {
    if (_environmentPollTimer != null) return;
    // The dome is a separate optional role, so the loop must start for a
    // dome-only rig too — otherwise the dome card's azimuth / shutter readouts
    // are never populated on a host with no weather or safety monitor.
    if (_backend is! EnvironmentalStatusBackend &&
        _backend is! DomeStatusBackend) {
      return;
    }
    _environmentPollTimer = Timer.periodic(
      DeviceService.environmentPollInterval,
      (_) => unawaited(_pollEnvironmentalStatus()),
    );
  }

  void _stopEnvironmentPollingIfIdle() {
    final weatherPollable = _shouldPollEnvironmentSource(
      _ref.read(weatherStateProvider).connectionState,
    );
    final safetyPollable = _shouldPollEnvironmentSource(
      _ref.read(safetyMonitorStateProvider).connectionState,
    );
    final domePollable = _shouldPollEnvironmentSource(
      _ref.read(domeStateProvider).connectionState,
    );
    if (!weatherPollable && !safetyPollable && !domePollable) {
      _environmentPollTimer?.cancel();
      _environmentPollTimer = null;
    }
  }

  Future<void> _pollEnvironmentalStatus() async {
    if (_disposed || _environmentPollInFlight) return;
    final environmental = _backend is EnvironmentalStatusBackend
        ? _backend as EnvironmentalStatusBackend
        : null;
    final domeStatusBackend = _backend is DomeStatusBackend
        ? _backend as DomeStatusBackend
        : null;
    if (environmental == null && domeStatusBackend == null) return;

    _environmentPollInFlight = true;
    try {
      final weather = _ref.read(weatherStateProvider);
      final weatherId = weather.deviceId;
      if (environmental != null &&
          _shouldPollEnvironmentSource(weather.connectionState) &&
          weatherId != null) {
        try {
          final conditions = await environmental
              .getHardwareWeatherConditions(weatherId)
              .timeout(DeviceService._environmentReadTimeout);
          if (weather.connectionState == DeviceConnectionState.error) {
            _ref.read(weatherStateProvider.notifier).setConnected();
          }
          _ref
              .read(weatherStateProvider.notifier)
              .updateConditions(
                temperature: conditions.temperature,
                humidity: conditions.humidity,
                pressure: conditions.pressure,
                cloudCover: conditions.cloudCover,
                dewPoint: conditions.dewPoint,
                windSpeed: conditions.windSpeed,
                windDirection: conditions.windDirection,
                skyQuality: conditions.skyQuality,
                skyTemperature: conditions.skyTemperature,
                rainRate: conditions.rainRate,
              );
        } catch (error) {
          _ref.read(weatherStateProvider.notifier).setError(error);
        }
      }

      final safety = _ref.read(safetyMonitorStateProvider);
      final safetyId = safety.deviceId;
      if (environmental != null &&
          _shouldPollEnvironmentSource(safety.connectionState) &&
          safetyId != null) {
        try {
          final isSafe = await environmental
              .getHardwareSafetyStatus(safetyId)
              .timeout(DeviceService._environmentReadTimeout);
          if (safety.connectionState == DeviceConnectionState.error) {
            _ref.read(safetyMonitorStateProvider.notifier).setConnected();
          }
          _ref
              .read(safetyMonitorStateProvider.notifier)
              .updateSafetyStatus(isSafe);
        } catch (error) {
          _ref.read(safetyMonitorStateProvider.notifier).setError(error);
        }
      }

      final dome = _ref.read(domeStateProvider);
      final domeId = dome.deviceId;
      if (domeStatusBackend != null &&
          _shouldPollEnvironmentSource(dome.connectionState) &&
          domeId != null) {
        try {
          await _readDomeStatusInto(domeStatusBackend, domeId);
          if (dome.connectionState == DeviceConnectionState.error) {
            _ref.read(domeStateProvider.notifier).setConnected();
          }
        } catch (error) {
          _ref.read(domeStateProvider.notifier).setError(error);
        }
      }
    } finally {
      _environmentPollInFlight = false;
    }
  }

  /// Read one dome telemetry sample and publish it to [domeStateProvider].
  ///
  /// Throws whatever the driver / transport threw so the caller decides whether
  /// that is a connect abort, a poll error, or a best-effort refresh.
  Future<void> _readDomeStatusInto(
    DomeStatusBackend backend,
    String deviceId,
  ) async {
    final status = await backend
        .getHardwareDomeStatus(deviceId)
        .timeout(DeviceService._environmentReadTimeout);
    _ref
        .read(domeStateProvider.notifier)
        .applyStatus(
          azimuth: status.azimuth,
          shutterStatus: _shutterStatusFromCode(status.shutterStatus),
          isSlewing: status.isSlewing,
          isAtHome: status.isAtHome,
          isParked: status.isParked,
          isSlaved: status.isSlaved,
        );
  }

  /// Refresh dome telemetry immediately (used right after a dome command so the
  /// card reflects the new shutter/park state instead of waiting out the 5 s
  /// poll). Best-effort: a failed refresh leaves the previous reading in place
  /// and the periodic poll reports the error on its own next tick.
  Future<void> _refreshDomeStatus() async {
    if (_disposed) return;
    if (_backend is! DomeStatusBackend) return;
    final deviceId = _ref.read(domeStateProvider).deviceId;
    if (deviceId == null || deviceId.isEmpty) return;
    try {
      await _readDomeStatusInto(_backend as DomeStatusBackend, deviceId);
    } catch (_) {
      // Left to the periodic poll to classify.
    }
  }
}

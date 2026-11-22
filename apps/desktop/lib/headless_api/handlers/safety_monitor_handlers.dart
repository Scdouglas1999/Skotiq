import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';
import 'package:skotiq_core/utils.dart';

/// Handlers for safety monitor endpoints
///
/// Safety monitors report whether it is safe to continue observing based on
/// various conditions like weather, power status, or custom sensor inputs.
/// Multiple safety monitors can be connected, and all must report "safe"
/// for the system to consider conditions safe for imaging.
class SafetyMonitorHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    SafetyMonitorApi.safetyStatus: handleSafetyStatus,
    SafetyMonitorApi.getSafetySettings: handleGetSafetySettings,
    SafetyMonitorApi.updateSafetySettings: handleUpdateSafetySettings,
    SafetyMonitorApi.acknowledgeUnsafe: handleAcknowledgeUnsafe,
    SafetyMonitorApi.cancelAcknowledgement: handleCancelAcknowledgement,
  };

  final ProviderContainer container;

  SafetyMonitorHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'SafetyMonitorHandlers');
  void _logError(String message) =>
      _logger.error(message, source: 'SafetyMonitorHandlers');

  // Safety-config persistence keys now live on the canonical
  // [SafetyConfigStore] so the read/write routing has one owner. The
  // last-acknowledgement key is endpoint-local (not part of SafetyConfig) and
  // stays here.
  static const _kWarningDelayKey = SafetyConfigStore.kWarningDelayKey;
  static const _kLastAckKey = 'safety_last_acknowledgement';

  String _failModeToApi(SafetyFailMode mode) => switch (mode) {
    SafetyFailMode.failOpen => 'fail_open',
    SafetyFailMode.failClosed => 'fail_closed',
    SafetyFailMode.warnOnly => 'warn_only',
  };

  SafetyFailMode _failModeFromApi(String value) => switch (value) {
    'fail_open' => SafetyFailMode.failOpen,
    'fail_closed' => SafetyFailMode.failClosed,
    'warn_only' => SafetyFailMode.warnOnly,
    _ => SafetyFailMode.failClosed,
  };

  int _parseIntSetting(Map<String, String> settings, String key, int fallback) {
    final raw = settings[key];
    if (raw == null) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  /// Build the `/api/safety/settings` payload from the single consolidated
  /// [SafetyConfig]. The read path that stitches the three stores lives behind
  /// [SafetyConfigStore.load], so no consumer can compute a divergent view.
  Future<Map<String, dynamic>> _buildSettingsPayload() async {
    final appSettings = container.read(appSettingsProvider).valueOrNull;
    final config = await container
        .read(safetyConfigStoreProvider)
        .load(appSettings: appSettings);

    return {
      'failMode': _failModeToApi(config.safetyFailMode),
      'checkIntervalSeconds': config.checkIntervalSeconds,
      'autoStopOnUnsafe': config.autoStopOnUnsafe,
      'autoParkOnUnsafe': config.autoParkOnUnsafe,
      'autoCloseRoofOnUnsafe': config.autoCloseRoofOnUnsafe,
      'warningDelaySeconds': config.warningDelaySeconds,
      'requiredSafeDurationSeconds': config.requiredSafeDurationSeconds,
      'enabledMonitors': <String>[],
    };
  }

  /// GET /api/safety/status
  /// Gets the current safety status from all connected safety monitors.
  /// Query params: deviceId=safety_monitor_id (optional - if not provided, returns status from all monitors)
  Future<Response> handleSafetyStatus(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'];

    List<DeviceInfo> connectedDevices = [];
    try {
      final backend = container.read(deviceBackendProvider);
      connectedDevices = await backend.getConnectedDevices();
    } catch (e) {
      _logError('Failed to read connected devices for safety status: $e');
    }

    final safetyMonitors = connectedDevices
        .where((d) => d.deviceType == DeviceType.safetyMonitor)
        .toList();

    final safetyMonitorState = container.read(safetyMonitorStateProvider);

    if (deviceId != null && deviceId.isNotEmpty) {
      final monitor = safetyMonitors.firstWhere(
        (d) => d.id == deviceId,
        orElse: () => const DeviceInfo(
          id: '',
          name: '',
          deviceType: DeviceType.safetyMonitor,
          driverType: DriverType.simulator,
          description: '',
          driverVersion: '',
        ),
      );

      if (monitor.id.isEmpty) {
        return jsonResponse({
          "connected": false,
          "deviceId": deviceId,
          "error":
              "Safety monitor '$deviceId' not connected - cannot determine safety state",
        }, statusCode: 503);
      }

      final isDeviceMatch = safetyMonitorState.deviceId == deviceId;
      final isConnected =
          isDeviceMatch &&
          safetyMonitorState.connectionState == DeviceConnectionState.connected;

      if (!isConnected) {
        return jsonResponse({
          "connected": false,
          "deviceId": deviceId,
          "error":
              "Safety monitor '$deviceId' found but not in connected state - cannot determine safety state",
        }, statusCode: 503);
      }

      return jsonOk({
        "connected": true,
        "deviceId": deviceId,
        "deviceName": monitor.name,
        "isSafe": safetyMonitorState.isSafe,
        "lastChecked": safetyMonitorState.lastChecked?.toWireTime(),
        "lastUpdate": DateTime.now().toWireTime(),
      });
    }

    // Return aggregate status from all monitors using the weather safety provider
    // which already combines all safety sources (API weather, hardware weather, safety monitors)
    final weatherSafety = container.read(weatherSafetyProvider);

    if (safetyMonitors.isEmpty) {
      // No safety monitors connected - use aggregate weather safety state
      // but report accurately that no monitors are connected
      return jsonOk({
        ...weatherSafety.toJson(),
        "monitorsConnected": 0,
        "monitors": <Map<String, dynamic>>[],
        "lastUpdate": DateTime.now().toWireTime(),
      });
    }

    final monitorStatuses = safetyMonitors.map((m) {
      final isThisDevice = safetyMonitorState.deviceId == m.id;
      final isConnected =
          isThisDevice &&
          safetyMonitorState.connectionState == DeviceConnectionState.connected;

      return {
        'deviceId': m.id,
        'deviceName': m.name,
        'connected': isConnected,
        'isSafe': isConnected ? safetyMonitorState.isSafe : null,
        'lastChecked': isConnected
            ? safetyMonitorState.lastChecked?.toWireTime()
            : null,
      };
    }).toList();

    return jsonOk({
      ...weatherSafety.toJson(),
      "monitorsConnected": safetyMonitors.length,
      "monitors": monitorStatuses,
      "lastUpdate": DateTime.now().toWireTime(),
    });
  }

  /// GET /api/safety/settings
  /// Gets safety-related settings.
  Future<Response> handleGetSafetySettings(Request request) async {
    final payload = await _buildSettingsPayload();

    try {
      final backend = container.read(deviceBackendProvider);
      final connectedDevices = await backend.getConnectedDevices();
      payload['enabledMonitors'] = connectedDevices
          .where((d) => d.deviceType == DeviceType.safetyMonitor)
          .map((d) => d.id)
          .toList();
    } catch (e) {
      _logError('Failed to read connected safety monitors: $e');
      payload['enabledMonitors'] = <String>[];
    }

    return jsonOk(payload);
  }

  /// POST /api/safety/settings
  /// Updates safety-related settings.
  /// Request body: { "failMode": "fail_closed", "checkIntervalSeconds": 60, ... }
  Future<Response> handleUpdateSafetySettings(Request request) async {
    _logInfo('POST /api/safety/settings');
    final payload = await readJsonObject(request);

    final failMode = optionalString(payload, 'failMode');
    if (failMode != null) {
      const validModes = ['fail_open', 'fail_closed', 'warn_only'];
      if (!validModes.contains(failMode)) {
        throw BadRequestError(
          field: 'failMode',
          expected: 'string',
          message: 'Must be one of: ${validModes.join(', ')}',
        );
      }
    }

    optionalInt(payload, 'checkIntervalSeconds', min: 5, max: 3600);
    optionalInt(payload, 'warningDelaySeconds', min: 0);
    optionalInt(payload, 'requiredSafeDurationSeconds', min: 0);

    final settingsNotifier = container.read(appSettingsProvider.notifier);
    final safetyConfig = container.read(safetyConfigStoreProvider);

    if (failMode != null) {
      final mode = _failModeFromApi(failMode);
      // safety_fail_mode is owned by app_settings; the notifier setter is the
      // canonical writer so state + persistence stay in lockstep.
      await settingsNotifier.setSafetyFailMode(mode);
    }

    final autoParkOnUnsafe = optionalBool(payload, 'autoParkOnUnsafe');
    if (autoParkOnUnsafe != null) {
      // park_on_unsafe_weather lives in app_settings (notifier-owned) and is
      // combined with the weather-side autoParkEnabled toggle in the facade.
      await settingsNotifier.setParkOnUnsafeWeather(autoParkOnUnsafe);
      await safetyConfig.setAutoParkOnUnsafe(autoParkOnUnsafe);
    }

    final autoStopOnUnsafe = optionalBool(payload, 'autoStopOnUnsafe');
    if (autoStopOnUnsafe != null) {
      await safetyConfig.setAutoStopOnUnsafe(autoStopOnUnsafe);
    }

    final autoCloseRoofOnUnsafe = optionalBool(
      payload,
      'autoCloseRoofOnUnsafe',
    );
    if (autoCloseRoofOnUnsafe != null) {
      await safetyConfig.setAutoCloseRoofOnUnsafe(autoCloseRoofOnUnsafe);
    }

    final checkInterval = optionalInt(payload, 'checkIntervalSeconds');
    if (checkInterval != null) {
      await safetyConfig.setCheckIntervalSeconds(checkInterval);
    }

    final warningDelay = optionalInt(payload, 'warningDelaySeconds');
    if (warningDelay != null) {
      await safetyConfig.setWarningDelaySeconds(warningDelay);
    }

    final requiredSafe = optionalInt(payload, 'requiredSafeDurationSeconds');
    if (requiredSafe != null) {
      await safetyConfig.setRequiredSafeDurationSeconds(requiredSafe);
    }

    final updated = await _buildSettingsPayload();
    return jsonOk({'status': 'updated', 'settings': updated});
  }

  /// POST /api/safety/acknowledge
  /// Acknowledges an unsafe condition, allowing operations to continue despite the warning.
  /// This is typically used when the operator has manually verified conditions are acceptable.
  /// Request body: { "deviceId": "safety_monitor_id", "reason": "Manually verified conditions", "durationMinutes": 60 }
  Future<Response> handleAcknowledgeUnsafe(Request request) async {
    _logInfo('POST /api/safety/acknowledge');
    final payload = await readJsonObject(request);
    final reason = requireString(payload, 'reason');
    final durationMinutes =
        optionalInt(payload, 'durationMinutes', min: 1) ?? 60;

    final stored = await container.read(settingsDaoProvider).getAllSettings();
    final ackRecord = {
      'reason': reason,
      'deviceId': optionalString(payload, 'deviceId'),
      'durationMinutes': durationMinutes,
      'acknowledgedAt': DateTime.now().toWireTime(),
    };
    await container
        .read(settingsDaoProvider)
        .setSetting(_kLastAckKey, jsonEncode(ackRecord));

    container
        .read(weatherSafetyProvider.notifier)
        .snooze(Duration(minutes: durationMinutes), reason: reason);

    _logInfo('Safety conditions acknowledged for ${durationMinutes}m: $reason');

    return jsonOk({
      'status': 'acknowledged',
      'snoozeUntil': DateTime.now()
          .add(Duration(minutes: durationMinutes))
          .toWireTime(),
      'warningDelaySeconds': _parseIntSetting(stored, _kWarningDelayKey, 60),
    });
  }

  Future<Response> handleCancelAcknowledgement(Request request) async {
    _logInfo('POST /api/safety/cancel-acknowledgement');
    container.read(weatherSafetyProvider.notifier).cancelSnooze();
    await container.read(settingsDaoProvider).deleteSetting(_kLastAckKey);
    return jsonOk({'status': 'cancelled'});
  }
}

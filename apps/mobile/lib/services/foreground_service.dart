import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'notification_service.dart';

class ImagingForegroundService {
  static final ImagingForegroundService _instance =
      ImagingForegroundService._internal();
  factory ImagingForegroundService() => _instance;
  ImagingForegroundService._internal();

  bool _isRunning = false;
  String _currentTarget = '';
  int _completedExposures = 0;
  double _percentComplete = 0.0;

  bool get isRunning => _isRunning;

  Future<void> initialize() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'skotiq_imaging',
        channelName: 'Skotiq Imaging',
        channelDescription: 'Displays imaging sequence progress',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: false,
        allowWakeLock: true,
        // some OEM aggressive battery firmware
        // (Xiaomi, Huawei, Samsung) releases WiFi when the screen is off
        // even with a foreground service running, which silently kills
        // the WS mid-sequence. Holding a WiFi lock for the lifetime of
        // the foreground service prevents that. The CHANGE_WIFI_STATE +
        // WAKE_LOCK manifest permissions are required for this to take
        // effect; both are declared in AndroidManifest.xml.
        allowWifiLock: true,
      ),
    );
  }

  /// Ask the OS to whitelist this app from battery optimization so the
  /// foreground service is not killed during long sequences. The user
  /// sees a system dialog asking whether to ignore battery optimizations
  /// for Skotiq. Returns true if the user has whitelisted (or had
  /// already whitelisted) the app.
  ///
  /// Safe to call multiple times; the OS only prompts when the current
  /// state is "not whitelisted".
  Future<bool> requestIgnoreBatteryOptimization() async {
    try {
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (e, st) {
      // Don't silently swallow — surface and treat as denied. The
      // foreground service still runs without the whitelist; it's
      // just more likely to be killed on aggressive OEMs.
      developer.log(
        'requestIgnoreBatteryOptimization failed: $e',
        name: 'ImagingForegroundService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  /// Ask Android for the runtime POST_NOTIFICATIONS permission via the
  /// foreground-task plugin's helper. Equivalent in effect to
  /// `flutter_local_notifications`'s `requestNotificationsPermission()`,
  /// but the foreground-task plugin uses its own permission check before
  /// it will start a service — so it must see "granted" too. Returns
  /// true on a granted decision.
  Future<bool> requestNotificationPermission() async {
    try {
      final result =
          await FlutterForegroundTask.requestNotificationPermission();
      return result == NotificationPermission.granted;
    } catch (e, st) {
      developer.log(
        'FlutterForegroundTask.requestNotificationPermission failed: $e',
        name: 'ImagingForegroundService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  Future<bool> startService({
    required String targetName,
    required int totalExposures,
  }) async {
    _currentTarget = targetName;
    _completedExposures = 0;
    _percentComplete = 0.0;

    if (await FlutterForegroundTask.isRunningService) {
      final restarted = await FlutterForegroundTask.restartService();
      if (restarted) {
        _isRunning = true;
      }
      return restarted;
    } else {
      final started = await FlutterForegroundTask.startService(
        notificationTitle: 'Imaging $targetName',
        notificationText: 'Starting sequence... (0/$totalExposures)',
        callback: startCallback,
      );
      if (started) {
        _isRunning = true;
      }
      return started;
    }
  }

  void updateProgress({
    required int completedExposures,
    required int totalExposures,
    String? currentFilter,
    String? statusMessage,
  }) {
    if (!_isRunning) return;

    _completedExposures = completedExposures;
    _percentComplete = totalExposures > 0
        ? (completedExposures / totalExposures) * 100
        : 0;

    // Render completed/total plus a percentage so the operator can see
    // long-sequence progress at a glance.
    final percentText = _percentComplete > 0
        ? ' (${_percentComplete.toStringAsFixed(0)}%)'
        : '';
    String text = '$completedExposures/$totalExposures exposures$percentText';
    if (currentFilter != null) {
      text += ' ($currentFilter)';
    }
    if (statusMessage != null && statusMessage.isNotEmpty) {
      text += ' - $statusMessage';
    }

    FlutterForegroundTask.updateService(
      notificationTitle: 'Imaging $_currentTarget',
      notificationText: text,
    );

    // Note: sendDataToTask removed in v6.0.0+
    // Data is now sent via updateService notification only
  }

  Future<void> stopService({
    bool sequenceCompleted = false,
    String? errorMessage,
  }) async {
    if (!_isRunning) return;

    // Send final notification before stopping service
    if (sequenceCompleted) {
      await MobileNotificationService().notifySequenceComplete(
        _currentTarget,
        _completedExposures,
      );
    } else if (errorMessage != null) {
      await MobileNotificationService().notifySequenceFailed(
        _currentTarget,
        errorMessage,
      );
    }

    await FlutterForegroundTask.stopService();
    _isRunning = false;
    _currentTarget = '';
    _completedExposures = 0;
    _percentComplete = 0.0;
  }

  void setRunning(bool running) {
    _isRunning = running;
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(ImagingTaskHandler());
}

class ImagingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    ImagingForegroundService().setRunning(true);
    // Deliberately do not call updateService here with a placeholder
    // notification text — the main isolate's [ImagingForegroundService.
    // startService] already wrote "Starting sequence... (0/N)" via the
    // service start call, and [updateProgress] from the sequence-event
    // listener will overwrite it the moment the first progress event
    // lands. Writing a hardcoded placeholder from this handler would
    // race with the main isolate and clobber the real progress text.
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    // Intentionally a no-op; kept because the plugin's [TaskHandler]
    // interface requires the override.
    //
    // The notification text is the run's real progress, written from the main
    // isolate by the sequence event listener (see
    // `ImagingForegroundService.updateProgress` in this file, called from
    // `MobileSequenceHooks._handleProgressUpdate`). A periodic overwrite from
    // this isolate would replace it with a generic placeholder every few
    // seconds.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    ImagingForegroundService().setRunning(false);
  }

  @override
  void onNotificationPressed() {
    // Handle notification tap - app will be brought to foreground
    FlutterForegroundTask.launchApp('/');
  }
}

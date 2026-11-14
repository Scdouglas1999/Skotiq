import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'mobile_preferences.dart';
import 'notification_service.dart';
import 'package:skotiq_core/services.dart';

enum BatteryWarningLevel { normal, low, veryLow, critical }

class PowerService {
  static final PowerService _instance = PowerService._internal();
  factory PowerService() => _instance;
  PowerService._internal();

  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batteryStateSubscription;
  Timer? _batteryMonitorTimer;

  bool _wakeLockActive = false;
  bool _isMonitoring = false;

  int _currentBatteryLevel = 100;
  BatteryState _currentBatteryState = BatteryState.full;
  BatteryWarningLevel _lastWarningLevel = BatteryWarningLevel.normal;

  Function(int percentage)? onBatteryLevelChanged;
  Function(BatteryState state)? onBatteryStateChanged;
  Function(BatteryWarningLevel level)? onBatteryWarning;
  Function()? onCriticalBattery;

  // Settings
  // Only CPU wake lock is honored. Screen wake lock was an unused config
  // surface that misled callers.
  bool enableCpuWakeLock = true; // Keep CPU awake (required for imaging)
  int batteryCheckIntervalSeconds = 30;

  bool get wakeLockActive => _wakeLockActive;
  int get currentBatteryLevel => _currentBatteryLevel;
  BatteryState get currentBatteryState => _currentBatteryState;
  bool get isMonitoring => _isMonitoring;

  Stream<int> get batteryLevelStream => _batteryLevelStreamController.stream;
  final _batteryLevelStreamController = StreamController<int>.broadcast();

  Future<void> initialize() async {
    _currentBatteryLevel = await _battery.batteryLevel;
    _currentBatteryState = await _battery.batteryState;

    _batteryStateSubscription = _battery.onBatteryStateChanged.listen((state) {
      _currentBatteryState = state;
      onBatteryStateChanged?.call(state);

      if (state == BatteryState.charging || state == BatteryState.full) {
        _lastWarningLevel = BatteryWarningLevel.normal;
      }
    });
  }

  Future<void> acquireWakeLock() async {
    if (_wakeLockActive) return;

    try {
      if (enableCpuWakeLock) {
        await WakelockPlus.enable();
        _wakeLockActive = true;
        Log.info('Wake lock acquired (CPU)', source: 'PowerService');
      }
    } catch (e, st) {
      // Caught + degraded: imaging may pause when OS suspends. Severe so
      // operators notice in the log file post-session.
      Log.error(
        'Failed to acquire wake lock: $e',
        source: 'PowerService',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> releaseWakeLock() async {
    if (!_wakeLockActive) return;

    try {
      await WakelockPlus.disable();
      _wakeLockActive = false;
      Log.info('Wake lock released', source: 'PowerService');
    } catch (e, st) {
      // Caught + degraded: wake lock stays held until process exit. This
      // leaks battery; severe so it surfaces in the log file.
      Log.error(
        'Failed to release wake lock: $e',
        source: 'PowerService',
        error: e,
        stackTrace: st,
      );
    }
  }

  void startBatteryMonitoring() {
    if (_isMonitoring) return;

    _isMonitoring = true;
    Log.info(
      'Started battery monitoring (interval: ${batteryCheckIntervalSeconds}s)',
      source: 'PowerService',
    );

    _batteryMonitorTimer = Timer.periodic(
      Duration(seconds: batteryCheckIntervalSeconds),
      (_) => _checkBatteryLevel(),
    );

    _checkBatteryLevel();
  }

  void stopBatteryMonitoring() {
    if (!_isMonitoring) return;

    _batteryMonitorTimer?.cancel();
    _batteryMonitorTimer = null;
    _isMonitoring = false;
    _lastWarningLevel = BatteryWarningLevel.normal;

    Log.info('Stopped battery monitoring', source: 'PowerService');
  }

  Future<void> _checkBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      _currentBatteryLevel = level;

      _batteryLevelStreamController.add(level);

      onBatteryLevelChanged?.call(level);

      final warningLevel = _getBatteryWarningLevel(level);

      if (warningLevel != _lastWarningLevel &&
          _currentBatteryState != BatteryState.charging &&
          _currentBatteryState != BatteryState.full) {
        _lastWarningLevel = warningLevel;

        // The "Battery warnings" toggle only mutes the notification banner;
        // the callbacks fire regardless. Neither pauses the run: the phone's
        // battery is no risk to the rig.
        final prefs = await SharedPreferences.getInstance();
        final notifyBattery = MobilePreferences(prefs).notifyBattery;

        switch (warningLevel) {
          case BatteryWarningLevel.low:
            if (notifyBattery) {
              await MobileNotificationService().notifyLowBattery(level);
            }
            onBatteryWarning?.call(warningLevel);
            break;

          case BatteryWarningLevel.veryLow:
            if (notifyBattery) {
              await MobileNotificationService().notifyLowBattery(level);
            }
            onBatteryWarning?.call(warningLevel);
            break;

          case BatteryWarningLevel.critical:
            if (notifyBattery) {
              await MobileNotificationService().notifyLowBattery(level);
            }
            onBatteryWarning?.call(warningLevel);
            onCriticalBattery?.call();
            break;

          case BatteryWarningLevel.normal:
            break;
        }
      }
    } catch (e, st) {
      // Caught + degraded: a single failed sample is fine, the periodic
      // timer keeps trying. Warn so repeated failures are visible.
      Log.warning(
        'Error checking battery level: $e',
        source: 'PowerService',
        error: e,
        stackTrace: st,
      );
    }
  }

  BatteryWarningLevel _getBatteryWarningLevel(int percentage) {
    if (percentage <= 10) {
      return BatteryWarningLevel.critical;
    } else if (percentage <= 15) {
      return BatteryWarningLevel.veryLow;
    } else if (percentage <= 20) {
      return BatteryWarningLevel.low;
    } else {
      return BatteryWarningLevel.normal;
    }
  }

  Future<void> startImagingSession() async {
    Log.info('Starting imaging session', source: 'PowerService');
    await acquireWakeLock();
    startBatteryMonitoring();
  }

  Future<void> stopImagingSession() async {
    Log.info('Stopping imaging session', source: 'PowerService');
    stopBatteryMonitoring();
    await releaseWakeLock();
  }

  Future<void> dispose() async {
    await _batteryStateSubscription?.cancel();
    _batteryMonitorTimer?.cancel();
    await _batteryLevelStreamController.close();
    if (_wakeLockActive) {
      await releaseWakeLock();
    }
  }

  bool shouldWarnForBattery() {
    return _currentBatteryLevel <= 15 &&
        _currentBatteryState != BatteryState.charging &&
        _currentBatteryState != BatteryState.full;
  }
}

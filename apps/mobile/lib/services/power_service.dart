import 'dart:async';
import 'dart:developer' as developer;
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'mobile_preferences.dart';
import 'notification_service.dart';

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

  // Callbacks for battery events
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
    // Get initial battery level
    _currentBatteryLevel = await _battery.batteryLevel;
    _currentBatteryState = await _battery.batteryState;

    // Listen to battery state changes (charging/discharging)
    _batteryStateSubscription = _battery.onBatteryStateChanged.listen((state) {
      _currentBatteryState = state;
      onBatteryStateChanged?.call(state);

      // Cancel critical warnings if charging
      if (state == BatteryState.charging || state == BatteryState.full) {
        _lastWarningLevel = BatteryWarningLevel.normal;
      }
    });
  }

  Future<void> acquireWakeLock() async {
    if (_wakeLockActive) return;

    try {
      if (enableCpuWakeLock) {
        // Enable wake lock to keep CPU running
        await WakelockPlus.enable();
        _wakeLockActive = true;
        developer.log(
          'Wake lock acquired (CPU)',
          name: 'PowerService',
          level: 800,
        );
      }
    } catch (e, st) {
      // Caught + degraded: imaging may pause when OS suspends. Severe so
      // operators notice in the log file post-session.
      developer.log(
        'Failed to acquire wake lock: $e',
        name: 'PowerService',
        level: 1000,
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
      developer.log('Wake lock released', name: 'PowerService', level: 800);
    } catch (e, st) {
      // Caught + degraded: wake lock stays held until process exit. This
      // leaks battery; severe so it surfaces in the log file.
      developer.log(
        'Failed to release wake lock: $e',
        name: 'PowerService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
    }
  }

  void startBatteryMonitoring() {
    if (_isMonitoring) return;

    _isMonitoring = true;
    developer.log(
      'Started battery monitoring (interval: ${batteryCheckIntervalSeconds}s)',
      name: 'PowerService',
      level: 800,
    );

    // Check battery level periodically
    _batteryMonitorTimer = Timer.periodic(
      Duration(seconds: batteryCheckIntervalSeconds),
      (_) => _checkBatteryLevel(),
    );

    // Initial check
    _checkBatteryLevel();
  }

  void stopBatteryMonitoring() {
    if (!_isMonitoring) return;

    _batteryMonitorTimer?.cancel();
    _batteryMonitorTimer = null;
    _isMonitoring = false;
    _lastWarningLevel = BatteryWarningLevel.normal;

    developer.log(
      'Stopped battery monitoring',
      name: 'PowerService',
      level: 800,
    );
  }

  Future<void> _checkBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      _currentBatteryLevel = level;

      // Emit to stream
      _batteryLevelStreamController.add(level);

      // Notify callback
      onBatteryLevelChanged?.call(level);

      // Check if we need to warn about battery level
      final warningLevel = _getBatteryWarningLevel(level);

      // Only notify if warning level changed and not charging
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
            // Battery level returned to normal
            break;
        }
      }
    } catch (e, st) {
      // Caught + degraded: a single failed sample is fine, the periodic
      // timer keeps trying. Warn so repeated failures are visible.
      developer.log(
        'Error checking battery level: $e',
        name: 'PowerService',
        level: 900,
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
    developer.log('Starting imaging session', name: 'PowerService', level: 800);
    await acquireWakeLock();
    startBatteryMonitoring();
  }

  Future<void> stopImagingSession() async {
    developer.log('Stopping imaging session', name: 'PowerService', level: 800);
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

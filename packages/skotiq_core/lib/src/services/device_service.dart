import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/equipment_provider.dart';
import '../providers/equipment/device_type_registry.dart';
import '../providers/profiles_provider.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart' show settingsDaoProvider;
import '../providers/focuser_backlash_provider.dart'
    show
        focuserBacklashCalibrationSettingsProvider,
        focuserBacklashOfferSessionProvider;
import '../providers/sequence_provider.dart';
import '../providers/session_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/ui_notification_provider.dart';
import '../providers/operation_progress_provider.dart';
import '../providers/filter_offset_provider.dart';
import '../providers/current_screen_provider.dart';
import '../providers/app_version_provider.dart';
import '../providers/autofocus_progress_provider.dart';
import '../providers/unified_discovery_provider.dart';
import 'smart_notification_service.dart';
import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart' hide TrackingRate;
import '../backend/skotiq_exception.dart' show ConnectionException;
import '../models/equipment/equipment_models.dart';
import '../models/imaging/imaging_models.dart'
    show AutofocusSettings, FilterAutofocusConfig;
import '../utils/coordinate_format.dart';
import '../utils/device_id.dart';
import 'camera_temperature_poller.dart';
import 'camera_warmup_controller.dart';
import 'device_heartbeat_router.dart';
import 'device_reconnect_coordinator.dart';
import 'device_exceptions.dart';
import 'mount_home_watcher.dart';
import 'logging_service.dart';
import 'error_service.dart';
import 'phd2_launcher.dart';
import 'phd2_status_poll.dart';
import 'predictive_af_service.dart';
import 'switch_channel_service.dart';
import 'device_service_lifecycle.dart';
import 'device_service/profile_device_resolution.dart';
import 'profile_service.dart' show profileServiceProvider;
import '../models/focuser_backlash_calibration.dart';
import '../models/mount_site_reconciliation.dart';
import '../providers/mount_site_provider.dart';

// Re-export backend types so importers of this file get them too.
export '../models/backend/device_types.dart' show DeviceType, DriverType;
export '../models/backend/device_info.dart' show DeviceInfo;

part 'device_service/event_handling.dart';
part 'device_service/control_helpers.dart';
part 'device_service/connections/imaging_chain.dart';
part 'device_service/connections/guider_and_rotator.dart';
part 'device_service/connections/environment.dart';
part 'device_service/connections/environment_codes.dart';
part 'device_service/connections/switch_device.dart';
part 'device_service/device_slots.dart';
part 'device_service/profile_connections.dart';
part 'device_service/mount_controls.dart';
part 'device_service/focuser_rotator_controls.dart';
part 'device_service/autofocus_controls.dart';
part 'device_service/focuser_backlash_calibration.dart';
part 'device_service/filter_wheel_controls.dart';
part 'device_service/guiding_sequencer_controls.dart';

/// Extension methods for DeviceType display
extension DeviceTypeDisplayExtension on DeviceType {
  String get displayName {
    switch (this) {
      case DeviceType.camera:
        return 'Camera';
      case DeviceType.mount:
        return 'Mount';
      case DeviceType.focuser:
        return 'Focuser';
      case DeviceType.filterWheel:
        return 'Filter Wheel';
      case DeviceType.guider:
        return 'Guider';
      case DeviceType.rotator:
        return 'Rotator';
      case DeviceType.dome:
        return 'Dome';
      case DeviceType.weather:
        return 'Weather';
      case DeviceType.safetyMonitor:
        return 'Safety Monitor';
      case DeviceType.switch_:
        return 'Switch';
      case DeviceType.coverCalibrator:
        return 'Cover Calibrator';
    }
  }
}

/// Extension methods for DriverType display
extension DriverTypeDisplayExtension on DriverType {
  String get displayName {
    switch (this) {
      case DriverType.ascom:
        return 'ASCOM';
      case DriverType.alpaca:
        return 'Alpaca';
      case DriverType.indi:
        return 'INDI';
      case DriverType.native:
        return 'Native';
      case DriverType.simulator:
        return 'Simulator';
    }
  }
}

/// Service for managing device discovery and connections
///
/// This service uses the SkotiqBackend abstraction to communicate
/// with devices via different backends (FFI for desktop, Network for mobile).
class DeviceService {
  final Ref _ref;
  final SkotiqBackend _backend;

  // Per-channel switch refresh + write logic lives on [SwitchChannelService]
  // (god-class split follow-up). The four `switchBridge*`
  // static hooks and the `switchBridgeBypassBackendCheck` flag now live
  // on that class; tests bind directly via
  // `SwitchChannelService.switchBridge* = ...` and reset with
  // `SwitchChannelService.resetHooks()` in `tearDown`.
  StreamSubscription? _eventSubscription;
  late final CameraTemperaturePoller _temperaturePoller;
  late final CameraWarmupController _warmupController;
  late final Phd2Launcher _phd2Launcher;
  late final DeviceReconnectCoordinator _reconnectCoordinator;
  late final DeviceHeartbeatRouter _heartbeat;
  late final SwitchChannelService _switchChannels;

  static const Duration _filterWheelVerifyTimeout = Duration(seconds: 60);

  /// Bound on the discovery that checks a profile's positional device ids
  /// before Connect All. ASCOM enumeration is the slow part.
  static const Duration _profilePositionDiscoveryTimeout = Duration(
    seconds: 20,
  );
  static const Duration _filterWheelVerifyPollInterval = Duration(
    milliseconds: 250,
  );

  static const Duration _focuserMoveTimeout = Duration(seconds: 300);
  static const Duration _focuserMovePollInterval = Duration(milliseconds: 500);

  int _focuserVerifyGeneration = 0;
  int _rotatorVerifyGeneration = 0;
  int _filterWheelVerifyGeneration = 0;
  Timer? _environmentPollTimer;
  bool _environmentPollInFlight = false;

  /// How often environmental / dome telemetry is re-read while a relevant device
  /// is connected.
  ///
  /// Public so a UI showing the AGE of these readings can assert its own ticker
  /// runs faster than this; ticking at the same period samples a fixed phase
  /// offset between two timers rather than elapsed time.
  static const Duration environmentPollInterval = Duration(seconds: 5);

  /// Hard cap on a single environmental / dome telemetry read.
  ///
  /// Without it a driver that accepts the call and never answers pins
  /// `_environmentPollInFlight` for the rest of the process: every later tick
  /// returns early, `setError` is never reached, and the card keeps rendering
  /// the last good value — a safety monitor frozen on "SAFE" while nothing is
  /// being read. Shorter than the 5 s tick so a wedged read surfaces
  /// as an error before the next poll instead of silently stacking up.
  static const Duration _environmentReadTimeout = Duration(seconds: 4);

  /// Manual focuser moves are exclusive across every UI surface. A widget's
  /// local busy flag cannot prevent a dashboard button and an equipment dialog
  /// from driving the same focuser at the same time.
  bool _isFocuserMoveRunning = false;
  bool _isFilterWheelCommandRunning = false;
  bool _isRotatorCommandRunning = false;

  /// Tracks the last applied filter focus offset per filter wheel so that
  /// multiple wheels do not clobber each other's delta calculations.
  final Map<String, int> _lastAppliedFilterOffsetByWheel = {};

  /// In-flight guarded operations — backend swap waits for zero.
  int _inFlightOperations = 0;
  final List<Completer<void>> _quiesceWaiters = [];

  bool _disposed = false;

  static const Duration _quiesceTimeout = Duration(seconds: 30);

  /// Guard against concurrent autofocus runs. Only one AF can run at a time
  /// since the focuser and camera are shared hardware resources.
  bool _isAutofocusRunning = false;
  bool _autofocusCancelRequested = false;

  bool get isAutofocusRunning => _isAutofocusRunning;

  /// Guard against a backlash calibration overlapping an autofocus sweep or
  /// another calibration: both drive the same camera and focuser.
  bool _isFocuserBacklashCalibrationRunning = false;

  bool get isFocuserBacklashCalibrationRunning =>
      _isFocuserBacklashCalibrationRunning;

  /// The build stamped into a calibration record, so a stored figure can be
  /// traced to the version that measured it.
  ///
  /// [appVersionProvider] throws when it has not been overridden, which is
  /// every test bench. An unstamped record is honest; a made-up version is
  /// not, so the fallback is blank rather than a plausible number.
  String _appVersionForCalibrationRecord() {
    try {
      return _ref.read(appVersionProvider).toString();
    } catch (_) {
      return '';
    }
  }

  /// The backend whose events this service is listening to.
  SkotiqBackend get eventSource => _backend;

  DeviceService(this._ref, this._backend) {
    _temperaturePoller = CameraTemperaturePoller(ref: _ref, backend: _backend);
    _warmupController = CameraWarmupController(ref: _ref, backend: _backend);
    _phd2Launcher = Phd2Launcher(ref: _ref);
    // Construct the heartbeat router first so the reconnect coordinator
    // can drive the "reconnecting" health indicator through it (the
    // native HeartbeatReconnecting event is never emitted, so the Dart
    // side surfaces that state from the reconnect signals it does see).
    _heartbeat = DeviceHeartbeatRouter(ref: _ref, backend: _backend);
    _reconnectCoordinator = DeviceReconnectCoordinator(
      ref: _ref,
      backend: _backend,
      resumeSequence: resumeSequence,
      pauseSequence: pauseSequence,
      surfaceReconnecting: (deviceId, {int attempt = 0, int maxAttempts = 0}) =>
          _heartbeat.surfaceReconnecting(
            deviceId: deviceId,
            attempt: attempt,
            maxAttempts: maxAttempts,
          ),
    );
    _switchChannels = SwitchChannelService(ref: _ref, backend: _backend);
    DeviceServiceLifecycle.register(this);
    _initEventListening();
  }

  /// Emits a diagnostic line through the logging service, but never lets a
  /// logger-emission failure mask a higher-priority device fault. We deliberately
  /// catch every kind of error from the logger lookup (e.g. provider mid-disposal
  /// during shutdown) and demote to a stderr line — fail-closed for the calling
  /// device operation, soft for the diagnostics emission itself.
  void _safeLog(void Function(LoggingService logger) emit, String contextTag) {
    try {
      final logger = _ref.read(loggingServiceProvider);
      emit(logger);
    } on Object catch (loggerErr) {
      // ignore: avoid_print
      print('DeviceService[$contextTag]: logger emission failed: $loggerErr');
    }
  }

  /// Active equipment profile from [equipmentProfilesProvider] (host API or local DB).
  EquipmentProfileModel? get _activeProfile =>
      _ref.read(activeEquipmentProfileProvider);

  Future<void> _writeFilterNamesToBackend({
    required List<String> syncedNames,
  }) async {
    // Use the selected backend for both local and remote sessions. The former
    // NetworkBackend special case only changed this client's labels, leaving
    // the host driver (and every other client) unchanged while logging a
    // successful sync.
    await _setFilterWheelNames(syncedNames);
  }

  void _initEventListening() {
    _eventSubscription?.cancel();
    _eventSubscription = _backend.eventStream.listen(
      (event) {
        if (event.category == EventCategory.equipment) {
          _handleEquipmentEvent(event);
        } else if (event.category == EventCategory.sequencer) {
          _handleSequencerEvent(event);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _safeLog(
          (logger) => logger.error(
            'DeviceService equipment event stream error: $error',
            source: 'DeviceService',
          ),
          'event-stream-error',
        );
        if (!_disposed) {
          _initEventListening();
        }
      },
      cancelOnError: false,
    );
  }

  /// Wait until all guarded in-flight operations complete.
  Future<void> quiesce({Duration? timeout}) async {
    if (_inFlightOperations == 0) {
      return;
    }
    final completer = Completer<void>();
    _quiesceWaiters.add(completer);
    await completer.future.timeout(
      timeout ?? _quiesceTimeout,
      onTimeout: () {
        throw TimeoutException(
          'Device operations did not complete within '
          '${(timeout ?? _quiesceTimeout).inSeconds}s',
        );
      },
    );
  }

  /// Cancel reconnect timers, suppress auto-reconnect, and quiesce before a
  /// backend swap disposes this service instance.
  Future<void> prepareForBackendSwap() async {
    _reconnectCoordinator.prepareForBackendSwap();
    cancelWarmCamera();
    _temperaturePoller.stop();
    _environmentPollTimer?.cancel();
    _environmentPollTimer = null;
    if (_isAutofocusRunning) {
      await _cancelAutofocus();
    }
    if (_isFocuserBacklashCalibrationRunning) {
      await _cancelFocuserBacklashCalibration();
    }
    _focuserVerifyGeneration++;
    _rotatorVerifyGeneration++;
    _filterWheelVerifyGeneration++;
    _lastAppliedFilterOffsetByWheel.clear();
    await quiesce();
  }

  Future<T> _trackInFlight<T>(Future<T> Function() operation) async {
    _inFlightOperations++;
    try {
      return await operation();
    } finally {
      _inFlightOperations--;
      if (_inFlightOperations == 0) {
        final waiters = List<Completer<void>>.from(_quiesceWaiters);
        _quiesceWaiters.clear();
        for (final waiter in waiters) {
          if (!waiter.isCompleted) {
            waiter.complete();
          }
        }
      }
    }
  }

  void dispose() {
    _disposed = true;
    DeviceServiceLifecycle.unregister(this);
    _eventSubscription?.cancel();
    _environmentPollTimer?.cancel();
    _environmentPollTimer = null;
    _temperaturePoller.dispose();
    _warmupController.dispose();
    _reconnectCoordinator.cancelAll();
  }

  /// Discover available devices of a specific type
  ///
  /// Returns a list of [DeviceInfo] objects representing available devices.
  Future<List<DeviceInfo>> discoverDevices(DeviceType type) async {
    return await _backend.discoverDevices(type);
  }

  /// Discover INDI devices at a specific server address
  Future<List<DeviceInfo>> discoverIndiAtAddress(String host, int port) async {
    // Backend returns DeviceInfo directly
    return await _backend.discoverIndiAtAddress(host, port);
  }

  /// Discover Alpaca devices at a specific server address
  Future<List<DeviceInfo>> discoverAlpacaAtAddress(
    String host,
    int port,
  ) async {
    // Backend returns DeviceInfo directly
    return await _backend.discoverAlpacaAtAddress(host, port);
  }

  // Public device orchestration stays on DeviceService so existing callers,
  // mocks, and provider contracts keep the same surface.
  Future<void> connectCamera(String deviceId) => _connectCamera(deviceId);
  Future<CameraRecommendedSettings> queryRecommendedCameraSettings(
    String deviceId,
  ) => _queryRecommendedCameraSettings(deviceId);
  Future<bool> applyRecommendedCameraSettings(CameraRecommendedSettings rec) =>
      _applyRecommendedCameraSettings(rec);
  Future<void> setCameraCooling({required bool enabled, double? targetTemp}) =>
      _setCameraCooling(enabled: enabled, targetTemp: targetTemp);
  Future<void> warmCamera({double ratePerMin = 2.0}) =>
      _warmCamera(ratePerMin: ratePerMin);
  void cancelWarmCamera() => _cancelWarmCamera();
  Future<void> disconnectCamera() => _disconnectCamera();
  Future<void> connectMount(String deviceId) => _connectMount(deviceId);
  Future<void> disconnectMount() => _disconnectMount();
  Future<void> connectFocuser(String deviceId) => _connectFocuser(deviceId);
  Future<void> disconnectFocuser() => _disconnectFocuser();
  Future<void> connectFilterWheel(String deviceId) =>
      _connectFilterWheel(deviceId);
  Future<void> disconnectFilterWheel() => _disconnectFilterWheel();

  /// Connect a guider.
  ///
  /// [host]/[port] override the settings-derived PHD2 endpoint for THIS
  /// connect (the launch path still uses `settings.phd2Path`). When omitted
  /// the configured `settings.phd2Host`/`settings.phd2Port` are used, so all
  /// existing callers are unchanged. This lets the guiding controller's
  /// `connect(host, port)` API be truthful on the local/FFI path instead of
  /// silently discarding its arguments. Ignored for non-PHD2 guiders.
  Future<void> connectGuider(String deviceId, {String? host, int? port}) =>
      _connectGuider(deviceId, host: host, port: port);
  Future<void> disconnectGuider() => _disconnectGuider();

  /// Whether [deviceId]'s most recent disconnect was user-initiated (within
  /// the coordinator's debounce window). Exposed so external watchers —
  /// e.g. the PHD2 controller's crash-relaunch path — can distinguish a
  /// deliberate disconnect from a process/link loss.
  bool isUserInitiatedDisconnect(String deviceId) =>
      _reconnectCoordinator.isUserInitiatedDisconnect(deviceId);

  /// Record a user-initiated disconnect for [deviceId] and cancel any pending
  /// auto-reconnect for it. Exposed so a controller that tears a device down
  /// through its own path (the PHD2 controller's `disconnect()`) can mark the
  /// intent SYNCHRONOUSLY — before the Disconnected event races back — so the
  /// crash-relaunch path treats it as deliberate rather than a link loss.
  void markUserInitiatedDisconnect(String deviceId) =>
      _markUserInitiatedDisconnect(deviceId);

  Future<void> connectDome(String deviceId) => _connectDome(deviceId);
  Future<void> disconnectDome() => _disconnectDome();

  /// Re-read dome telemetry now and publish it to `domeStateProvider`.
  ///
  /// Called right after a dome command so the card's shutter / park / azimuth
  /// readouts reflect the command instead of holding the pre-command reading
  /// for up to one 5 s poll interval. Best-effort by design.
  Future<void> refreshDomeStatus() => _refreshDomeStatus();
  Future<void> connectWeather(String deviceId) => _connectWeather(deviceId);
  Future<void> disconnectWeather() => _disconnectWeather();
  Future<void> connectSafetyMonitor(String deviceId) =>
      _connectSafetyMonitor(deviceId);
  Future<void> disconnectSafetyMonitor() => _disconnectSafetyMonitor();
  Future<void> connectSwitch(String deviceId) => _connectSwitch(deviceId);
  Future<void> disconnectSwitch() => _disconnectSwitch();
  Future<void> refreshSwitchChannels() => _refreshSwitchChannels();
  Future<void> setSwitchChannel(int channelIndex, bool on) =>
      _setSwitchChannel(channelIndex, on);
  Future<void> setSwitchChannelValue(int channelIndex, double value) =>
      _setSwitchChannelValue(channelIndex, value);
  Future<void> connectRotator(String deviceId) => _connectRotator(deviceId);
  Future<void> disconnectRotator() => _disconnectRotator();
  Future<void> connectCoverCalibrator(String deviceId) =>
      _connectCoverCalibrator(deviceId);
  Future<void> disconnectCoverCalibrator() => _disconnectCoverCalibrator();

  Stream<DeviceConnectProgress> connectAllFromProfile(
    EquipmentProfileModel profile,
  ) => _connectAllFromProfile(profile);
  Future<void> disconnectAll() => _disconnectAll();

  Future<void> slewMountToCoordinates(double ra, double dec) =>
      _trackInFlight(() => _slewMountToCoordinates(ra, dec));
  Future<void> syncMountToCoordinates(double ra, double dec) =>
      _trackInFlight(() => _syncMountToCoordinates(ra, dec));
  Future<void> parkMount() => _trackInFlight(_parkMount);
  Future<void> unparkMount() => _trackInFlight(_unparkMount);
  Future<void> setMountTracking(bool enabled) =>
      _trackInFlight(() => _setMountTracking(enabled));
  Future<void> setMountTrackingRate(int rate) =>
      _trackInFlight(() => _setMountTrackingRate(rate));
  Future<void> abortMountSlew() => _trackInFlight(_abortMountSlew);
  Future<void> slewMountToAltAz(double altitude, double azimuth) =>
      _trackInFlight(() => _slewMountToAltAz(altitude, azimuth));
  Future<MountHomeOutcome> findMountHome() => _trackInFlight(_findMountHome);
  Future<void> pulseGuidMount({
    required String direction,
    required int durationMs,
  }) => _trackInFlight(
    () => _pulseGuidMount(direction: direction, durationMs: durationMs),
  );

  Future<void> moveFocuserTo(int position) =>
      _trackInFlight(() => _moveFocuserTo(position));
  Future<void> moveFocuserRelative(int delta) =>
      _trackInFlight(() => _moveFocuserRelative(delta));
  Future<void> haltFocuser() => _trackInFlight(_haltFocuser);
  Future<void> moveRotatorTo(double angle) =>
      _trackInFlight(() => _moveRotatorTo(angle));
  Future<void> moveRotatorRelative(double delta) =>
      _trackInFlight(() => _moveRotatorRelative(delta));
  Future<void> haltRotator() => _trackInFlight(_haltRotator);
  Future<void> setRotatorReversed(bool reversed) =>
      _trackInFlight(() => _setRotatorReversed(reversed));
  Future<void> syncRotatorToPa(double positionAngle) =>
      _trackInFlight(() => _syncRotatorToPa(positionAngle));
  Future<AutofocusResult> runAutofocus({
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    String method = 'VCurve',
    int binning = 1,
    bool useSettingsDefaults = true,
  }) => _trackInFlight(
    () => _runAutofocus(
      exposureTime: exposureTime,
      stepSize: stepSize,
      stepsOut: stepsOut,
      method: method,
      binning: binning,
      useSettingsDefaults: useSettingsDefaults,
    ),
  );
  Future<void> cancelAutofocus() => _trackInFlight(_cancelAutofocus);

  /// Measure the connected focuser's backlash. A refusal comes back in the
  /// result; an exception means the run could not happen at all.
  Future<FocuserBacklashResult> calibrateFocuserBacklash({
    int? centerPosition,
  }) => _trackInFlight(
    () => _calibrateFocuserBacklash(centerPosition: centerPosition),
  );

  Future<void> cancelFocuserBacklashCalibration() =>
      _trackInFlight(_cancelFocuserBacklashCalibration);

  /// What a calibration run would cost, before agreeing to it.
  Future<FocuserBacklashCalibrationPlan> planFocuserBacklashCalibration({
    int? centerPosition,
  }) => _trackInFlight(
    () => _planFocuserBacklashCalibration(centerPosition: centerPosition),
  );
  Future<void> setFilterWheelPosition(int position) =>
      _trackInFlight(() => _setFilterWheelPosition(position));
  Future<void> setFilterWheelNames(List<String> names) =>
      _trackInFlight(() => _setFilterWheelNames(names));

  Future<void> startGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) => _startGuiding(
    settlePixels: settlePixels,
    settleTime: settleTime,
    settleTimeout: settleTimeout,
  );
  Future<void> stopGuiding() => _stopGuiding();
  Future<void> dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) => _dither(
    amount: amount,
    raOnly: raOnly,
    settlePixels: settlePixels,
    settleTime: settleTime,
    settleTimeout: settleTimeout,
  );
  Future<void> startSequence() => _startSequence();
  Future<void> stopSequence() => _stopSequence();
  Future<void> pauseSequence() => _pauseSequence();
  Future<void> resumeSequence() => _resumeSequence();
  Future<void> loadSequence(String json) => _loadSequence(json);
  Future<SequencerStatus> getSequencerStatus() => _getSequencerStatus();
}

/// Provider for the device service
final deviceServiceProvider = Provider<DeviceService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = DeviceService(ref, backend);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for available cameras
final availableCamerasProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.camera);
});

/// Provider for available mounts
final availableMountsProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.mount);
});

/// Provider for available focusers
final availableFocusersProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.focuser);
});

/// Provider for available filter wheels
final availableFilterWheelsProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref
      .watch(deviceServiceProvider)
      .discoverDevices(DeviceType.filterWheel);
});

/// Provider for available guiders
final availableGuidersProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.guider);
});

/// Provider for available rotators
final availableRotatorsProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.rotator);
});

/// Provider for available domes
final availableDomesProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.dome);
});

/// Provider for available weather devices
final availableWeatherProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.weather);
});

/// Provider for available safety monitors
final availableSafetyMonitorsProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref
      .watch(deviceServiceProvider)
      .discoverDevices(DeviceType.safetyMonitor);
});

/// Provider for available switch devices.
final availableSwitchesProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.switch_);
});

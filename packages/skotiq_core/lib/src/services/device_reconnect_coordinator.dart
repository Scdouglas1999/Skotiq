import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart';
import '../models/sequence/sequence_models.dart';
import '../providers/equipment_provider.dart';
import '../providers/profiles_provider.dart';
import '../providers/sequence_provider.dart';
import '../providers/ui_notification_provider.dart';
import 'device_service.dart' show DeviceTypeDisplayExtension;
import 'logging_service.dart';
import 'notification_service.dart';

/// Coordinates the device auto-reconnect lifecycle.
///
/// Owns:
///   * the per-device attempt counter and exponential-backoff timer map,
///   * the user-initiated-disconnect debounce so manual disconnects do
///     not immediately trigger an auto-reconnect,
///   * suppress-during-backend-swap state,
///   * the post-reconnect "should I resume a paused sequence?" check.
///
/// Separate from `DeviceService` so the reconnect state machine is not inlined
/// alongside the connect/disconnect command layer. DeviceService drives this
/// coordinator from its device-event handlers; the coordinator never reaches
/// back into DeviceService's internals — sequencer pause/resume is the one
/// place a callback is required and is injected explicitly.
class DeviceReconnectCoordinator {
  DeviceReconnectCoordinator({
    required Ref ref,
    required SkotiqBackend backend,
    required Future<void> Function() resumeSequence,
    required Future<void> Function() pauseSequence,
    required void Function(String deviceId, {int attempt, int maxAttempts})
    surfaceReconnecting,
    List<Duration>? retryDelays,
    Future<void> Function(DeviceType type, String deviceId)? reconnectAttempt,
  }) : assert(retryDelays == null || retryDelays.isNotEmpty),
       _ref = ref,
       _backend = backend,
       _resumeSequence = resumeSequence,
       _pauseSequence = pauseSequence,
       _surfaceReconnecting = surfaceReconnecting,
       _retryDelays = retryDelays ?? reconnectDelays,
       _reconnectAttemptOverride = reconnectAttempt;

  final Ref _ref;
  final SkotiqBackend _backend;
  final Future<void> Function() _resumeSequence;
  final Future<void> Function() _pauseSequence;
  final List<Duration> _retryDelays;
  final Future<void> Function(DeviceType type, String deviceId)?
  _reconnectAttemptOverride;

  /// Drive the per-device heartbeat-health indicator into the
  /// "reconnecting" state. Injected (rather than reaching into the
  /// heartbeat router directly) so the coordinator stays free of any
  /// provider/router coupling — it owns the reconnect *decision*, the
  /// router owns the health *surface*. See
  /// `DeviceHeartbeatRouter.surfaceReconnecting`.
  final void Function(String deviceId, {int attempt, int maxAttempts})
  _surfaceReconnecting;

  /// Maximum number of reconnection attempts before surfacing the
  /// "couldn't reconnect" UI notification and giving up.
  static const int maxReconnectAttempts = 3;

  /// Reconnection delay backoff (5, 10, 20 seconds).
  static const List<Duration> reconnectDelays = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
  ];

  /// How long after a user-initiated disconnect we ignore Disconnected
  /// events for that device id (so the connection-down event the user
  /// just triggered does not bounce back as a reconnect).
  static const Duration userDisconnectSuppressDuration = Duration(seconds: 10);

  final Map<String, int> _reconnectionAttempts = {};
  final Map<String, Timer> _reconnectionTimers = {};
  final Set<String> _reconnectionsInFlight = {};
  final Set<String> _reconnectExhausted = {};
  int _reconnectGeneration = 0;

  /// User-initiated disconnects suppress auto-reconnect briefly.
  final Set<String> _userInitiatedDisconnects = {};
  Timer? _userDisconnectDebounceTimer;

  /// Set during backend swap so stray Disconnected events cannot
  /// reconnect against a backend that is mid-tear-down.
  bool _suppressAutoReconnect = false;

  /// Whether the NATIVE Rust reconnection engine owns reconnect for
  /// [type], i.e. its per-device-type heartbeat config has
  /// `auto_reconnect = true`.
  ///
  /// This mirrors the native source of truth exactly: the path Dart
  /// triggers when it starts a heartbeat is
  /// `DeviceManager::start_heartbeat` →
  /// `Self::get_heartbeat_config(device_type)` (see
  /// `native/.../device_manager/heartbeat.rs`), which returns the
  /// per-type `HeartbeatConfig::for_*()` policy from
  /// `device_manager/mod.rs`. That config's `auto_reconnect` flag is
  /// later read by the native `reconnection_loop` (it reconnects any
  /// device left in `ConnectionState::Error` with `auto_reconnect`
  /// set), so for those types the native loop performs the real
  /// reconnect on its own — emitting `Connecting` then `Connected`.
  ///
  /// Why the policy is mirrored here instead of queried over FFI: the
  /// plain `startDeviceHeartbeat` FFI surface the Dart side actually
  /// uses does not let the caller tune the escalation policy — it always
  /// inherits these compiled per-type defaults — so the mapping is
  /// stable and authoritative. Encoding it here keeps the de-duplication
  /// decision inside the one file that owns reconnect ownership, with no
  /// new FFI round-trip on the hot disconnect path.
  ///
  /// DE-DUPLICATION (DEV-P1 dual-reconnect race): when this returns true
  /// the Dart coordinator must NOT schedule its own reconnect — doing so
  /// raced the native loop and double-connected / thrashed the same
  /// physical device after a heartbeat-driven loss. The two engines now
  /// have exactly one owner per device type. Sequence-resume after a
  /// native-driven reconnect is still handled, off the authoritative
  /// `Connected` event, by [onAuthoritativeDeviceConnected].
  static bool nativeOwnsReconnect(DeviceType type) {
    switch (type) {
      // HeartbeatConfig::for_mount / for_dome / for_weather /
      // for_safety_monitor / for_guider / for_cover_calibrator all set
      // auto_reconnect = true.
      case DeviceType.mount:
      case DeviceType.dome:
      case DeviceType.weather:
      case DeviceType.safetyMonitor:
      case DeviceType.guider:
      case DeviceType.coverCalibrator:
        return true;
      // HeartbeatConfig::for_camera / for_focuser / for_filter_wheel /
      // for_rotator / for_switch all set auto_reconnect = false, so the
      // native loop ignores them and the Dart coordinator is the sole
      // reconnect engine.
      case DeviceType.camera:
      case DeviceType.focuser:
      case DeviceType.filterWheel:
      case DeviceType.rotator:
      case DeviceType.switch_:
        return false;
    }
  }

  String _reconnectKey(DeviceType type, String deviceId) =>
      '${type.name}:$deviceId';

  /// Mark [deviceId] as a user-initiated disconnect: cancel any pending
  /// reconnect for that device, drop the attempt counter, and arm the
  /// debounce timer so any Disconnected event arriving in the next 10s
  /// is treated as expected.
  void markUserInitiatedDisconnect(String deviceId) {
    if (deviceId.isEmpty) {
      return;
    }
    _userInitiatedDisconnects.add(deviceId);
    final reconnectKeys = _reconnectionTimers.keys
        .followedBy(_reconnectionAttempts.keys)
        .followedBy(_reconnectionsInFlight)
        .followedBy(_reconnectExhausted)
        .where((key) => key.endsWith(':$deviceId'))
        .toSet();
    for (final key in reconnectKeys) {
      _reconnectionTimers[key]?.cancel();
      _reconnectionTimers.remove(key);
      _reconnectionAttempts.remove(key);
      _reconnectionsInFlight.remove(key);
      _reconnectExhausted.remove(key);
    }
    _userDisconnectDebounceTimer?.cancel();
    _userDisconnectDebounceTimer = Timer(userDisconnectSuppressDuration, () {
      _userInitiatedDisconnects.clear();
      _userDisconnectDebounceTimer = null;
    });
  }

  bool isUserInitiatedDisconnect(String deviceId) {
    return _userInitiatedDisconnects.contains(deviceId);
  }

  /// A disconnect command failed before the backend acknowledged teardown.
  /// Remove the temporary suppression so the still-connected device is not
  /// stranded without reconnect handling for the debounce window.
  void clearUserInitiatedDisconnect(String deviceId) {
    _userInitiatedDisconnects.remove(deviceId);
    if (_userInitiatedDisconnects.isEmpty) {
      _userDisconnectDebounceTimer?.cancel();
      _userDisconnectDebounceTimer = null;
    }
  }

  /// Cancel every pending reconnect timer and zero the counters. Used
  /// during backend swap and from `DeviceService.dispose`.
  void cancelAll() {
    _reconnectGeneration++;
    for (final timer in _reconnectionTimers.values) {
      timer.cancel();
    }
    _reconnectionTimers.clear();
    _reconnectionAttempts.clear();
    _reconnectionsInFlight.clear();
    _reconnectExhausted.clear();
  }

  /// Wind down before a backend swap: cancel timers, clear debounce
  /// state, and lock out future reconnect attempts until [reset] is
  /// called.
  void prepareForBackendSwap() {
    _suppressAutoReconnect = true;
    cancelAll();
    _userInitiatedDisconnects.clear();
    _userDisconnectDebounceTimer?.cancel();
    _userDisconnectDebounceTimer = null;
  }

  /// Re-enable auto-reconnect after a swap. Not currently called (the
  /// post-swap `DeviceService` instance constructs a fresh coordinator)
  /// but kept symmetrical with [prepareForBackendSwap] for future use.
  void reset() {
    _suppressAutoReconnect = false;
  }

  /// Schedule a reconnection attempt for [type]/[deviceId] subject to:
  ///   * suppress-during-swap,
  ///   * user-initiated-disconnect debounce,
  ///   * per-type `autoReconnectEnabled` flag,
  ///   * `maxReconnectAttempts` cap (notifies the user and gives up).
  Future<void> attemptReconnect(DeviceType type, String deviceId) async {
    if (_suppressAutoReconnect) {
      return;
    }

    if (isUserInitiatedDisconnect(deviceId)) {
      _safeLog(
        (logger) => logger.info(
          'Skipping auto-reconnect for user-initiated disconnect of '
          '${type.displayName} ($deviceId)',
          source: 'DeviceReconnectCoordinator',
        ),
      );
      return;
    }

    // DEV-P1 dual-reconnect de-duplication: if the native Rust
    // reconnection engine owns reconnect for this device type, defer to
    // it. Both engines firing against the same physical device after a
    // heartbeat-driven loss double-connected and thrashed the driver.
    // The native loop will reconnect (emitting Connecting/Connected) and
    // keep retrying for minutes; our [onAuthoritativeDeviceConnected]
    // hook (driven off the live Connected event) still resumes a paused
    // sequence once the device is back, and per-attempt failures still
    // surface to the user via the native `Error` events. We only need to
    // (a) NOT schedule a competing Dart reconnect, and (b) surface the
    // "reconnecting" indicator the native side never emits an event for.
    if (nativeOwnsReconnect(type)) {
      _surfaceReconnecting(deviceId);
      _safeLog(
        (logger) => logger.info(
          'Deferring reconnect of ${type.displayName} ($deviceId) to the '
          'native auto-reconnect engine (single-owner policy); Dart '
          'coordinator will not schedule a competing attempt.',
          source: 'DeviceReconnectCoordinator',
        ),
      );
      return;
    }

    final autoReconnectEnabled = _getAutoReconnectFor(type);

    if (!autoReconnectEnabled) {
      _safeLog(
        (logger) => logger.info(
          'Auto-reconnect disabled for ${type.displayName} ($deviceId)',
          source: 'DeviceReconnectCoordinator',
        ),
      );
      return;
    }

    final reconnectKey = _reconnectKey(type, deviceId);

    // A Disconnected event can be emitted as cleanup by the very connect
    // attempt that is already running. Coalesce those events with the
    // coordinator-owned retry path: without these guards, each cleanup event
    // schedules a second timer and, after the third failure, starts a fresh
    // 1/3..3/3 batch forever.
    if (_reconnectionTimers.containsKey(reconnectKey) ||
        _reconnectionsInFlight.contains(reconnectKey) ||
        _reconnectExhausted.contains(reconnectKey)) {
      return;
    }

    final attemptCount = _reconnectionAttempts[reconnectKey] ?? 0;

    if (attemptCount >= maxReconnectAttempts) {
      _markReconnectExhausted(type, deviceId, reconnectKey);
      return;
    }

    _reconnectionAttempts[reconnectKey] = attemptCount + 1;

    // Surface the "reconnecting" indicator for this Dart-owned device the
    // moment an attempt is committed to, so the card reads "Reconnecting…"
    // through the backoff window instead of falling back to gray "unknown".
    // Nothing else covers it: the native HeartbeatReconnecting event is never
    // emitted for these devices.
    _surfaceReconnecting(
      deviceId,
      attempt: attemptCount + 1,
      maxAttempts: maxReconnectAttempts,
    );

    final delay = attemptCount < _retryDelays.length
        ? _retryDelays[attemptCount]
        : _retryDelays.last;
    final generation = _reconnectGeneration;

    _safeLog(
      (logger) => logger.info(
        'Scheduling reconnection attempt ${attemptCount + 1}/'
        '$maxReconnectAttempts for ${type.displayName} ($deviceId) '
        'in ${delay.inSeconds}s at '
        '${DateTime.now().add(delay).toIso8601String()}',
        source: 'DeviceReconnectCoordinator',
      ),
    );

    _reconnectionTimers[reconnectKey] = Timer(delay, () async {
      _reconnectionTimers.remove(reconnectKey);
      if (generation != _reconnectGeneration ||
          _suppressAutoReconnect ||
          isUserInitiatedDisconnect(deviceId)) {
        return;
      }

      _reconnectionsInFlight.add(reconnectKey);
      Object? reconnectFailure;
      try {
        _safeLog(
          (logger) => logger.info(
            'Attempting reconnection ${attemptCount + 1}/'
            '$maxReconnectAttempts for ${type.displayName} ($deviceId) at '
            '${DateTime.now().toIso8601String()}',
            source: 'DeviceReconnectCoordinator',
          ),
        );

        final reconnectAttempt = _reconnectAttemptOverride;
        if (reconnectAttempt == null) {
          await _performReconnection(type, deviceId);
        } else {
          await reconnectAttempt(type, deviceId);
        }

        _reconnectionAttempts.remove(reconnectKey);
        _reconnectExhausted.remove(reconnectKey);

        _safeLog(
          (logger) => logger.info(
            'Successfully reconnected ${type.displayName} ($deviceId) at '
            '${DateTime.now().toIso8601String()}',
            source: 'DeviceReconnectCoordinator',
          ),
        );

        _showReconnectionSuccessNotification(type, deviceId);

        await _considerSequenceResume(type);
      } catch (e) {
        reconnectFailure = e;
        _safeLog(
          (logger) => logger.warning(
            'Reconnection attempt ${attemptCount + 1}/'
            '$maxReconnectAttempts failed for ${type.displayName} '
            '($deviceId): $e',
            source: 'DeviceReconnectCoordinator',
          ),
        );
      } finally {
        _reconnectionsInFlight.remove(reconnectKey);
      }

      if (reconnectFailure != null && generation == _reconnectGeneration) {
        final completedAttempts = _reconnectionAttempts[reconnectKey] ?? 0;
        if (completedAttempts >= maxReconnectAttempts) {
          _markReconnectExhausted(type, deviceId, reconnectKey);
        } else {
          unawaited(attemptReconnect(type, deviceId));
        }
      }
    });
  }

  void _markReconnectExhausted(
    DeviceType type,
    String deviceId,
    String reconnectKey,
  ) {
    // Multiple late Disconnected/Error events may all observe the terminal
    // state. Notify once, then retain the exhausted marker until a real
    // Connected event or an explicit user disconnect resets the lifecycle.
    if (!_reconnectExhausted.add(reconnectKey)) {
      return;
    }
    _safeLog(
      (logger) => logger.error(
        'Failed to reconnect ${type.displayName} ($deviceId) after '
        '$maxReconnectAttempts attempts; automatic retries are exhausted',
        source: 'DeviceReconnectCoordinator',
      ),
    );
    _showReconnectionFailedNotification(type, deviceId);
  }

  /// Handle disconnection of critical devices (camera, mount) during
  /// sequence execution: snapshot a fresh checkpoint and pause the run.
  /// The reconnect path will resume automatically via
  /// [_considerSequenceResume] once both critical devices are back.
  Future<void> handleCriticalDeviceDisconnect(
    String deviceType,
    String deviceId,
  ) async {
    final sequenceState = _ref.read(sequenceExecutionStateProvider);
    if (sequenceState != SequenceExecutionState.running &&
        sequenceState != SequenceExecutionState.paused) {
      return;
    }

    try {
      await _backend.saveCheckpoint();
    } catch (e) {
      _safeLog(
        (logger) => logger.error(
          'Failed to save checkpoint after critical $deviceType disconnect '
          '($deviceId): $e',
          source: 'DeviceReconnectCoordinator',
        ),
      );
      try {
        _ref
            .read(uiNotificationProvider.notifier)
            .showError(
              'Failed to save a sequence checkpoint after $deviceType '
              'disconnected.',
              title: 'Checkpoint Failed',
              duration: const Duration(seconds: 12),
            );
      } on Object {
        // Notification failure must not mask the hardware-protection pause.
      }
    }

    if (sequenceState == SequenceExecutionState.paused) {
      return;
    }

    try {
      await _pauseSequence();
    } catch (e) {
      _safeLog(
        (logger) => logger.warning(
          'Failed to pause sequence after critical $deviceType disconnect '
          '($deviceId): $e',
          source: 'DeviceReconnectCoordinator',
        ),
      );
    }
  }

  bool _getAutoReconnectFor(DeviceType type) {
    return switch (type) {
      DeviceType.camera => _ref.read(cameraStateProvider).autoReconnectEnabled,
      DeviceType.mount => _ref.read(mountStateProvider).autoReconnectEnabled,
      DeviceType.focuser =>
        _ref.read(focuserStateProvider).autoReconnectEnabled,
      DeviceType.filterWheel =>
        _ref.read(filterWheelStateProvider).autoReconnectEnabled,
      DeviceType.guider => _ref.read(guiderStateProvider).autoReconnectEnabled,
      DeviceType.rotator =>
        _ref.read(rotatorStateProvider).autoReconnectEnabled,
      DeviceType.dome => _ref.read(domeStateProvider).autoReconnectEnabled,
      DeviceType.weather =>
        _ref.read(weatherStateProvider).autoReconnectEnabled,
      DeviceType.safetyMonitor =>
        _ref.read(safetyMonitorStateProvider).autoReconnectEnabled,
      DeviceType.coverCalibrator =>
        _ref.read(coverCalibratorStateProvider).autoReconnectEnabled,
      DeviceType.switch_ => _ref.read(switchStateProvider).autoReconnectEnabled,
    };
  }

  Future<void> _performReconnection(DeviceType type, String deviceId) async {
    switch (type) {
      case DeviceType.camera:
        await _ref
            .read(cameraStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.mount:
        await _ref
            .read(mountStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.focuser:
        await _ref
            .read(focuserStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.filterWheel:
        await _ref
            .read(filterWheelStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.guider:
        await _ref
            .read(guiderStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.rotator:
        await _ref
            .read(rotatorStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.dome:
        await _ref
            .read(domeStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.weather:
        await _ref
            .read(weatherStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.safetyMonitor:
        await _ref
            .read(safetyMonitorStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.switch_:
        await _ref
            .read(switchStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
      case DeviceType.coverCalibrator:
        await _ref
            .read(coverCalibratorStateProvider.notifier)
            .connect(deviceId, maxRetries: 1);
        break;
    }

    final outcome = switch (type) {
      DeviceType.camera => (
        _ref.read(cameraStateProvider).connectionState,
        _ref.read(cameraStateProvider).lastError,
      ),
      DeviceType.mount => (
        _ref.read(mountStateProvider).connectionState,
        _ref.read(mountStateProvider).lastError,
      ),
      DeviceType.focuser => (
        _ref.read(focuserStateProvider).connectionState,
        _ref.read(focuserStateProvider).lastError,
      ),
      DeviceType.filterWheel => (
        _ref.read(filterWheelStateProvider).connectionState,
        _ref.read(filterWheelStateProvider).lastError,
      ),
      DeviceType.guider => (
        _ref.read(guiderStateProvider).connectionState,
        _ref.read(guiderStateProvider).lastError,
      ),
      DeviceType.rotator => (
        _ref.read(rotatorStateProvider).connectionState,
        _ref.read(rotatorStateProvider).lastError,
      ),
      DeviceType.dome => (
        _ref.read(domeStateProvider).connectionState,
        _ref.read(domeStateProvider).lastError,
      ),
      DeviceType.weather => (
        _ref.read(weatherStateProvider).connectionState,
        _ref.read(weatherStateProvider).lastError,
      ),
      DeviceType.safetyMonitor => (
        _ref.read(safetyMonitorStateProvider).connectionState,
        _ref.read(safetyMonitorStateProvider).lastError,
      ),
      DeviceType.switch_ => (
        _ref.read(switchStateProvider).connectionState,
        _ref.read(switchStateProvider).lastError,
      ),
      DeviceType.coverCalibrator => (
        _ref.read(coverCalibratorStateProvider).connectionState,
        _ref.read(coverCalibratorStateProvider).lastError,
      ),
    };
    validateReconnectOutcome(
      type: type,
      connectionState: outcome.$1,
      lastError: outcome.$2,
    );
  }

  /// State notifiers deliberately retain terminal connection failures in
  /// `lastError` instead of rethrowing them, so awaiting `connect()` alone does
  /// not prove that reconnection succeeded. Keep the coordinator's retry
  /// counter honest by requiring the authoritative post-attempt state.
  static void validateReconnectOutcome({
    required DeviceType type,
    required DeviceConnectionState connectionState,
    Object? lastError,
  }) {
    if (connectionState == DeviceConnectionState.connected) {
      return;
    }
    throw StateError(
      '${type.displayName} reconnect finished in '
      '${connectionState.name} state'
      '${lastError == null ? '' : ': $lastError'}',
    );
  }

  /// After a successful reconnect, resume a paused sequence if and only
  /// if every critical device listed in the active profile is back.
  Future<void> _considerSequenceResume(DeviceType type) async {
    if (type != DeviceType.camera && type != DeviceType.mount) {
      return;
    }

    final sequenceState = _ref.read(sequenceExecutionStateProvider);
    if (sequenceState != SequenceExecutionState.paused) {
      return;
    }

    final activeProfile = _ref.read(activeEquipmentProfileProvider);
    if (activeProfile == null) {
      return;
    }

    bool allCriticalDevicesConnected = true;

    if (activeProfile.cameraId != null && activeProfile.cameraId!.isNotEmpty) {
      final cameraState = _ref.read(cameraStateProvider);
      if (cameraState.connectionState != DeviceConnectionState.connected) {
        allCriticalDevicesConnected = false;
      }
    }

    if (activeProfile.mountId != null && activeProfile.mountId!.isNotEmpty) {
      final mountState = _ref.read(mountStateProvider);
      if (mountState.connectionState != DeviceConnectionState.connected) {
        allCriticalDevicesConnected = false;
      }
    }

    if (allCriticalDevicesConnected) {
      try {
        await _resumeSequence();
      } catch (e) {
        _safeLog(
          (logger) => logger.warning(
            'Failed to resume sequence after reconnecting ${type.displayName}: '
            '$e',
            source: 'DeviceReconnectCoordinator',
          ),
        );
      }
    }
  }

  /// Resume a paused sequence after an AUTHORITATIVE device-connected event,
  /// regardless of which actor reconnected the device.
  ///
  /// The Dart coordinator exhausts its own retry budget in ~35s, but the Rust
  /// reconnection loop keeps retrying for minutes. Without this hook, a
  /// reconnect driven by the Rust loop (after the Dart side already gave up)
  /// would reconnect the device yet leave the sequence paused — the operator
  /// wakes to a rig that is "connected but idle". Wiring this to the live
  /// connected event closes that gap. Safe to call for any device type: only
  /// camera/mount drive a resume, and resume only fires once ALL critical
  /// devices are back (see [_considerSequenceResume]).
  Future<void> onAuthoritativeDeviceConnected(
    String deviceType,
    String deviceId,
  ) async {
    final reconnectKeys = _reconnectionTimers.keys
        .followedBy(_reconnectionAttempts.keys)
        .followedBy(_reconnectExhausted)
        .where((key) => key.endsWith(':$deviceId'))
        .toSet();
    for (final key in reconnectKeys) {
      _reconnectionTimers.remove(key)?.cancel();
      _reconnectionAttempts.remove(key);
      _reconnectExhausted.remove(key);
    }

    final lower = deviceType.toLowerCase();
    final DeviceType type;
    if (lower == 'camera') {
      type = DeviceType.camera;
    } else if (lower == 'mount') {
      type = DeviceType.mount;
    } else {
      return;
    }
    await _considerSequenceResume(type);
  }

  void _showReconnectionFailedNotification(DeviceType type, String deviceId) {
    try {
      _ref
          .read(uiNotificationProvider.notifier)
          .showError(
            'Failed to reconnect ${type.displayName} after '
            '$maxReconnectAttempts attempts.\n\n'
            'Troubleshooting steps:\n'
            '• Check device power and USB/network connections\n'
            '• Verify device drivers are installed and up to date\n'
            '• Try unplugging and reconnecting the device\n'
            '• Restart the device software (ASCOM/INDI/etc.)\n'
            '• Check for device error messages or logs\n\n'
            'Please fix the issue and reconnect manually.',
            title: '${type.displayName} Reconnection Failed',
            duration: const Duration(seconds: 15),
          );
    } on Object catch (e) {
      _safeLog(
        (logger) => logger.warning(
          'UI notification for reconnect-failed dropped: $e',
          source: 'DeviceReconnectCoordinator',
        ),
      );
    }

    try {
      _ref
          .read(notificationServiceProvider)
          .notifyError(
            errorTitle: 'Device Reconnection Failed',
            errorMessage:
                '${type.displayName} ($deviceId) could not be '
                'reconnected after $maxReconnectAttempts attempts.\n\n'
                'Auto-reconnection has stopped. Manual intervention required.\n'
                'Check device power, connections, and drivers.',
            source: 'Device Monitor',
          );
    } on Object catch (e) {
      _safeLog(
        (logger) => logger.warning(
          'External notification for reconnect-failed dropped: $e',
          source: 'DeviceReconnectCoordinator',
        ),
      );
    }
  }

  void _showReconnectionSuccessNotification(DeviceType type, String deviceId) {
    try {
      _ref
          .read(uiNotificationProvider.notifier)
          .showSuccess(
            '${type.displayName} has been reconnected successfully.',
            title: 'Device Reconnected',
            duration: const Duration(seconds: 5),
          );
    } on Object catch (e) {
      _safeLog(
        (logger) => logger.warning(
          'UI notification for reconnect-success dropped: $e',
          source: 'DeviceReconnectCoordinator',
        ),
      );
    }

    if (type == DeviceType.camera || type == DeviceType.mount) {
      try {
        _ref
            .read(notificationServiceProvider)
            .notifyCustom(
              title: 'Device Reconnected',
              message:
                  '${type.displayName} ($deviceId) has been reconnected '
                  'successfully and is back online.',
              priority: NotificationPriority.normal,
            );
      } on Object catch (e) {
        _safeLog(
          (logger) => logger.warning(
            'External notification for reconnect-success dropped: $e',
            source: 'DeviceReconnectCoordinator',
          ),
        );
      }
    }
  }

  void _safeLog(void Function(LoggingService logger) emit) {
    try {
      final logger = _ref.read(loggingServiceProvider);
      emit(logger);
    } on Object {
      // Logger may be unavailable mid-disposal. Diagnostic-only failure;
      // do not propagate up the reconnect path.
    }
  }
}

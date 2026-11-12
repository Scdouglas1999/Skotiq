import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart';
import '../models/sequence/sequence_models.dart';
import '../providers/equipment_provider.dart';
import '../providers/profiles_provider.dart';
import '../providers/sequence_provider.dart';
import '../providers/ui_notification_provider.dart';
import 'logging_service.dart';
import 'notification_service.dart';
import '../backend/remote_host.dart';
import '../models/backend/backend_types.dart';

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
    required Future<void> Function(DeviceType type, String deviceId) connect,
    List<Duration>? retryDelays,
    Future<void> Function(DeviceType type, String deviceId)? reconnectAttempt,
    Future<String> Function(DeviceType type, String deviceId)? reconnectTarget,
  }) : assert(retryDelays == null || retryDelays.isNotEmpty),
       _ref = ref,
       _backend = backend,
       _resumeSequence = resumeSequence,
       _pauseSequence = pauseSequence,
       _surfaceReconnecting = surfaceReconnecting,
       _connect = connect,
       _retryDelays = retryDelays ?? reconnectDelays,
       _reconnectAttemptOverride = reconnectAttempt,
       _reconnectTarget = reconnectTarget;

  final Ref _ref;
  final SkotiqBackend _backend;

  /// On a companion the device events are the imaging host's, relayed. The
  /// host already reconnects, checkpoints and pauses for its own devices, so
  /// the companion must never send its own reconnect, checkpoint or pause.
  bool get _hostOwnsRecovery => _backend.remoteHost != null;
  final Future<void> Function() _resumeSequence;
  final Future<void> Function() _pauseSequence;

  /// The device service's connect: the one writer of a slot during a
  /// connect. It throws when the connect fails.
  final Future<void> Function(DeviceType type, String deviceId) _connect;
  final List<Duration> _retryDelays;
  final Future<void> Function(DeviceType type, String deviceId)?
  _reconnectAttemptOverride;

  /// Where a reconnect of a device last at an id has to go. Profile devices
  /// on a USB bus are found by the name the profile saved: after the bus
  /// enumerates in another order (a hub dropout), the camera last at
  /// `native:zwo:1` can be at `native:zwo:0`. Throws when the device cannot
  /// be found safely, which counts as a failed attempt.
  final Future<String> Function(DeviceType type, String deviceId)?
  _reconnectTarget;

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

  /// Whether the native heartbeat reconnects [type] itself. When it does,
  /// this coordinator must not schedule a reconnect of its own: the two raced
  /// and double-connected the same device. Resuming the sequence after a
  /// native reconnect is handled by [onAuthoritativeDeviceConnected].
  bool nativeOwnsReconnect(DeviceType type) =>
      _backend.nativeReconnectedDeviceTypes.contains(type);

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
    if (_suppressAutoReconnect || _hostOwnsRecovery) {
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

        final resolveTarget = _reconnectTarget;
        final target = resolveTarget == null
            ? deviceId
            : await resolveTarget(type, deviceId);
        if (target != deviceId) {
          _safeLog(
            (logger) => logger.warning(
              '${type.displayName} last at $deviceId is now at $target; '
              'reconnecting it there',
              source: 'DeviceReconnectCoordinator',
            ),
          );
        }

        final reconnectAttempt = _reconnectAttemptOverride;
        if (reconnectAttempt == null) {
          await _performReconnection(type, target);
        } else {
          await reconnectAttempt(type, target);
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

  /// A device of [type] came onto the bus. Each device of that type whose
  /// automatic reconnects ran out gets a fresh round: a hub that takes
  /// minutes to power back up outlasts the three quick attempts, and the
  /// device then stayed in error all night.
  void onDeviceArrived(DeviceType type) {
    if (_suppressAutoReconnect || _hostOwnsRecovery) return;
    final prefix = '${type.name}:';
    final exhausted = _reconnectExhausted
        .where((key) => key.startsWith(prefix))
        .toList();
    for (final key in exhausted) {
      _reconnectExhausted.remove(key);
      _reconnectionAttempts.remove(key);
      final deviceId = key.substring(prefix.length);
      _safeLog(
        (logger) => logger.info(
          'A ${type.displayName} came onto the bus; trying $deviceId again',
          source: 'DeviceReconnectCoordinator',
        ),
      );
      unawaited(attemptReconnect(type, deviceId));
    }
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
    if (_hostOwnsRecovery) return;
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

  bool _getAutoReconnectFor(DeviceType type) =>
      readDeviceSlot(_ref, type).autoReconnectEnabled;

  Future<void> _performReconnection(DeviceType type, String deviceId) async {
    await _connect(type, deviceId);
    final slot = readDeviceSlot(_ref, type);
    validateReconnectOutcome(
      type: type,
      connectionState: slot.connectionState,
      lastError: slot.lastError,
    );
  }

  /// A connect that returns has not proved the device is back: the slot can
  /// have been taken by another connect meanwhile. Keep the coordinator's
  /// retry counter honest by requiring the authoritative post-attempt state.
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
    // The driver reports Connected as soon as it opens, before the app has
    // brought the device up. During one of this coordinator's own attempts
    // that is not yet a recovery: the attempt's outcome decides, and its
    // count must survive a bring-up that then fails.
    final reconnectKeys = _reconnectionTimers.keys
        .followedBy(_reconnectionAttempts.keys)
        .followedBy(_reconnectExhausted)
        .where(
          (key) =>
              key.endsWith(':$deviceId') &&
              !_reconnectionsInFlight.contains(key),
        )
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
            .notify(
              event: NotificationEvent.custom,
              title: 'Device Reconnected',
              message:
                  '${type.displayName} ($deviceId) has been reconnected '
                  'successfully and is back online.',
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

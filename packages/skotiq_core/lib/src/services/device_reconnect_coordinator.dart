import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart';
import '../models/sequence/sequence_models.dart';
import '../providers/equipment_provider.dart';
import '../providers/profiles_provider.dart';
import '../providers/sequence_provider.dart';
import '../models/notification/notification_categories.dart'
    show NotificationCategory;
import 'notification/notification_router.dart' show NotificationRouter;
import '../models/backend/backend_types.dart';
import '../providers/logging_service_provider.dart';

/// What the app does around a lost device. The reconnecting itself is the
/// native heartbeat's (every device type on the imaging host); a linked
/// client leaves its host's devices to the host.
///
/// Owns:
///   * the user-initiated-disconnect debounce, so the Disconnected a manual
///     disconnect causes is not read as a lost device,
///   * the "Reconnecting" indicator for a device the native side reconnects
///     (it publishes no event of its own for that),
///   * the checkpoint and pause of a live run when its camera or mount is
///     lost, and lifting that pause once both are back.
class DeviceReconnectCoordinator {
  DeviceReconnectCoordinator({
    required Ref ref,
    required SkotiqBackend backend,
    required bool hostOwnsRecovery,
    required Future<void> Function() resumeSequence,
    required Future<void> Function({String? origin}) pauseSequence,
    required void Function(String deviceId) surfaceReconnecting,
    NotificationRouter Function()? notices,
  }) : _ref = ref,
       _notices = notices,
       _backend = backend,
       _hostOwnsRecovery = hostOwnsRecovery,
       _resumeSequence = resumeSequence,
       _pauseSequence = pauseSequence,
       _surfaceReconnecting = surfaceReconnecting {
    // A pause this coordinator placed is its to lift only while it lasts: once
    // the run leaves it (the operator resumed, stopped, or it ended), a later
    // pause is someone else's.
    ref.listen<SequenceExecutionState>(sequenceExecutionStateProvider, (
      _,
      next,
    ) {
      if (next != SequenceExecutionState.paused) _pausedForDeviceLoss = false;
    });
  }

  final Ref _ref;
  final SkotiqBackend _backend;

  /// The notification router a failed checkpoint is told through; null tells
  /// nothing.
  final NotificationRouter Function()? _notices;

  /// On a companion the device events are the imaging host's, relayed. The
  /// host already reconnects, checkpoints and pauses for its own devices, so
  /// the companion must never send its own checkpoint or pause.
  final bool _hostOwnsRecovery;
  final Future<void> Function() _resumeSequence;
  final Future<void> Function({String? origin}) _pauseSequence;

  /// The run is paused because this coordinator paused it for a lost camera
  /// or mount. Only such a pause is lifted when the devices come back; a pause
  /// the operator or the run's own recovery placed waits for the operator.
  bool _pausedForDeviceLoss = false;

  /// Drives the per-device heartbeat-health indicator into "reconnecting"
  /// (`DeviceHeartbeatRouter.surfaceReconnecting`).
  final void Function(String deviceId) _surfaceReconnecting;

  /// How long after a user-initiated disconnect we ignore Disconnected
  /// events for that device id (so the connection-down event the user
  /// just triggered does not read as a lost device).
  static const Duration userDisconnectSuppressDuration = Duration(seconds: 10);

  /// User-initiated disconnects are not device losses for a short while.
  final Set<String> _userInitiatedDisconnects = {};
  Timer? _userDisconnectDebounceTimer;

  /// Set during backend swap so stray Disconnected events against a backend
  /// that is mid-tear-down are not read as lost devices.
  bool _suppressAutoReconnect = false;

  /// Mark [deviceId] as a user-initiated disconnect and arm the debounce
  /// timer so any Disconnected event arriving in the next 10s is treated as
  /// expected.
  void markUserInitiatedDisconnect(String deviceId) {
    if (deviceId.isEmpty) {
      return;
    }
    _userInitiatedDisconnects.add(deviceId);
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
  /// Remove the temporary suppression so a later loss of the still-connected
  /// device is not taken for the user's disconnect.
  void clearUserInitiatedDisconnect(String deviceId) {
    _userInitiatedDisconnects.remove(deviceId);
    if (_userInitiatedDisconnects.isEmpty) {
      _userDisconnectDebounceTimer?.cancel();
      _userDisconnectDebounceTimer = null;
    }
  }

  /// Wind down before a backend swap: clear debounce state and stop reading
  /// Disconnected events as lost devices.
  void prepareForBackendSwap() {
    _suppressAutoReconnect = true;
    _userInitiatedDisconnects.clear();
    _userDisconnectDebounceTimer?.cancel();
    _userDisconnectDebounceTimer = null;
  }

  /// [type]'s device at [deviceId] was lost. On the imaging host the native
  /// heartbeat reconnects it; this only shows it as reconnecting.
  void onDeviceLost(DeviceType type, String deviceId) {
    if (_suppressAutoReconnect || _hostOwnsRecovery) {
      return;
    }

    if (isUserInitiatedDisconnect(deviceId)) {
      logSafely(
        _ref,
        (logger) => logger.info(
          'Skipping auto-reconnect for user-initiated disconnect of '
          '${type.displayName} ($deviceId)',
          source: 'DeviceReconnectCoordinator',
        ),
      );
      return;
    }

    if (!_backend.nativeReconnectedDeviceTypes.contains(type)) return;
    _surfaceReconnecting(deviceId);
    logSafely(
      _ref,
      (logger) => logger.info(
        'Deferring reconnect of ${type.displayName} ($deviceId) to the '
        'native auto-reconnect engine',
        source: 'DeviceReconnectCoordinator',
      ),
    );
  }

  /// Handle disconnection of critical devices (camera, mount) during a live
  /// run: snapshot a fresh checkpoint and pause the run. The reconnect path
  /// lifts that pause via [_considerSequenceResume] once both critical devices
  /// are back; a run already paused keeps its pause and is left to whoever
  /// placed it.
  Future<void> handleCriticalDeviceDisconnect(
    String deviceType,
    String deviceId,
  ) async {
    if (_hostOwnsRecovery) return;
    final sequenceState = _ref.read(sequenceExecutionStateProvider);
    if (!sequenceState.isLive) return;

    try {
      await _backend.saveCheckpoint();
    } catch (e) {
      logSafely(
        _ref,
        (logger) => logger.error(
          'Failed to save checkpoint after critical $deviceType disconnect '
          '($deviceId): $e',
          source: 'DeviceReconnectCoordinator',
        ),
      );
      try {
        _notices?.call().routeRendered(
          category: NotificationCategory.checkpointFailed,
          title: 'Checkpoint Failed',
          body:
              'Failed to save a sequence checkpoint after $deviceType '
              'disconnected.',
          severity: EventSeverity.error,
        );
      } on Object {
        // Notification failure must not mask the hardware-protection pause.
      }
    }

    // A run a manual action holds is paused too, but this pause must outlive
    // the hold: the action's release would otherwise resume the run.
    if (sequenceState == SequenceExecutionState.paused &&
        !_ref.read(runHeldByActionProvider)) {
      return;
    }

    try {
      await _pauseSequence(origin: '$deviceType disconnected');
      _pausedForDeviceLoss = true;
    } catch (e) {
      logSafely(
        _ref,
        (logger) => logger.warning(
          'Failed to pause sequence after critical $deviceType disconnect '
          '($deviceId): $e',
          source: 'DeviceReconnectCoordinator',
        ),
      );
    }
  }

  /// After a reconnect, lift the pause this coordinator placed if and only if
  /// every critical device listed in the active profile is back.
  Future<void> _considerSequenceResume(DeviceType type) async {
    if (type != DeviceType.camera && type != DeviceType.mount) {
      return;
    }

    final sequenceState = _ref.read(sequenceExecutionStateProvider);
    if (!_pausedForDeviceLoss ||
        sequenceState != SequenceExecutionState.paused) {
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
        _pausedForDeviceLoss = false;
      } catch (e) {
        logSafely(
          _ref,
          (logger) => logger.warning(
            'Failed to resume sequence after reconnecting ${type.displayName}: '
            '$e',
            source: 'DeviceReconnectCoordinator',
          ),
        );
      }
    }
  }

  /// Lift this coordinator's device-loss pause after an AUTHORITATIVE
  /// device-connected event, whichever actor reconnected the device. Safe to
  /// call for any device type: only camera/mount drive a resume, and resume
  /// only fires once ALL critical devices are back (see
  /// [_considerSequenceResume]).
  Future<void> onAuthoritativeDeviceConnected(
    DeviceType type,
    String deviceId,
  ) => _considerSequenceResume(type);
}

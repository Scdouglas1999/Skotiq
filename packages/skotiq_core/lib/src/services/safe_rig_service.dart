import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart';
import '../models/sequence/sequence_models.dart';
import '../providers/backend_provider.dart';
import '../providers/equipment/camera_state_provider.dart';
import '../providers/equipment/cover_calibrator_state_provider.dart';
import '../providers/equipment/device_capability_provider.dart';
import '../providers/equipment/dome_state_provider.dart';
import '../providers/equipment/mount_state_provider.dart';
import '../providers/secondary_rig_provider.dart';
import '../providers/sequence_provider.dart';
import '../providers/ui_notification_provider.dart';

/// Outcome of a single [SafeRigService.safeTheRig] invocation.
///
/// Every step that was *attempted* is recorded so callers (and tests) can see
/// exactly what the safe-the-rig action did. [failures] is non-empty when one
/// or more attempted steps threw; in that case [SafeRigService.safeTheRig]
/// also throws a [SafeRigException] AFTER attempting every remaining step —
/// safing the rig must never short-circuit (a dome-close failure must not skip
/// the mount park, and vice-versa). Failures surface through the critical
/// notification and the thrown exception.
@immutable
class SafeRigResult {
  /// True when the running sequence was paused (it was running and the
  /// pause call succeeded).
  final bool sequencePaused;

  /// True when an active camera exposure was aborted successfully.
  final bool exposureAborted;

  /// True when the independent secondary capture loop acknowledged stop.
  ///
  /// Only set when a secondary rig was actually armed. A stop command sent to a
  /// rig that is not running protects nothing, and reporting it as one
  /// ("secondary rig stopped") describes work that did not happen.
  final bool secondaryRigQuiesced;

  /// True when the mount park command was issued successfully.
  final bool mountParked;

  /// True when a park was requested but no mount was connected, so NOTHING was
  /// parked. This is not a protection step: any mount tracking under another
  /// program (or connected to a driver we do not own) is still exposed.
  final bool mountAbsent;

  /// True when the connected mount reported itself already parked, so no park
  /// command was needed. This one genuinely is safe.
  final bool mountAlreadyParked;

  /// True when the dome shutter close command was issued successfully.
  final bool domeClosed;

  /// True when the cover close command was issued successfully.
  final bool coverClosed;

  /// True when a connected camera cooler was disabled successfully.
  final bool coolerDisabled;

  /// Per-step failures, keyed by step name (`exposure`, `pause`, `park`,
  /// `dome`, `cover`, `cooler`). Empty on full success.
  final Map<String, Object> failures;

  const SafeRigResult({
    this.sequencePaused = false,
    this.exposureAborted = false,
    this.secondaryRigQuiesced = false,
    this.mountParked = false,
    this.mountAbsent = false,
    this.mountAlreadyParked = false,
    this.domeClosed = false,
    this.coverClosed = false,
    this.coolerDisabled = false,
    this.failures = const {},
  });

  bool get hasFailures => failures.isNotEmpty;

  /// No park command was needed because there was nothing of ours to park.
  ///
  /// Kept as a derived value for callers that only need "we did not have to
  /// park"; anything that TELLS THE OPERATOR what happened must use
  /// [mountAlreadyParked] / [mountAbsent], which do not conflate a parked mount
  /// with an absent one.
  bool get mountAlreadySafe => mountAlreadyParked || mountAbsent;

  SafeRigResult copyWith({
    bool? sequencePaused,
    bool? exposureAborted,
    bool? secondaryRigQuiesced,
    bool? mountParked,
    bool? mountAbsent,
    bool? mountAlreadyParked,
    bool? domeClosed,
    bool? coverClosed,
    bool? coolerDisabled,
    Map<String, Object>? failures,
  }) {
    return SafeRigResult(
      sequencePaused: sequencePaused ?? this.sequencePaused,
      exposureAborted: exposureAborted ?? this.exposureAborted,
      secondaryRigQuiesced: secondaryRigQuiesced ?? this.secondaryRigQuiesced,
      mountParked: mountParked ?? this.mountParked,
      mountAbsent: mountAbsent ?? this.mountAbsent,
      mountAlreadyParked: mountAlreadyParked ?? this.mountAlreadyParked,
      domeClosed: domeClosed ?? this.domeClosed,
      coverClosed: coverClosed ?? this.coverClosed,
      coolerDisabled: coolerDisabled ?? this.coolerDisabled,
      failures: failures ?? this.failures,
    );
  }
}

/// Thrown when one or more safe-the-rig steps failed. Carries the partial
/// [result] so callers can still see what succeeded.
class SafeRigException implements Exception {
  final SafeRigResult result;
  final String reason;

  SafeRigException(this.reason, this.result);

  @override
  String toString() {
    final failed = result.failures.entries
        .map((e) => '${e.key}: ${e.value}')
        .join('; ');
    return 'SafeRigException(reason="$reason", failures=[$failed])';
  }
}

/// Shared, reliable "safe the rig" action used by every unattended-night
/// safety path that must put the hardware into a non-imaging, non-tracking,
/// weather-protected state.
///
/// Why this exists: three independent P0 paths — weather-safety enforcement,
/// the low-disk watchdog, and end-of-night handling — each need the same
/// missing capability: pause the running sequence (preserving its
/// checkpoint), park the mount so it stops tracking into the ground/clouds,
/// and optionally close the dome shutter and cover. Before this service the
/// weather path *computed* the actions but never executed them, and the
/// low-disk watchdog only paused (leaving the mount tracking with the night
/// dead and unattended). Centralising the action means there is one
/// fail-closed, loudly-erroring implementation instead of three divergent
/// half-implementations.
///
/// Ordering rationale:
///   1. Pause the sequence FIRST so no new exposure / slew is issued while we
///      park (best-effort: if there is no running sequence, this is a no-op).
///   2. Park the mount — the safety-critical step. Stops tracking; on most
///      mounts also slews to a safe stow position.
///   3. Close the dome shutter, then the cover — physical weather protection.
///
/// Every requested step is attempted even if an earlier one throws; the
/// aggregated failures are surfaced via a CRITICAL notification and a thrown
/// [SafeRigException]. Device ids are resolved from the live equipment state
/// providers exactly as [_autoResumeAfterWeatherClear] resolves the mount.
class SafeRigService {
  final Ref _ref;
  final SkotiqBackend _backend;
  final BackendNotifier _backendNotifier;

  /// Stops the secondary capture loop and returns whether a secondary rig was
  /// actually running (so the outcome report can distinguish "stopped it" from
  /// "there was nothing to stop").
  final Future<bool> Function() _stopSecondaryRig;
  bool _retired = false;

  SafeRigService(
    Ref ref, {
    SkotiqBackend? backend,
    required Future<bool> Function() stopSecondaryRig,
  }) : _ref = ref,
       _backend = backend ?? ref.read(backendProvider),
       _backendNotifier = ref.read(backendProvider.notifier),
       _stopSecondaryRig = stopSecondaryRig;

  bool get _hasAuthority =>
      !_retired && _backendNotifier.isCurrentBackend(_backend);

  void retire() => _retired = true;

  void _ensureAuthority(
    String reason,
    SafeRigResult result,
    Map<String, Object> failures,
  ) {
    if (_hasAuthority) return;
    throw SafeRigException(
      reason,
      result.copyWith(
        failures: Map.unmodifiable({
          ...failures,
          'authority': StateError(
            'The imaging host changed while the rig was being safed. No '
            'further commands were sent; verify the outgoing rig manually.',
          ),
        }),
      ),
    );
  }

  /// Safe the rig.
  ///
  /// [reason] is the human-readable trigger ("Weather turned unsafe",
  /// "Disk space critically low", …) used in the critical notification.
  ///
  /// [abortExposure] / [park] / [closeDome] / [closeCover] /
  /// [disableCooling] / [quiesceSecondaryRig] gate the optional protection
  /// steps. The sequence is paused only when it is actually running; an idle
  /// or already-paused sequencer needs no command. When [park] is true but no
  /// mount is connected, or the mount is already parked, the park step is
  /// skipped and recorded as
  /// [SafeRigResult.mountAlreadySafe] — that is success, not a failure.
  ///
  /// [notify] controls whether the CRITICAL UI notification is posted (default
  /// true). Callers that emit their own richer notification can disable it.
  ///
  /// Throws [SafeRigException] if any attempted step failed (after attempting
  /// all of them).
  Future<SafeRigResult> safeTheRig({
    required String reason,
    bool park = true,
    bool closeDome = false,
    bool closeCover = false,
    bool abortExposure = false,
    bool disableCooling = false,
    bool quiesceSecondaryRig = true,
    bool notify = true,
  }) async {
    final failures = <String, Object>{};
    var result = const SafeRigResult();
    _ensureAuthority(reason, result, failures);

    // The secondary rig owns a capture loop outside the primary sequencer.
    // Stop it first and wait for its native exposure abort to complete before
    // the primary sequence can be paused or the shared mount can move.
    if (quiesceSecondaryRig) {
      try {
        // The callback reports whether a secondary rig was actually running.
        // A stop sent to a rig that was never armed protected nothing, so it
        // must not be reported as a step that was carried out.
        final stopped = await _stopSecondaryRig();
        _ensureAuthority(reason, result, failures);
        result = result.copyWith(secondaryRigQuiesced: stopped);
      } catch (e) {
        failures['secondaryRig'] = e;
      }
    }
    _ensureAuthority(reason, result, failures);

    // A daemon/process shutdown cannot leave a sensor integrating after its
    // controlling client disappears. Abort before pausing/parking so no live
    // exposure races the mount move. Weather safing leaves this opt-in false
    // because a paused run may resume after conditions clear.
    if (abortExposure) {
      final camera = _ref.read(cameraStateProvider);
      final connected =
          camera.connectionState == DeviceConnectionState.connected &&
          camera.deviceId != null &&
          camera.deviceId!.isNotEmpty;
      if (connected && camera.isExposing) {
        try {
          await _backend.cameraAbortExposure(camera.deviceId!);
          _ensureAuthority(reason, result, failures);
          _ref.read(cameraStateProvider.notifier).setExposing(false);
          result = result.copyWith(exposureAborted: true);
        } catch (e) {
          failures['exposure'] = e;
        }
      }
    }
    _ensureAuthority(reason, result, failures);

    // 1. Pause a running sequence so no further exposure/slew is dispatched
    //    while we park. Do not send an invalid pause command while idle or
    //    already paused: several backends correctly reject that command, and
    //    treating the rejection as a safing failure obscures whether the
    //    hardware protection steps actually succeeded.
    final executionState = _ref.read(sequenceExecutionStateProvider);
    if (executionState.canPause) {
      try {
        await _backend.sequencerPause();
        _ensureAuthority(reason, result, failures);
        result = result.copyWith(sequencePaused: true);
      } catch (e) {
        failures['pause'] = e;
      }
    }
    _ensureAuthority(reason, result, failures);

    // 2. Park the mount (the safety-critical step).
    if (park) {
      final mount = _ref.read(mountStateProvider);
      final connected =
          mount.connectionState == DeviceConnectionState.connected &&
          mount.deviceId != null &&
          mount.deviceId!.isNotEmpty;
      if (!connected) {
        // No mount connected: nothing was parked. Recorded as absent, NOT as
        // "already safe" — the operator must not be told the mount is secure
        // when we never had one to command.
        result = result.copyWith(mountAbsent: true);
      } else if (mount.isParked) {
        // Already parked — already safe.
        result = result.copyWith(mountAlreadyParked: true);
      } else {
        try {
          await _backend.mountPark(mount.deviceId!);
          _ensureAuthority(reason, result, failures);
          _ref.read(mountStateProvider.notifier).setParked(true);
          _ref.read(mountStateProvider.notifier).setTracking(false);
          result = result.copyWith(mountParked: true);
        } catch (e) {
          failures['park'] = e;
        }
      }
    }
    _ensureAuthority(reason, result, failures);

    // 3. Close the dome shutter (physical weather protection).
    if (closeDome) {
      final dome = _ref.read(domeStateProvider);
      final connected =
          dome.connectionState == DeviceConnectionState.connected &&
          dome.deviceId != null &&
          dome.deviceId!.isNotEmpty;
      final alreadyClosed =
          dome.shutterStatus == ShutterStatus.closed ||
          dome.shutterStatus == ShutterStatus.closing;
      if (connected && !alreadyClosed) {
        try {
          final capabilities = await _ref.read(
            equipmentDomeCapabilitiesProvider(dome.deviceId!).future,
          );
          _ensureAuthority(reason, result, failures);
          if (capabilities == null) {
            throw StateError(
              'Dome capabilities are unavailable; shutter closure cannot be '
              'verified as supported',
            );
          }
          if (!capabilities.canSetShutter) {
            throw UnsupportedError(
              'Connected dome does not support shutter control',
            );
          }
          await closeDomeShutter(_backend, dome.deviceId!);
          _ensureAuthority(reason, result, failures);
          result = result.copyWith(domeClosed: true);
        } catch (e) {
          failures['dome'] = e;
        }
      }
    }
    _ensureAuthority(reason, result, failures);

    // 4. Close the cover (physical weather protection).
    if (closeCover) {
      final cover = _ref.read(coverCalibratorStateProvider);
      final connected =
          cover.connectionState == DeviceConnectionState.connected &&
          cover.deviceId != null &&
          cover.deviceId!.isNotEmpty;
      if (connected && cover.hasCover && !cover.isCoverClosed) {
        try {
          await closeCalibratorCover(_backend, cover.deviceId!);
          _ensureAuthority(reason, result, failures);
          result = result.copyWith(coverClosed: true);
        } catch (e) {
          failures['cover'] = e;
        }
      }
    }
    _ensureAuthority(reason, result, failures);

    // Driver-side coolers often remain energized after the client exits. For
    // terminal shutdown paths, explicitly turn cooling off after the rig is
    // physically protected. A normal weather pause intentionally keeps it on.
    if (disableCooling) {
      final camera = _ref.read(cameraStateProvider);
      final connected =
          camera.connectionState == DeviceConnectionState.connected &&
          camera.deviceId != null &&
          camera.deviceId!.isNotEmpty;
      var coolerActive =
          camera.isCooling ||
          camera.isWarming ||
          (camera.coolerPower != null && camera.coolerPower! > 0);
      if (connected) {
        try {
          final status = await _backend.getCameraStatus(camera.deviceId!);
          if (!status.connected) {
            throw StateError(
              'Camera status reports disconnected while disabling cooler',
            );
          }
          coolerActive =
              coolerActive ||
              status.coolerOn ||
              (status.coolerPower != null && status.coolerPower! > 0);
          // A fresh status that explicitly reports no cooling capability and
          // no active cooler is authoritative: there is nothing to disable.
          if (!status.canCool && !coolerActive) {
            coolerActive = false;
          }
        } catch (e) {
          if (!coolerActive) {
            failures['cooler'] = StateError(
              'Could not verify whether the connected camera cooler is off: '
              '$e',
            );
          }
        }
      }
      _ensureAuthority(reason, result, failures);
      if (connected && coolerActive) {
        try {
          await _backend.cameraSetCooling(
            deviceId: camera.deviceId!,
            enabled: false,
          );
          _ensureAuthority(reason, result, failures);
          final notifier = _ref.read(cameraStateProvider.notifier);
          notifier.markCoolingDisabled();
          result = result.copyWith(coolerDisabled: true);
        } catch (e) {
          failures['cooler'] = e;
        }
      }
    }

    _ensureAuthority(reason, result, failures);

    result = result.copyWith(failures: Map.unmodifiable(failures));

    if (notify) {
      _emitNotification(reason, result);
    }

    if (result.hasFailures) {
      throw SafeRigException(reason, result);
    }
    return result;
  }

  /// Issue the dome-shutter close command against [deviceId].
  ///
  /// Routed through the active backend's [DeviceBackend] role: the network
  /// backend forwards to the imaging host's `dome/close` endpoint; the local
  /// FFI backend calls the Rust bridge. `@visibleForTesting` so unit tests can
  /// record the call without a live bridge.
  @visibleForTesting
  Future<void> closeDomeShutter(SkotiqBackend backend, String deviceId) {
    return backend.domeCloseShutter(deviceId);
  }

  /// Issue the cover close command against [deviceId]. See [closeDomeShutter].
  @visibleForTesting
  Future<void> closeCalibratorCover(
    SkotiqBackend backend,
    String deviceId,
  ) {
    return backend.coverClose(deviceId);
  }

  void _emitNotification(String reason, SafeRigResult result) {
    final notifier = _ref.read(uiNotificationProvider.notifier);
    if (result.hasFailures) {
      final failed = result.failures.keys.join(', ');
      notifier.showError(
        'CRITICAL: $reason. Safe-the-rig partially FAILED ($failed). '
        'Operator intervention required.',
        title: 'Safe the rig',
        duration: const Duration(seconds: 20),
      );
      return;
    }

    // Report ONLY what was actually done. A step skipped because its device is
    // not connected is not an accomplishment: listing it tells the operator the
    // rig is secure when nothing was commanded.
    final steps = <String>[];
    if (result.sequencePaused) steps.add('sequence paused');
    if (result.exposureAborted) steps.add('exposure aborted');
    if (result.secondaryRigQuiesced) steps.add('secondary rig stopped');
    if (result.mountParked) steps.add('mount parked');
    if (result.mountAlreadyParked && !result.mountParked) {
      steps.add('mount was already parked');
    }
    if (result.domeClosed) steps.add('dome closed');
    if (result.coverClosed) steps.add('cover closed');
    if (result.coolerDisabled) steps.add('cooler disabled');
    final gap = result.mountAbsent
        ? ' NO MOUNT CONNECTED — nothing was parked; if a mount is tracking '
              'under another program it is still exposed.'
        : '';

    if (steps.isEmpty) {
      // Not a safing event: no run was active and no device answered, so
      // nothing was commanded. A warning, not a critical "rig safed" — on an
      // idle, disconnected app (weather safety resolves fail-closed to unsafe
      // when no weather source exists) this is the only thing the operator
      // sees.
      notifier.showWarning(
        'Nothing to safe: $reason. No run was active and no mount, dome or '
        'cover is connected.$gap',
        title: 'Safe the rig',
        duration: const Duration(seconds: 16),
      );
      return;
    }

    notifier.showError(
      'CRITICAL: $reason. Rig safed: ${steps.join(', ')}.$gap',
      title: 'Safe the rig',
      duration: const Duration(seconds: 16),
    );
  }
}

/// Stop the secondary capture loop, reporting whether one was actually armed.
///
/// The armed check runs first because after a successful stop the rig always
/// reads disarmed, so there would be no way to tell afterwards whether anything
/// was stopped. If the check itself fails we still issue the stop but report
/// `false`: an unverified claim that the secondary rig was stopped is exactly
/// the kind of statement this reporting must never make.
Future<bool> _stopSecondaryRigReportingWhetherItRan(Ref ref) async {
  final controller = ref.read(secondaryRigControllerProvider);
  var wasArmed = false;
  try {
    wasArmed = await controller.isArmed();
  } catch (error, stackTrace) {
    debugPrint(
      'Could not determine whether the secondary rig was armed: $error\n'
      '$stackTrace',
    );
    wasArmed = false;
  }
  await controller.stop();
  return wasArmed;
}

/// Provider for the shared safe-the-rig action.
final safeRigServiceProvider = Provider<SafeRigService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = SafeRigService(
    ref,
    backend: backend,
    stopSecondaryRig: () => _stopSecondaryRigReportingWhetherItRan(ref),
  );
  ref.onDispose(service.retire);
  return service;
});

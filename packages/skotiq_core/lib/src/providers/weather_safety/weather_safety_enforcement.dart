// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of '../weather_safety_provider.dart';

/// Hardware enforcement and the auto-resume state machine for
/// [WeatherSafetyNotifier].
extension _WeatherSafetyEnforcement on WeatherSafetyNotifier {
  /// Execute and latch the computed actions only after every requested SafeRig
  /// step succeeds. Failed attempts deliberately leave the episode re-armed.
  Future<void> _enforceSafetyActionsAndLatch(
    WeatherSafetyActions actions,
  ) async {
    if (_safeRigEnforced || _enforceInFlight) return;
    final succeeded = await _enforceSafetyActions(actions);
    if (!mounted) return;
    if (succeeded && state.status == WeatherSafetyStatus.unsafe) {
      _safeRigEnforced = true;
    }
  }

  /// Execute the computed weather-safety actions on the hardware via the
  /// shared [SafeRigService]. Idempotent enough to be safe even if the latch
  /// were bypassed: SafeRig skips an already-parked mount / already-closed
  /// dome. Fail-closed: SafeRig throws on partial failure and surfaces a
  /// CRITICAL notification; we additionally log a warning banner here so the
  /// operator sees the weather-safety framing.
  Future<bool> _enforceSafetyActions(WeatherSafetyActions actions) async {
    // Authority may change while an evaluation is in flight. Neither a remote
    // client nor disconnected UI-only mode may execute the host's local
    // SafeRig workflow.
    final backend = _ref.read(backendProvider);
    if (backend is DisconnectedBackend || backend is NetworkBackend) {
      return false;
    }
    if (_enforceInFlight) return false;
    _enforceInFlight = true;
    final executionBefore = _ref.read(sequenceExecutionStateProvider);
    final mountBefore = _ref.read(mountStateProvider);
    void recordOwnership(SafeRigResult result) {
      _weatherPausedSequence =
          actions.shouldPause &&
          executionBefore == SequenceExecutionState.running &&
          result.sequencePaused;
      _weatherParkedMount =
          actions.shouldPark && !mountBefore.isParked && result.mountParked;
    }

    try {
      if (!actions.shouldPause &&
          !actions.shouldPark &&
          !actions.shouldCloseDome) {
        return true;
      }
      if (!await _hasAnythingToSafe()) {
        // Nothing is running and nothing SafeRig could command is connected,
        // so running the safing workflow would issue no protective command
        // while announcing a rig-safing event. That is what turned "enable
        // weather safety" on an idle, disconnected app into a red alert. Say
        // what is actually true instead, and stay re-armed (return false) so
        // the next evaluation still safes the rig the moment a mount, dome or
        // run appears while conditions remain unsafe.
        _announceNothingToSafe(actions);
        return false;
      }
      final safeRig = _ref.read(safeRigServiceProvider);
      final result = await safeRig.safeTheRig(
        reason: actions.reason ?? 'Weather turned unsafe',
        park: actions.shouldPark,
        closeDome: actions.shouldCloseDome,
        // Cover follows the dome decision: if conditions warrant closing the
        // dome shutter they also warrant closing a flip-flat / cover.
        closeCover: actions.shouldCloseDome,
      );
      recordOwnership(result);
      return true;
    } on SafeRigException catch (e) {
      recordOwnership(e.result);
      if (mounted) {
        _ref
            .read(uiNotificationProvider.notifier)
            .showError(
              'Weather safety enforcement did not fully complete: $e',
              title: 'Weather Safety',
              duration: const Duration(seconds: 15),
            );
      }
      return false;
    } catch (e) {
      // SafeRig already posted a CRITICAL notification with the per-step
      // failures; add the weather-safety context so the operator knows what
      // tripped it. Do not rethrow — the periodic evaluator must keep running.
      if (mounted) {
        _ref
            .read(uiNotificationProvider.notifier)
            .showError(
              'Weather safety enforcement did not fully complete: $e',
              title: 'Weather Safety',
              duration: const Duration(seconds: 15),
            );
      }
      return false;
    } finally {
      _enforceInFlight = false;
    }
  }

  /// Whether SafeRig currently has anything it could actually command: a
  /// pausable sequence, an armed secondary capture loop, or a connected mount,
  /// dome or cover. This is exactly the union of the conditions under which
  /// [SafeRigService.safeTheRig] issues a command on the weather path, so a
  /// `false` here means the workflow would protect nothing.
  ///
  /// Errs towards enforcing: if the secondary-rig status cannot be read we
  /// assume a rig may be running and let the safing workflow proceed.
  Future<bool> _hasAnythingToSafe() async {
    bool connected(DeviceConnectionState connectionState, String? deviceId) =>
        connectionState == DeviceConnectionState.connected &&
        deviceId != null &&
        deviceId.isNotEmpty;

    if (_ref.read(sequenceExecutionStateProvider).canPause) return true;
    final mount = _ref.read(mountStateProvider);
    if (connected(mount.connectionState, mount.deviceId)) return true;
    final dome = _ref.read(domeStateProvider);
    if (connected(dome.connectionState, dome.deviceId)) return true;
    final cover = _ref.read(coverCalibratorStateProvider);
    if (connected(cover.connectionState, cover.deviceId)) return true;
    try {
      return await _ref.read(secondaryRigControllerProvider).isArmed();
    } catch (_) {
      return true;
    }
  }

  /// State the truth for an unsafe verdict that commands nothing, once per
  /// episode: a warning about the configuration, not a rig-safing alert.
  void _announceNothingToSafe(WeatherSafetyActions actions) {
    if (_nothingToSafeAnnounced || !mounted) return;
    _nothingToSafeAnnounced = true;
    final reason = actions.reason ?? 'Weather turned unsafe';
    _ref
        .read(uiNotificationProvider.notifier)
        .showWarning(
          '$reason. No run is active and no mount, dome or cover is '
          'connected, so nothing was commanded. Weather safety will act as '
          'soon as equipment is connected or a run starts.',
          title: 'Weather Safety',
          duration: const Duration(seconds: 12),
        );
  }

  void _scheduleAutoResume() {
    // Why: defer the unpark by `_autoResumeHoldoff` so a transient
    // safe-reading does not force an immediate resume. The banner posted
    // here is the same UI surface that announced the park so the operator
    // sees the full park-then-resume narrative in one place.
    _resumeDelayTimer?.cancel();
    final generation = ++_autoResumeGeneration;
    final resumeAt = DateTime.now().add(_autoResumeDelay);
    Future<void>.microtask(() {
      if (!mounted || generation != _autoResumeGeneration) return;
      final mins = _autoResumeDelay.inMinutes;
      _ref
          .read(uiNotificationProvider.notifier)
          .showInfo(
            'Weather is clearing; auto-resume scheduled for '
            '${resumeAt.hour.toString().padLeft(2, '0')}:'
            '${resumeAt.minute.toString().padLeft(2, '0')} '
            '(after $mins min hold-off).',
            title: 'Weather Safety',
            duration: const Duration(seconds: 10),
          );
    });
    _resumeDelayTimer = Timer(_autoResumeDelay, () {
      if (!mounted || generation != _autoResumeGeneration) return;
      // Re-check just before resuming. If the periodic evaluator pushed us
      // back to unsafe during the wait we abort.
      if (state.status != WeatherSafetyStatus.safe) {
        Future<void>.microtask(() {
          if (!mounted) return;
          _ref
              .read(uiNotificationProvider.notifier)
              .showWarning(
                'Auto-resume aborted: conditions deteriorated during hold-off.',
                title: 'Weather Safety',
                duration: const Duration(seconds: 10),
              );
        });
        return;
      }
      unawaited(_autoResumeAfterWeatherClear(generation));
    });
  }

  void _cancelPendingAutoResume() {
    // Invalidating the generation also retires a recovery that has already
    // passed the hold-off timer and is awaiting an unpark/resume command.
    // Cancelling only the Timer allowed that stale continuation to resume the
    // sequence after conditions had turned unsafe again.
    _autoResumeGeneration++;
    _resumeDelayTimer?.cancel();
    _resumeDelayTimer = null;
  }

  bool _canContinueAutoResume(SkotiqBackend backend, int generation) =>
      mounted &&
      generation == _autoResumeGeneration &&
      state.status == WeatherSafetyStatus.safe &&
      _backendNotifier.isCurrentBackend(backend);

  Future<void> _restoreSafetyAfterInterruptedResume({
    required SkotiqBackend backend,
    required bool sequenceResumeIssued,
    required bool mountUnparkIssued,
    required String? mountDeviceId,
  }) async {
    // A command can finish after weather re-degrades. The normal unsafe
    // enforcement may have run while that command was still pending, so undo
    // our own late completion explicitly; otherwise an unpark/resume can be
    // the final command and leave an unattended rig active in unsafe weather.
    if (!mounted ||
        state.status != WeatherSafetyStatus.unsafe ||
        !_backendNotifier.isCurrentBackend(backend)) {
      return;
    }

    final failures = <String>[];
    if (sequenceResumeIssued) {
      try {
        await backend.sequencerPause();
      } catch (error) {
        failures.add('pause sequence: $error');
      }
    }
    if (mountUnparkIssued && mountDeviceId != null) {
      try {
        await backend.mountPark(mountDeviceId);
      } catch (error) {
        failures.add('park mount: $error');
      }
    }

    if (failures.isNotEmpty && mounted) {
      _ref
          .read(uiNotificationProvider.notifier)
          .showError(
            'Weather became unsafe during automatic recovery, and Skotiq '
            'could not fully restore the safe state (${failures.join('; ')}).',
            title: 'Weather Safety',
            duration: const Duration(seconds: 15),
          );
    }
  }

  Future<void> _autoResumeAfterWeatherClear(int generation) async {
    if (_resumeInFlight) return;
    _resumeInFlight = true;
    final backend = _backendNotifier.currentBackend;
    var mountUnparkIssued = false;
    var sequenceResumeIssued = false;
    String? mountDeviceId;
    try {
      if (!_canContinueAutoResume(backend, generation)) return;
      if (_weatherParkedMount) {
        final mount = _ref.read(mountStateProvider);
        final connected =
            mount.connectionState == DeviceConnectionState.connected &&
            mount.deviceId != null &&
            mount.deviceId!.isNotEmpty;
        if (!connected) {
          throw StateError(
            'Cannot auto-resume: the weather-parked mount is disconnected',
          );
        }
        mountDeviceId = mount.deviceId!;
        if (mount.isParked) {
          await backend.mountUnpark(mountDeviceId);
          mountUnparkIssued = true;
        }
        if (!_canContinueAutoResume(backend, generation)) {
          await _restoreSafetyAfterInterruptedResume(
            backend: backend,
            sequenceResumeIssued: sequenceResumeIssued,
            mountUnparkIssued: mountUnparkIssued,
            mountDeviceId: mountDeviceId,
          );
          return;
        }
        _weatherParkedMount = false;
      }
      if (_weatherPausedSequence) {
        if (!_canContinueAutoResume(backend, generation)) return;
        await backend.sequencerResume();
        sequenceResumeIssued = true;
        if (!_canContinueAutoResume(backend, generation)) {
          await _restoreSafetyAfterInterruptedResume(
            backend: backend,
            sequenceResumeIssued: sequenceResumeIssued,
            mountUnparkIssued: mountUnparkIssued,
            mountDeviceId: mountDeviceId,
          );
          return;
        }
        _weatherPausedSequence = false;
      }
      if (!_canContinueAutoResume(backend, generation)) return;
      _ref
          .read(uiNotificationProvider.notifier)
          .showInfo(
            'Weather is safe again; weather-owned safing actions were reversed.',
            title: 'Weather Safety',
            duration: const Duration(seconds: 8),
          );
    } catch (e) {
      if (!_canContinueAutoResume(backend, generation)) return;
      _ref
          .read(uiNotificationProvider.notifier)
          .showWarning(
            'Weather cleared, but automatic resume failed: $e',
            title: 'Weather Safety',
            duration: const Duration(seconds: 10),
          );
    } finally {
      _resumeInFlight = false;
    }
  }
}

bool _isLiveReading(SafetySourceReading reading) =>
    reading == SafetySourceReading.safe ||
    reading == SafetySourceReading.unsafe;

part of '../connected_device_card.dart';

extension _ConnectedDeviceCommandHandlers on _ConnectedDeviceCardState {
  // Action handlers

  Future<void> _handleDisconnect() async {
    // Disconnecting a camera whose TEC is still active cuts cooler power
    // abruptly — gate with the shared cooled-camera confirm. Confirm BEFORE
    // _beginDeviceCommand so the card is not held busy while the dialog is up.
    if (widget.type == ConnectedDeviceType.camera) {
      final proceed = await confirmDisconnectCooledCamera(context, ref);
      if (!proceed || !mounted) return;
    }
    final revision = _beginDeviceCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = _currentCardDeviceId();
    try {
      switch (widget.type) {
        case ConnectedDeviceType.camera:
          await deviceService.disconnectCamera();
          break;
        case ConnectedDeviceType.mount:
          await deviceService.disconnectMount();
          break;
        case ConnectedDeviceType.focuser:
          await deviceService.disconnectFocuser();
          break;
        case ConnectedDeviceType.filterWheel:
          await deviceService.disconnectFilterWheel();
          break;
        case ConnectedDeviceType.guider:
          await deviceService.disconnectGuider();
          break;
        case ConnectedDeviceType.rotator:
          await deviceService.disconnectRotator();
          break;
        case ConnectedDeviceType.dome:
          await deviceService.disconnectDome();
          break;
        case ConnectedDeviceType.weather:
          await deviceService.disconnectWeather();
          break;
        case ConnectedDeviceType.safetyMonitor:
          await deviceService.disconnectSafetyMonitor();
          break;
        case ConnectedDeviceType.coverCalibrator:
          await deviceService.disconnectCoverCalibrator();
          break;
      }
    } catch (e) {
      if (mounted &&
          _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
        context.showErrorSnackBar('Failed to disconnect: $e');
      }
    } finally {
      _finishDeviceCommand(revision, backend);
    }
  }

  Future<void> _handleCoolCamera(double targetTemp) async {
    final revision = _beginDeviceCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = ref.read(cameraStateProvider).deviceId;
    // Cancel any in-progress warm-up before cooling
    deviceService.cancelWarmCamera();
    try {
      await deviceService.setCameraCooling(
          enabled: true, targetTemp: targetTemp);
      if (mounted &&
          _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
        context.showSuccessSnackBar(
            'Cooling to ${formatCelsius(targetTemp, decimals: 0)}');
      }
    } catch (e) {
      if (mounted &&
          _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
        context.showErrorSnackBar('Failed to start cooling: $e');
      }
    } finally {
      _finishDeviceCommand(revision, backend);
    }
  }

  /// Set the camera's cooling setpoint and start cooling to it.
  ///
  /// The dialog validates a finite target (rejecting blank/`NaN`/`±∞` input
  /// with inline feedback and zero hardware work), then stays open and busy
  /// while [DeviceService.setCameraCooling] is awaited. It closes only once the
  /// driver confirms; a hardware failure keeps the dialog open with the typed
  /// value intact and re-enables Set for a retry. The Set button is guarded
  /// against double submission so a rapid double-tap issues a single cooling
  /// command. No capability temperature range is imposed because the camera
  /// state does not expose min/max setpoint bounds — only finiteness is
  /// enforced here (with defense-in-depth in DeviceService).
  Future<void> _showCoolingTempDialog(double currentTemp) async {
    var targetText = currentTemp.isFinite ? currentTemp.toStringAsFixed(0) : '';
    final pageContext = context;
    bool isSaving = false;
    String? errorText;

    await _showEquipmentDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (context, setState) {
          final colors = SkotiqColors.of(context);
          return SkotiqDialog(
            title: 'Set Cooling Target',
            icon: LucideIcons.thermometer,
            width: 400,
            actions: [
              SkotiqButton(
                onPressed: isSaving ? null : () => Navigator.pop(context),
                label: 'Cancel',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
              ),
              SkotiqButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        if (isSaving) return;
                        final temp = double.tryParse(targetText.trim());
                        if (temp == null || !temp.isFinite) {
                          setState(() =>
                              errorText = 'Enter a finite target temperature.');
                          return;
                        }
                        setState(() {
                          errorText = null;
                          isSaving = true;
                        });
                        try {
                          final deviceService = ref.read(deviceServiceProvider);
                          // Cancel any in-progress warm-up before cooling, then
                          // drive the cooler to the requested setpoint.
                          deviceService.cancelWarmCamera();
                          await deviceService.setCameraCooling(
                              enabled: true, targetTemp: temp);
                          if (!context.mounted) return;
                          ref
                              .read(cameraStateProvider.notifier)
                              .setTargetTemp(temp);
                          Navigator.pop(context);
                          if (pageContext.mounted) {
                            pageContext.showSuccessSnackBar(
                                'Cooling to ${formatCelsius(temp, decimals: 0)}');
                          }
                        } catch (e) {
                          if (!context.mounted) return;
                          setState(() {
                            isSaving = false;
                            errorText = 'Failed to start cooling: $e';
                          });
                        }
                      },
                label: isSaving ? 'Setting...' : 'Set',
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  initialValue: targetText,
                  onChanged: (value) => targetText = value,
                  enabled: !isSaving,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Target Temperature (C)',
                    labelStyle: SkotiqTypography.bodySm
                        .copyWith(color: colors.textMuted),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: colors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: colors.primary),
                    ),
                  ),
                  style:
                      SkotiqTypography.body.copyWith(color: colors.textPrimary),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorText!,
                    style:
                        SkotiqTypography.bodySm.copyWith(color: colors.error),
                  ),
                ],
              ],
            ),
          );
        });
      },
    );
  }

  Future<void> _handleWarmCamera() async {
    final revision = _beginDeviceCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = ref.read(cameraStateProvider).deviceId;
    try {
      await deviceService.warmCamera();
      if (mounted &&
          _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
        context.showSuccessSnackBar('Gradually warming camera (2°C/min)');
      }
    } catch (e) {
      if (mounted &&
          _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
        context.showErrorSnackBar('Failed to warm up: $e');
      }
    } finally {
      _finishDeviceCommand(revision, backend);
    }
  }

  void _handleCancelWarm() {
    final deviceService = ref.read(deviceServiceProvider);
    deviceService.cancelWarmCamera();
    if (mounted) {
      context.showSuccessSnackBar('Warm-up cancelled');
    }
  }

  Future<void> _handleTogglePark() async {
    final revision = _beginMountCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    final mountService = ref.read(mountCommandServiceProvider);
    try {
      final result = await mountService.togglePark();
      if (mounted &&
          _hasCurrentMountAuthority(backend, mountService, revision)) {
        context.showCommandActionResult(result);
      }
    } finally {
      _finishMountCommand(revision, backend);
    }
  }

  Future<void> _handleFindHome() async {
    final revision = _beginMountCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    final mountService = ref.read(mountCommandServiceProvider);
    try {
      final result = await mountService.findHome();
      if (mounted &&
          _hasCurrentMountAuthority(backend, mountService, revision)) {
        context.showCommandActionResult(result);
      }
    } finally {
      _finishMountCommand(revision, backend);
    }
  }

  Future<void> _handleToggleTracking(bool currentlyTracking) async {
    final revision = _beginMountCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    final mountService = ref.read(mountCommandServiceProvider);
    try {
      final result = await mountService.setTracking(!currentlyTracking);
      if (mounted &&
          _hasCurrentMountAuthority(backend, mountService, revision)) {
        context.showCommandActionResult(result);
      }
    } finally {
      _finishMountCommand(revision, backend);
    }
  }

  /// Manually trigger a meridian flip now (outside the sequencer's automatic
  /// watchdog). Flips and re-points to the mount's current sky position. The
  /// manual path a remote operator needs when stalled at the meridian.
  Future<void> _handleManualMeridianFlip() async {
    final revision = _beginMountCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    try {
      final confirmed = await _showEquipmentDialog<bool>(
        context: context,
        builder: (ctx) => SkotiqDialog(
          title: 'Meridian Flip Now?',
          icon: LucideIcons.flipHorizontal,
          width: 400,
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.pop(ctx, false),
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            SkotiqButton(
              onPressed: () => Navigator.pop(ctx, true),
              label: 'Flip',
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
            ),
          ],
          child: Text(
            'This slews the mount across the meridian and re-points to the '
            'current position. Guiding pauses and resumes automatically. '
            'Proceed?',
            style: SkotiqTypography.bodySm
                .copyWith(color: SkotiqColors.of(ctx).textSecondary),
          ),
        ),
      );
      if (confirmed != true ||
          !mounted ||
          revision != _commandRevision ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }

      final succeeded = await ref
          .read(meridianFlipStandaloneMonitorProvider.notifier)
          .executeNow();
      if (!mounted ||
          revision != _commandRevision ||
          !identical(ref.read(backendProvider), backend)) {
        return;
      }
      if (succeeded) {
        context.showSuccessSnackBar('Meridian flip completed');
      } else {
        context.showErrorSnackBar(
          ref.read(flipLastErrorProvider) ?? 'Meridian flip could not start',
        );
      }
    } finally {
      _finishMountCommand(revision, backend);
    }
  }

  Future<void> _handleFilterChange(int position) async {
    final revision = _beginDeviceCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = ref.read(filterWheelStateProvider).deviceId;
    try {
      await deviceService.setFilterWheelPosition(position);
    } catch (e) {
      if (mounted &&
          _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
        context.showErrorSnackBar('Failed to change filter: $e');
      }
    } finally {
      _finishDeviceCommand(revision, backend);
    }
  }

  Future<void> _handleToggleGuiding(bool currentlyGuiding) async {
    final revision = _beginDeviceCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = ref.read(guiderStateProvider).deviceId;
    try {
      if (currentlyGuiding) {
        await deviceService.stopGuiding();
        if (mounted &&
            _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
          context.showSuccessSnackBar('Guiding stopped');
        }
      } else {
        await deviceService.startGuiding();
        if (mounted &&
            _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
          context.showSuccessSnackBar('Guiding started');
        }
      }
    } catch (e) {
      if (mounted &&
          _hasCurrentDeviceAuthority(backend, deviceService, deviceId)) {
        context.showErrorSnackBar('Guiding operation failed: $e');
      }
    } finally {
      _finishDeviceCommand(revision, backend);
    }
  }

  String? _currentCardDeviceId() => switch (widget.type) {
        ConnectedDeviceType.camera => ref.read(cameraStateProvider).deviceId,
        ConnectedDeviceType.mount => ref.read(mountStateProvider).deviceId,
        ConnectedDeviceType.focuser => ref.read(focuserStateProvider).deviceId,
        ConnectedDeviceType.filterWheel =>
          ref.read(filterWheelStateProvider).deviceId,
        ConnectedDeviceType.guider => ref.read(guiderStateProvider).deviceId,
        ConnectedDeviceType.rotator => ref.read(rotatorStateProvider).deviceId,
        ConnectedDeviceType.dome => ref.read(domeStateProvider).deviceId,
        ConnectedDeviceType.weather => ref.read(weatherStateProvider).deviceId,
        ConnectedDeviceType.safetyMonitor =>
          ref.read(safetyMonitorStateProvider).deviceId,
        ConnectedDeviceType.coverCalibrator =>
          ref.read(coverCalibratorStateProvider).deviceId,
      };

  bool _hasCurrentDeviceAuthority(
    SkotiqBackend backend,
    DeviceService deviceService,
    String? deviceId,
  ) =>
      mounted &&
      identical(ref.read(backendProvider), backend) &&
      identical(ref.read(deviceServiceProvider), deviceService) &&
      _currentCardDeviceId() == deviceId;

  bool _hasCurrentMountAuthority(
    SkotiqBackend backend,
    MountCommandService service,
    int revision,
  ) =>
      mounted &&
      revision == _commandRevision &&
      identical(ref.read(backendProvider), backend) &&
      identical(ref.read(mountCommandServiceProvider), service);

  // Dome action handlers

  bool _hasCurrentDomeAuthority(
    SkotiqBackend backend,
    String deviceId,
  ) {
    return identical(ref.read(backendProvider), backend) &&
        ref.read(domeStateProvider).deviceId == deviceId;
  }

  /// Re-read dome telemetry so the card reflects the command that just
  /// completed. Without this the dome readouts only moved on the 5 s poll, and
  /// before the poll existed at all they never moved — the shutter button stayed
  /// on "Open Shutter" forever while a green toast claimed the shutter was
  /// opening.
  Future<void> _refreshDomeAfterCommand() =>
      ref.read(deviceServiceProvider).refreshDomeStatus();

  Future<void> _handleDomeShutter(ShutterStatus currentStatus) async {
    final domeState = ref.read(domeStateProvider);
    final deviceId = domeState.deviceId;
    if (deviceId == null) return;
    final revision = _beginDomeCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    try {
      if (currentStatus == ShutterStatus.open) {
        await backend.domeCloseShutter(deviceId);
      } else {
        await backend.domeOpenShutter(deviceId);
      }
      await _refreshDomeAfterCommand();
      if (mounted && _hasCurrentDomeAuthority(backend, deviceId)) {
        // Report what we actually know. The command was accepted; whether the
        // shutter is moving is only knowable from the telemetry read above, so
        // when that read leaves the state unknown we say "sent", not "opening".
        final observed = ref.read(domeStateProvider).shutterStatus;
        final closing = currentStatus == ShutterStatus.open;
        final verb = closing ? 'Close' : 'Open';
        context.showSuccessSnackBar(
          observed == ShutterStatus.unknown
              ? '$verb shutter command sent — dome is not reporting '
                  'shutter state'
              : closing
                  ? 'Closing dome shutter'
                  : 'Opening dome shutter',
        );
      }
    } catch (e) {
      if (mounted && _hasCurrentDomeAuthority(backend, deviceId)) {
        context.showErrorSnackBar('Dome shutter operation failed: $e');
      }
    } finally {
      _finishDomeCommand(revision, backend);
    }
  }

  Future<void> _handleDomePark() async {
    final domeState = ref.read(domeStateProvider);
    final deviceId = domeState.deviceId;
    if (deviceId == null || domeState.isParked) return;
    final revision = _beginDomeCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    try {
      await backend.domePark(deviceId);
      await _refreshDomeAfterCommand();
      if (mounted && _hasCurrentDomeAuthority(backend, deviceId)) {
        context.showSuccessSnackBar('Parking dome');
      }
    } catch (e) {
      if (mounted && _hasCurrentDomeAuthority(backend, deviceId)) {
        context.showErrorSnackBar('Dome park operation failed: $e');
      }
    } finally {
      _finishDomeCommand(revision, backend);
    }
  }

  Future<void> _handleDomeHome() async {
    final domeState = ref.read(domeStateProvider);
    final deviceId = domeState.deviceId;
    if (deviceId == null) return;
    final revision = _beginDomeCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    try {
      await backend.domeFindHome(deviceId);
      await _refreshDomeAfterCommand();
      if (mounted && _hasCurrentDomeAuthority(backend, deviceId)) {
        context.showSuccessSnackBar('Homing dome');
      }
    } catch (e) {
      if (mounted && _hasCurrentDomeAuthority(backend, deviceId)) {
        context.showErrorSnackBar('Dome home failed: $e');
      }
    } finally {
      _finishDomeCommand(revision, backend);
    }
  }

  Future<void> _handleDomeHalt() async {
    final domeState = ref.read(domeStateProvider);
    final deviceId = domeState.deviceId;
    if (deviceId == null) return;
    final revision = _beginDomeCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    try {
      await backend.domeAbortSlew(deviceId);
      await _refreshDomeAfterCommand();
      if (mounted && _hasCurrentDomeAuthority(backend, deviceId)) {
        context.showSuccessSnackBar('Stopping dome');
      }
    } catch (e) {
      if (mounted && _hasCurrentDomeAuthority(backend, deviceId)) {
        context.showErrorSnackBar('Dome halt failed: $e');
      }
    } finally {
      _finishDomeCommand(revision, backend);
    }
  }

  /// Route the equipment-card safety override through the same state machine
  /// as Weather and the run dashboard. That gives local and remote sessions
  /// identical duration, cancellation and failure behavior.
  void _handleSafetySnooze() {
    ref.read(equipmentSafetySnoozeActionProvider)(
      const Duration(minutes: 15),
    );
  }

  void _handleSafetyCancelSnooze() {
    ref.read(equipmentSafetyCancelSnoozeActionProvider)();
  }

  // Cover calibrator action handlers

  Future<void> _handleCoverToggle(bool isOpen) async {
    final coverState = ref.read(coverCalibratorStateProvider);
    final deviceId = coverState.deviceId;
    if (deviceId == null ||
        coverState.connectionState != DeviceConnectionState.connected) {
      return;
    }
    final revision = _beginCoverCalibratorCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    try {
      if (isOpen) {
        await backend.coverClose(deviceId);
      } else {
        await backend.coverOpen(deviceId);
      }
      if (mounted &&
          identical(ref.read(backendProvider), backend) &&
          ref.read(coverCalibratorStateProvider).deviceId == deviceId) {
        ref
            .read(coverCalibratorStateProvider.notifier)
            .updateCoverStatus(CoverStatus.moving);
        ref.invalidate(equipmentCoverCalibratorCapabilitiesProvider(deviceId));
        context.showSuccessSnackBar(isOpen ? 'Closing cover' : 'Opening cover');
      }
    } catch (e) {
      if (mounted && identical(ref.read(backendProvider), backend)) {
        context.showErrorSnackBar('Cover operation failed: $e');
      }
    } finally {
      _finishCoverCalibratorCommand(revision, backend);
    }
  }

  Future<void> _handleCalibratorToggle({
    required bool isOn,
    required int? brightness,
    required int maxBrightness,
  }) async {
    final state = ref.read(coverCalibratorStateProvider);
    final deviceId = state.deviceId;
    if (deviceId == null ||
        state.connectionState != DeviceConnectionState.connected) {
      return;
    }
    final revision = _beginCoverCalibratorCommand();
    if (revision == null) return;
    final backend = ref.read(backendProvider);
    try {
      if (isOn) {
        await backend.calibratorOff(deviceId);
        if (mounted &&
            identical(ref.read(backendProvider), backend) &&
            ref.read(coverCalibratorStateProvider).deviceId == deviceId) {
          ref
              .read(coverCalibratorStateProvider.notifier)
              .updateCalibratorStatus(CalibratorStatus.off);
          ref.invalidate(
            equipmentCoverCalibratorCapabilitiesProvider(deviceId),
          );
          context.showSuccessSnackBar('Calibrator light off');
        }
      } else {
        if (maxBrightness <= 0) {
          throw StateError('The driver did not report a usable brightness');
        }
        final target = brightness != null && brightness > 0
            ? brightness.clamp(1, maxBrightness).toInt()
            : maxBrightness > 0
                ? (maxBrightness / 2).round().clamp(1, maxBrightness).toInt()
                : 1;
        await backend.calibratorOn(deviceId, target);
        if (mounted &&
            identical(ref.read(backendProvider), backend) &&
            ref.read(coverCalibratorStateProvider).deviceId == deviceId) {
          final notifier = ref.read(coverCalibratorStateProvider.notifier);
          notifier.updateBrightness(target);
          notifier.updateCalibratorStatus(CalibratorStatus.notReady);
          ref.invalidate(
            equipmentCoverCalibratorCapabilitiesProvider(deviceId),
          );
          context.showSuccessSnackBar(
            'Calibrator light requested at brightness $target',
          );
        }
      }
    } catch (e) {
      if (mounted && identical(ref.read(backendProvider), backend)) {
        context.showErrorSnackBar('Calibrator operation failed: $e');
      }
    } finally {
      _finishCoverCalibratorCommand(revision, backend);
    }
  }
}

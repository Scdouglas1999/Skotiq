part of '../connected_device_card.dart';

extension _ConnectedDeviceCommandHandlers on _ConnectedDeviceCardState {
  /// Re-read the cover/calibrator after a command so the card shows what the
  /// device now reports; the host's poll and the runtime channel keep it
  /// current after that.
  void _refreshCoverCalibrator(String deviceId) {
    unawaited(
      refreshCoverCalibratorSnapshot(
        ProviderScope.containerOf(context, listen: false),
        deviceId,
      ).catchError((Object _) {
        return null;
      }),
    );
  }

  Future<void> _handleDisconnect() async {
    // Disconnecting a camera whose TEC is still active cuts cooler power
    // abruptly — gate with the shared cooled-camera confirm. Confirm BEFORE
    // _beginDeviceCommand so the card is not held busy while the dialog is up.
    if (widget.type == DeviceType.camera) {
      final proceed = await confirmDisconnectCooledCamera(context, ref);
      if (!proceed || !mounted) return;
    }
    final command = _beginDeviceCommand();
    if (command == null) return;
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = _currentCardDeviceId();
    try {
      await deviceService.disconnect(widget.type);
    } catch (e) {
      if (mounted && _isCurrentDevice(command, deviceId)) {
        context.showErrorSnackBar('Failed to disconnect: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
    }
  }

  Future<void> _handleCoolCamera(double targetTemp) async {
    final command = _beginDeviceCommand();
    if (command == null) return;
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = ref.read(cameraStateProvider).deviceId;
    deviceService.cancelWarmCamera(restorePriorSetting: false);
    try {
      await deviceService.setCameraCooling(
          enabled: true, targetTemp: targetTemp);
      if (mounted && _isCurrentDevice(command, deviceId)) {
        context.showSuccessSnackBar(
            'Cooling to ${formatCelsius(targetTemp, decimals: 0)}');
      }
    } catch (e) {
      if (mounted && _isCurrentDevice(command, deviceId)) {
        context.showErrorSnackBar('Failed to start cooling: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
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

    await showHostBoundDialog<void>(
      context: context,
      ref: ref,
      builder: (ctx, host) {
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
                          deviceService.cancelWarmCamera(
                              restorePriorSetting: false);
                          await deviceService.setCameraCooling(
                              enabled: true, targetTemp: temp);
                          if (!context.mounted || host.isStale) return;
                          ref
                              .read(cameraStateProvider.notifier)
                              .setTargetTemp(temp);
                          Navigator.pop(context);
                          if (pageContext.mounted) {
                            pageContext.showSuccessSnackBar(
                                'Cooling to ${formatCelsius(temp, decimals: 0)}');
                          }
                        } catch (e) {
                          if (!context.mounted || host.isStale) return;
                          setState(() {
                            isSaving = false;
                            errorText = 'Failed to start cooling: ${userFacingError(e)}';
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
                    labelText: 'Target temperature (°C)',
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
    final command = _beginDeviceCommand();
    if (command == null) return;
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = ref.read(cameraStateProvider).deviceId;
    try {
      final outcome = await deviceService.warmCamera();
      if (mounted && _isCurrentDevice(command, deviceId)) {
        final message = warmupOutcomeMessage(outcome);
        if (message != null) context.showSuccessSnackBar(message);
      }
    } catch (e) {
      if (mounted && _isCurrentDevice(command, deviceId)) {
        context.showErrorSnackBar('Failed to warm up: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
    }
  }

  void _handleCancelWarm() {
    final deviceService = ref.read(deviceServiceProvider);
    deviceService.cancelWarmCamera();
    if (mounted) {
      context.showSuccessSnackBar(
          'Warm-up canceled; the cooler goes back to its previous set-point');
    }
  }

  Future<void> _handleTogglePark() async {
    final command = _beginMountCommand();
    if (command == null) return;
    final mountService = ref.read(mountCommandServiceProvider);
    try {
      final result = await mountService.togglePark();
      if (mounted && command.isCurrent) {
        context.showCommandActionResult(result);
      }
    } finally {
      _finishCommand(command);
    }
  }

  Future<void> _handleFindHome() async {
    final command = _beginMountCommand();
    if (command == null) return;
    final mountService = ref.read(mountCommandServiceProvider);
    try {
      final result = await mountService.findHome();
      if (mounted && command.isCurrent) {
        context.showCommandActionResult(result);
      }
    } finally {
      _finishCommand(command);
    }
  }

  Future<void> _handleToggleTracking(bool currentlyTracking) async {
    final command = _beginMountCommand();
    if (command == null) return;
    final mountService = ref.read(mountCommandServiceProvider);
    try {
      final result = await mountService.setTracking(!currentlyTracking);
      if (mounted && command.isCurrent) {
        context.showCommandActionResult(result);
      }
    } finally {
      _finishCommand(command);
    }
  }

  /// Manually trigger a meridian flip now (outside the sequencer's automatic
  /// watchdog). Flips and re-points to the mount's current sky position. The
  /// manual path a remote operator needs when stalled at the meridian.
  Future<void> _handleManualMeridianFlip() async {
    final command = _beginMountCommand();
    if (command == null) return;
    try {
      final confirmed = await showHostBoundDialog<bool>(
        context: context,
        ref: ref,
        builder: (ctx, _) => SkotiqDialog(
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
          command.isStale) {
        return;
      }

      final succeeded = await ref
          .read(meridianFlipStandaloneMonitorProvider.notifier)
          .executeNow();
      if (!mounted ||
          command.isStale) {
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
      _finishCommand(command);
    }
  }

  Future<void> _handleFilterChange(int position) async {
    final command = _beginDeviceCommand();
    if (command == null) return;
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = ref.read(filterWheelStateProvider).deviceId;
    try {
      await deviceService.setFilterWheelPosition(position);
    } catch (e) {
      if (mounted && _isCurrentDevice(command, deviceId)) {
        context.showErrorSnackBar('Failed to change filter: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
    }
  }

  Future<void> _handleToggleGuiding(bool currentlyGuiding) async {
    final command = _beginDeviceCommand();
    if (command == null) return;
    final guider = ref.read(phd2ControllerProvider);
    final deviceId = ref.read(guiderStateProvider).deviceId;
    try {
      if (currentlyGuiding) {
        await guider.stopGuiding();
        if (mounted && _isCurrentDevice(command, deviceId)) {
          context.showSuccessSnackBar('Guiding stopped');
        }
      } else {
        await guider.startGuiding();
        if (mounted && _isCurrentDevice(command, deviceId)) {
          context.showSuccessSnackBar('Guiding started');
        }
      }
    } catch (e) {
      if (mounted && _isCurrentDevice(command, deviceId)) {
        context.showErrorSnackBar('Guiding operation failed: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
    }
  }

  String? _currentCardDeviceId() =>
      ref.read(widget.type.slot.state).deviceId;

  /// [command] is still the card's and the card still shows the device it was
  /// sent to.
  bool _isCurrentDevice(AsyncScope<SkotiqBackend> command, String? deviceId) =>
      command.isCurrent && _currentCardDeviceId() == deviceId;

  bool _isCurrentDome(AsyncScope<SkotiqBackend> command, String deviceId) =>
      command.isCurrent && ref.read(domeStateProvider).deviceId == deviceId;

  bool _isCurrentCoverCalibrator(
    AsyncScope<SkotiqBackend> command,
    String deviceId,
  ) =>
      command.isCurrent &&
      ref.read(coverCalibratorStateProvider).deviceId == deviceId;

  /// Dome commands go through the shared device command path, which re-reads
  /// the dome after each one so the card reflects it at once (the readouts
  /// otherwise move only on the 5 s poll), the same for a command a linked
  /// client sends.
  DeviceCommands get _deviceCommands => ref.read(deviceCommandsProvider);

  Future<void> _handleDomeShutter(ShutterStatus currentStatus) async {
    final domeState = ref.read(domeStateProvider);
    final deviceId = domeState.deviceId;
    if (deviceId == null) return;
    final command = _beginDomeCommand();
    if (command == null) return;
    try {
      if (currentStatus == ShutterStatus.open) {
        await _deviceCommands.domeCloseShutter(deviceId);
      } else {
        await _deviceCommands.domeOpenShutter(deviceId);
      }
      if (mounted && _isCurrentDome(command, deviceId)) {
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
      if (mounted && _isCurrentDome(command, deviceId)) {
        context.showErrorSnackBar('Dome shutter operation failed: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
    }
  }

  Future<void> _handleDomePark() async {
    final domeState = ref.read(domeStateProvider);
    final deviceId = domeState.deviceId;
    if (deviceId == null || domeState.isParked) return;
    final command = _beginDomeCommand();
    if (command == null) return;
    try {
      await _deviceCommands.domePark(deviceId);
      if (mounted && _isCurrentDome(command, deviceId)) {
        context.showSuccessSnackBar('Parking dome');
      }
    } catch (e) {
      if (mounted && _isCurrentDome(command, deviceId)) {
        context.showErrorSnackBar('Dome park operation failed: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
    }
  }

  Future<void> _handleDomeHome() async {
    final domeState = ref.read(domeStateProvider);
    final deviceId = domeState.deviceId;
    if (deviceId == null) return;
    final command = _beginDomeCommand();
    if (command == null) return;
    try {
      await _deviceCommands.domeFindHome(deviceId);
      if (mounted && _isCurrentDome(command, deviceId)) {
        context.showSuccessSnackBar('Homing dome');
      }
    } catch (e) {
      if (mounted && _isCurrentDome(command, deviceId)) {
        context.showErrorSnackBar('Dome home failed: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
    }
  }

  Future<void> _handleDomeHalt() async {
    final domeState = ref.read(domeStateProvider);
    final deviceId = domeState.deviceId;
    if (deviceId == null) return;
    final command = _beginDomeCommand();
    if (command == null) return;
    try {
      await _deviceCommands.domeAbortSlew(deviceId);
      if (mounted && _isCurrentDome(command, deviceId)) {
        context.showSuccessSnackBar('Stopping dome');
      }
    } catch (e) {
      if (mounted && _isCurrentDome(command, deviceId)) {
        context.showErrorSnackBar('Dome halt failed: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
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

  Future<void> _handleCoverToggle(bool isOpen) async {
    final coverState = ref.read(coverCalibratorStateProvider);
    final deviceId = coverState.deviceId;
    if (deviceId == null ||
        coverState.connectionState != DeviceConnectionState.connected) {
      return;
    }
    final command = _beginCoverCalibratorCommand();
    if (command == null) return;
    try {
      if (isOpen) {
        await command.value.coverClose(deviceId);
      } else {
        await command.value.coverOpen(deviceId);
      }
      if (mounted && _isCurrentCoverCalibrator(command, deviceId)) {
        ref
            .read(coverCalibratorStateProvider.notifier)
            .updateCoverStatus(CoverStatus.moving);
        _refreshCoverCalibrator(deviceId);
        context.showSuccessSnackBar(isOpen ? 'Closing cover' : 'Opening cover');
      }
    } catch (e) {
      if (mounted && command.isCurrent) {
        context.showErrorSnackBar('Cover operation failed: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
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
    final command = _beginCoverCalibratorCommand();
    if (command == null) return;
    try {
      if (isOn) {
        await command.value.calibratorOff(deviceId);
        if (mounted && _isCurrentCoverCalibrator(command, deviceId)) {
          ref
              .read(coverCalibratorStateProvider.notifier)
              .updateCalibratorStatus(CalibratorStatus.off);
          _refreshCoverCalibrator(deviceId);
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
        await command.value.calibratorOn(deviceId, target);
        if (mounted && _isCurrentCoverCalibrator(command, deviceId)) {
          final notifier = ref.read(coverCalibratorStateProvider.notifier);
          notifier.updateBrightness(target);
          notifier.updateCalibratorStatus(CalibratorStatus.notReady);
          _refreshCoverCalibrator(deviceId);
          context.showSuccessSnackBar(
            'Calibrator light requested at brightness $target',
          );
        }
      }
    } catch (e) {
      if (mounted && command.isCurrent) {
        context.showErrorSnackBar('Calibrator operation failed: ${userFacingError(e)}');
      }
    } finally {
      _finishCommand(command);
    }
  }
}

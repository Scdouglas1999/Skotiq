// RMS formatting, state mapping, guider commands and guiding-settings persistence.
part of '../guiding_screen.dart';

mixin _GuidingActions on ConsumerState<GuidingScreen>, _GuidingStateFields {
  Color _getSnrColor(double snr, SkotiqColors colors) {
    // A real star measurement is strictly positive. Zero means "no star has
    // been measured", which is not an alarm — painting it error-red made an
    // idle guider look like it had just lost the star.
    if (snr <= 0) return colors.textMuted;
    if (snr >= 10) return colors.success;
    if (snr >= 5) return colors.warning;
    return colors.error;
  }

  /// Copy for the guide-star preview while [starImageProvider] holds no image.
  ///
  /// The notifier only polls while the guider is looping / guiding /
  /// calibrating and otherwise sits in `AsyncValue.loading()`, so an idle
  /// guider is not waiting for anything. Say what is actually true, and what
  /// the user has to do next.
  String _starViewIdleMessage() {
    final phd2State = ref.watch(phd2StateProvider);
    final isAcquiring = phd2State == Phd2State.looping ||
        phd2State == Phd2State.guiding ||
        phd2State == Phd2State.calibrating ||
        phd2State == Phd2State.settling;
    if (isAcquiring) return 'Waiting for image...';
    if (ref.watch(guiderStateProvider).connectionState !=
        DeviceConnectionState.connected) {
      return 'Connect a guider to acquire a guide star';
    }
    return 'Press Loop Exposures or Start to acquire a guide star';
  }

  /// SNR / star-mass readouts share the "positive means measured" rule: the
  /// guider only reports them once it has actually measured a star, so a 0 is
  /// an absence of data. Returning null lets [Readout] render the one em dash
  /// the sheet allows instead of an invented placeholder string.
  String? _starMetricValue(double value, {int decimals = 1}) =>
      value > 0 ? value.toStringAsFixed(decimals) : null;

  /// A calibration angle for a [Readout]; null when PHD2 has not reported one.
  String? _angleValue(double? degrees) => degrees?.toStringAsFixed(1);

  /// A calibration rate for a [Readout]; null when PHD2 has not reported one.
  String? _rateValue(double? rate) => rate?.toStringAsFixed(2);

  /// The `Frame Count` readout, which counts whichever frames the guider is
  /// currently taking.
  ///
  /// Looping takes no corrections, so `frameCount` — a count of guide STEPS —
  /// sat at `0` for the whole of a Loop Exposures run while the SNR and Star
  /// Mass rows directly above it updated per loop frame; all three read as
  /// describing the same frames, so one of them was lying. While looping the
  /// row reports the loop's own frames, counted from one per loop.
  String _frameCountText(Phd2GuideStats stats, Phd2State phd2State) =>
      phd2State == Phd2State.looping
          ? stats.loopFrameCount.toString()
          : stats.frameCount.toString();

  /// The chip tone for a guider state (05 §10: status colours mean status).
  ChipTone _getStateTone(Phd2State state) {
    switch (state) {
      case Phd2State.guiding:
        return ChipTone.success;
      case Phd2State.looping:
      case Phd2State.calibrating:
      case Phd2State.unknown:
        return ChipTone.warning;
      case Phd2State.paused:
      case Phd2State.settling:
        return ChipTone.primary;
      case Phd2State.lostLock:
        return ChipTone.error;
      case Phd2State.stopped:
      case Phd2State.selected:
        return ChipTone.neutral;
    }
  }

  /// The connected guider, or the active profile's guider while none is
  /// connected.
  String? _selectedGuiderId() {
    final live = ref.watch(guiderStateProvider).deviceId;
    if (live != null) return live;
    final profileGuider =
        ref.watch(activeProfileProvider).valueOrNull?.guiderId?.trim();
    return (profileGuider == null || profileGuider.isEmpty)
        ? null
        : profileGuider;
  }

  /// The one muted fact beside the page title: which guider, connected or not.
  String _connectionLabel(bool isConnected) {
    final guiderState = ref.watch(guiderStateProvider);
    final guiderId = _selectedGuiderId();
    final isPhd2Guider = guiderId == null || isPhd2DeviceId(guiderId);
    final isBuiltinGuider = guiderId == builtinGuiderDeviceId;
    final name = isBuiltinGuider
        ? 'Built-in guider'
        : isPhd2Guider
            ? 'PHD2'
            : (guiderState.deviceName ?? 'Guider');
    return isConnected ? '$name connected' : '$name disconnected';
  }

  String _getStateLabel(Phd2State state) {
    switch (state) {
      case Phd2State.stopped:
        return 'Stopped';
      case Phd2State.selected:
        return 'Star selected';
      case Phd2State.looping:
        return 'Looping';
      case Phd2State.calibrating:
        return 'Calibrating';
      case Phd2State.guiding:
        return 'Guiding';
      case Phd2State.paused:
        return 'Paused';
      case Phd2State.settling:
        return 'Settling';
      case Phd2State.lostLock:
        return 'Lost lock';
      case Phd2State.unknown:
        return 'Unknown';
    }
  }

  Phd2GuidingState _mapPhd2State(Phd2State state) {
    switch (state) {
      case Phd2State.stopped:
      // "Selected" is connected + a star chosen but not yet guiding — the same
      // idle-but-ready surface as Stopped (Start is legal), NOT disconnected.
      case Phd2State.selected:
        return Phd2GuidingState.stopped;
      case Phd2State.looping:
        return Phd2GuidingState.looping;
      case Phd2State.calibrating:
        return Phd2GuidingState.calibrating;
      case Phd2State.guiding:
        return Phd2GuidingState.guiding;
      case Phd2State.paused:
        return Phd2GuidingState.paused;
      case Phd2State.settling:
        return Phd2GuidingState.settling;
      case Phd2State.lostLock:
        return Phd2GuidingState.lostLock;
      case Phd2State.unknown:
        return Phd2GuidingState.unknown;
    }
  }

  void _showConnectionDialog() {
    Phd2ConnectionDialog.show(context, ref);
  }

  /// Connect the profile's guider when it is not PHD2 (the built-in guider or
  /// a camera guider); PHD2 has its own connect path.
  Future<void> _connectProfileGuider(String guiderId) async {
    try {
      await ref.read(deviceServiceProvider).connectDeviceGuider(
            guiderId,
            guideCameraId: ref.read(profileGuiderProvider).guideCameraId,
          );
    } catch (e) {
      _showActionError('Failed to connect the guider: $e');
    }
  }

  Future<void> _disconnectActiveGuider() async {
    final hostScope = ref.backendScope();
    final guiderId = ref.read(guiderStateProvider).deviceId;
    try {
      await ref.read(deviceServiceProvider).disconnect(DeviceType.guider);
      if (!mounted) return;
      if (hostScope.isStale) {
        _showActionError(
          'The imaging host changed while disconnecting the guider. '
          'Check Equipment before continuing.',
        );
      }
    } catch (e) {
      _showActionError(
        'Failed to disconnect ${guiderId ?? 'the active guider'}: $e',
      );
    }
  }

  /// Select the guide star at a tapped image position. The star view invokes
  /// this fire-and-forget, so the RPC failure is surfaced here — a rejected
  /// lock-position command would otherwise leave the tap silently doing
  /// nothing.
  Future<void> _selectStar(double x, double y) async {
    try {
      await ref.read(lockPositionProvider.notifier).setLockPosition(x, y);
    } catch (e) {
      _showActionError('Could not select the guide star: $e');
    }
  }

  /// Auto Select: ask the guider to pick a guide star, and SAY what happened.
  ///
  /// Returns the outcome for the panel's own inline notice banner. Two earlier
  /// attempts at this reported through a snackbar, and a live drive that
  /// clicked Auto Select three times still found "no notice, no toast, no
  /// status text anywhere in the a11y tree": the app-shell snackbar had
  /// already timed out by the time the screen was read. The banner is part of
  /// the panel and stays until dismissed. A failure still propagates to the
  /// panel's inline error banner.
  Future<String?> _autoSelectStar() async {
    final logger = ref.read(loggingServiceProvider);
    logger.info('Auto Select: asking the guider to pick a guide star',
        source: 'Guiding');
    await ref.read(lockPositionProvider.notifier).findStar();
    final position = ref.read(lockPositionProvider);
    if (position == null) {
      logger.warning(
        'Auto Select: the guider reported no guide star',
        source: 'Guiding',
      );
      return 'Auto Select found no guide star — try a longer guide exposure '
          'or a different part of the sky.';
    }
    final where =
        '(${position.x.toStringAsFixed(1)}, ${position.y.toStringAsFixed(1)})';
    logger.info('Auto Select: guide star selected at $where px',
        source: 'Guiding');
    return 'Guide star selected at $where';
  }

  /// Deselect the guide star. Returns the controller Future so the awaiting
  /// caller (GuideControlsPanel's `_runAction`) surfaces a rejected RPC — e.g. a
  /// mid-flight host change — instead of the failure escaping as an unhandled
  /// Future. Discarding it here left a Deselect tap silently failing.
  Future<void> _deselectStar() =>
      ref.read(lockPositionProvider.notifier).deselectStar();

  /// Surface a guiding action failure inline instead of letting it escape as an
  /// unhandled Future (calibration ops issue real PHD2 RPCs that can fail).
  void _showActionError(String message) {
    if (!mounted) return;
    context.showErrorSnackBar(message);
  }

  Future<void> _clearCalibration() async {
    final hostScope = ref.backendScope();
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Clear calibration?',
      message: 'This discards PHD2\'s current calibration. You will need to '
          'recalibrate before guiding is reliable again.',
      confirmLabel: 'Clear',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    if (hostScope.isStale) {
      _showActionError(
        'The connected imaging host changed. Calibration was not cleared.',
      );
      return;
    }
    try {
      await ref.read(calibrationStateProvider.notifier).clearCalibration();
    } catch (e) {
      _showActionError('Failed to clear calibration: $e');
    }
  }

  Future<void> _flipCalibration() async {
    try {
      await ref.read(calibrationStateProvider.notifier).flipCalibration();
    } catch (e) {
      _showActionError('Failed to flip calibration: $e');
    }
  }
}

// RMS formatting, state mapping, guider commands and guiding-settings persistence.
part of '../guiding_screen.dart';

mixin _GuidingActions on ConsumerState<GuidingScreen>, _GuidingStateFields {
  /// PHD2 reports guide residuals in pixels (RADistanceRaw/AvgDist). When a
  /// pixel scale (arcsec/px) is known we present arcseconds; otherwise we show
  /// the raw pixel value labelled "px" rather than mislabelling it as arcsec.
  ({double value, String unit}) _rmsReadout(double raw, double pixelScale) {
    if (pixelScale > 0) return (value: raw * pixelScale, unit: '"');
    return (value: raw, unit: ' px');
  }

  /// Pull a human-readable message out of whatever the brain-params fetch
  /// threw. `StateError` (our explicit empty-dump guard) carries a clean
  /// sentence; everything else falls back to its string form.
  String _brainErrorMessage(Object error) {
    if (error is StateError) return error.message;
    return error.toString();
  }

  Color _getSnrColor(double snr, SkotiqColors colors) {
    // A real star measurement is strictly positive. Zero means "no star has
    // been measured", which is not an alarm — painting it error-red made an
    // idle guider look like it had just lost the star.
    if (snr <= 0) return colors.textMuted;
    if (snr >= 10) return colors.success;
    if (snr >= 5) return colors.warning;
    return colors.error;
  }

  /// Per-frame guide error, converted for display the same way the RMS
  /// readouts are. The guider reports residuals in guide-camera pixels while
  /// the graph and bullseye axes are arcseconds, so at a typical 2-4"/px guide
  /// scale the raw pixels understate the real error several-fold.
  double _errorForDisplay(double px, double pixelScale) =>
      pixelScale > 0 ? px * pixelScale : px;

  /// Unit suffix matching [_errorForDisplay].
  String _errorUnit(double pixelScale) => pixelScale > 0 ? '"' : ' px';

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

  /// The one muted fact beside the page title: which guider, connected or not.
  String _connectionLabel(bool isConnected) {
    final guiderState = ref.watch(guiderStateProvider);
    final guiderId = guiderState.deviceId;
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

  Future<void> _disconnectActiveGuider() async {
    final backend = ref.read(backendProvider);
    final guiderId = ref.read(guiderStateProvider).deviceId;
    try {
      await ref.read(deviceServiceProvider).disconnectGuider();
      if (!mounted) return;
      if (!identical(backend, ref.read(backendProvider))) {
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
    final colors = SkotiqColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: colors.error),
    );
  }

  Future<void> _clearCalibration() async {
    final backend = ref.read(backendProvider);
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Clear calibration?',
      message: 'This discards PHD2\'s current calibration. You will need to '
          'recalibrate before guiding is reliable again.',
      confirmLabel: 'Clear',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    if (!identical(backend, ref.read(backendProvider))) {
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

  // Settle / dither persistence — canonical AppSettings authority (defect 5)
  //
  // The screen owns no independent settle/dither store: it seeds its live cache
  // from the persisted settings once, then writes every edit straight back
  // through the AppSettings notifier so values persist across navigation AND
  // full reconstruction, and remote companions share the same canonical sync.

  /// Seed the settle/dither controls from the persisted authority exactly once
  /// per screen instance. Values are clamped to the control ranges so a
  /// corrupt/out-of-range stored value can never push a slider off its track.
  void _hydrateGuidingSettings(AppSettingsState settings) {
    if (_guidingSettingsHydrated) return;
    _guidingSettingsHydrated = true;
    _settlePixels = settings.settleThreshold.clamp(0.5, 5.0).toDouble();
    _settleTimeout = settings.settleTimeout.toDouble().clamp(30.0, 180.0);
    _settleTime = settings.settleTime.toDouble().clamp(5.0, 60.0);
    _ditherAmount = _ditherScaleToPixels(settings.ditherScale).clamp(1.0, 20.0);
    _ditherRaOnly = settings.ditherRaOnly;
  }

  void _setSettlePixels(double value) {
    final clamped = value.clamp(0.5, 5.0).toDouble();
    final rollback = _settlePixels;
    setState(() => _settlePixels = clamped);
    unawaited(_persistSettlePixels(clamped, rollback));
  }

  Future<void> _persistSettlePixels(double value, double rollback) async {
    final clamped = value.clamp(0.5, 5.0).toDouble();
    final current = ref.read(appSettingsProvider).valueOrNull?.settleThreshold;
    if (current != null && (current - clamped).abs() < 0.0001) return;
    try {
      await ref.read(appSettingsProvider.notifier).setSettleThreshold(clamped);
    } catch (error) {
      if (!mounted) return;
      if ((_settlePixels - clamped).abs() < 0.0001) {
        final authoritative =
            ref.read(appSettingsProvider).valueOrNull?.settleThreshold;
        setState(
            () => _settlePixels = (authoritative ?? rollback).clamp(0.5, 5.0));
      }
      _showActionError('Could not save the settle threshold: $error');
    }
  }

  void _setSettleTimeout(double value) {
    final clamped = value.clamp(30.0, 180.0).toDouble();
    final rollback = _settleTimeout;
    setState(() => _settleTimeout = clamped);
    unawaited(_persistSettleTimeout(clamped, rollback));
  }

  Future<void> _persistSettleTimeout(double value, double rollback) async {
    final clamped = value.clamp(30.0, 180.0).round();
    final current = ref.read(appSettingsProvider).valueOrNull?.settleTimeout;
    if (current == clamped) return;
    try {
      await ref.read(appSettingsProvider.notifier).setSettleTimeout(clamped);
    } catch (error) {
      if (!mounted) return;
      if ((_settleTimeout - clamped).abs() < 0.0001) {
        final authoritative =
            ref.read(appSettingsProvider).valueOrNull?.settleTimeout;
        setState(
          () => _settleTimeout =
              (authoritative?.toDouble() ?? rollback).clamp(30.0, 180.0),
        );
      }
      _showActionError('Could not save the settle timeout: $error');
    }
  }

  void _setSettleTime(double value) {
    final clamped = value.clamp(5.0, 60.0).toDouble();
    final rollback = _settleTime;
    setState(() => _settleTime = clamped);
    unawaited(_persistSettleTime(clamped, rollback));
  }

  Future<void> _persistSettleTime(double value, double rollback) async {
    final clamped = value.clamp(5.0, 60.0).round();
    final current = ref.read(appSettingsProvider).valueOrNull?.settleTime;
    if (current == clamped) return;
    try {
      await ref.read(appSettingsProvider.notifier).setSettleTime(clamped);
    } catch (error) {
      if (!mounted) return;
      if ((_settleTime - clamped).abs() < 0.0001) {
        final authoritative =
            ref.read(appSettingsProvider).valueOrNull?.settleTime;
        setState(
          () => _settleTime =
              (authoritative?.toDouble() ?? rollback).clamp(5.0, 60.0),
        );
      }
      _showActionError('Could not save the settle time: $error');
    }
  }

  void _setDitherRaOnly(bool value) {
    final rollback = _ditherRaOnly;
    setState(() => _ditherRaOnly = value);
    unawaited(_persistDitherRaOnly(value, rollback));
  }

  Future<void> _persistDitherRaOnly(bool value, bool rollback) async {
    final current = ref.read(appSettingsProvider).valueOrNull?.ditherRaOnly;
    if (current == value) return;
    try {
      await ref.read(appSettingsProvider.notifier).setDitherRaOnly(value);
    } catch (error) {
      if (!mounted) return;
      if (_ditherRaOnly == value) {
        final authoritative =
            ref.read(appSettingsProvider).valueOrNull?.ditherRaOnly;
        setState(() => _ditherRaOnly = authoritative ?? rollback);
      }
      _showActionError('Could not save the dither RA-only setting: $error');
    }
  }

  void _setDitherAmount(double pixels) {
    final clamped = pixels.clamp(1.0, 20.0).toDouble();
    final rollback = _ditherAmount;
    setState(() => _ditherAmount = clamped);
    unawaited(_persistDitherScale(clamped, rollback));
  }

  Future<void> _persistDitherScale(double pixels, double rollback) async {
    final scale = _pixelsToDitherScale(pixels);
    final current = ref.read(appSettingsProvider).valueOrNull?.ditherScale;
    if (current == scale) return;
    try {
      await ref.read(appSettingsProvider.notifier).setDitherScale(scale);
    } catch (error) {
      if (!mounted) return;
      if ((_ditherAmount - pixels).abs() < 0.0001) {
        final authoritative =
            ref.read(appSettingsProvider).valueOrNull?.ditherScale;
        setState(
          () => _ditherAmount = authoritative == null
              ? rollback
              : _ditherScaleToPixels(authoritative),
        );
      }
      _showActionError('Could not save the dither amount: $error');
    }
  }

  /// Canonical AppSettings stores dither strength as a coarse Small/Medium/Large
  /// bucket; the slider works in pixels. These two helpers are the single,
  /// documented bridge between the two representations.
  static double _ditherScaleToPixels(String scale) {
    switch (scale) {
      case 'Small':
        return 2.0;
      case 'Large':
        return 10.0;
      case 'Medium':
      default:
        return 5.0;
    }
  }

  static String _pixelsToDitherScale(double pixels) {
    if (pixels < 3.5) return 'Small';
    if (pixels < 7.5) return 'Medium';
    return 'Large';
  }
}

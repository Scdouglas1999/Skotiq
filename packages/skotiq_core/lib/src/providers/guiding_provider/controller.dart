part of '../guiding_provider.dart';

/// Controller to manage PHD2 connection and state updates
final phd2ControllerProvider = Provider<Phd2Controller>((ref) {
  final backend = ref.watch(backendProvider);
  final controller = Phd2Controller(ref, backend);
  ref.onDispose(() => controller.dispose());
  return controller;
});

/// Serialises guiding commands issued through [Phd2Controller] so a double-tap
/// — or a UI command racing a programmatic one — cannot fire the same native
/// call twice or leave a late Start active after the user pressed Stop. Stop is
/// issued immediately to interrupt settling, then issued once more after any
/// in-flight positive command drains. That final stop is the ordering fence:
/// even if the first stop reached the host before Start did, the terminal
/// command observed by PHD2 is still Stop.
class _GuidingCommandGate {
  bool _positiveInFlight = false;
  bool _stopInFlight = false;
  Future<void>? _positiveDrain;

  /// True when any command currently holds a slot (used by the UI to stay busy
  /// until the command is accepted or fails).
  bool get isBusy => _positiveInFlight || _stopInFlight;

  Future<T> runPositive<T>(String command, Future<T> Function() action) async {
    if (_positiveInFlight || _stopInFlight) {
      throw GuidingCommandBusyException(command);
    }
    _positiveInFlight = true;
    final operation = Future<T>.sync(action);
    final drain = operation.then<void>((_) {}, onError: (_, __) {});
    _positiveDrain = drain;
    try {
      return await operation;
    } finally {
      _positiveInFlight = false;
      if (identical(_positiveDrain, drain)) _positiveDrain = null;
    }
  }

  Future<T> runStop<T>(String command, Future<T> Function() action) async {
    if (_stopInFlight) {
      throw GuidingCommandBusyException(command);
    }
    _stopInFlight = true;
    try {
      final positive = _positiveDrain;
      final firstResult = await action();
      if (positive != null) {
        await positive;
        return await action();
      }
      return firstResult;
    } finally {
      _stopInFlight = false;
    }
  }
}

class Phd2Controller {
  final Ref ref;
  final SkotiqBackend backend;
  StreamSubscription? _eventSub;
  bool _disposed = false;
  final DateTime Function() _now;
  DateTime? _lastStarLossWarning;
  DateTime? _stableGuidingSince;
  bool _starLossActive = false;
  bool _relaunchInFlight = false;

  /// A single physical link loss can produce more than one Disconnected event:
  /// PHD2 reports the socket loss, then our backend cleanup publishes its own
  /// terminal event.  Treat those as one episode so cleanup cannot feed its
  /// own event back into another cleanup forever.
  bool _linkLossHandled = false;

  /// Set true by an explicit user [disconnect]; stays true until the user
  /// explicitly [connect]s again. While set, the crash-relaunch path refuses
  /// to bring PHD2 back — a deliberate disconnect must stay disconnected even
  /// after the reconnect coordinator's short user-disconnect debounce expires
  /// (the relaunch backoff outlives that 10 s window, so the debounce alone is
  /// not authoritative).
  bool _userDisconnectRequested = false;

  /// Cancellable backoff between relaunch attempts so an explicit Disconnect
  /// can wake the sleeping loop immediately instead of waiting out the delay.
  Timer? _relaunchTimer;
  Completer<void>? _relaunchWake;

  /// Shared connect future. Duplicate callers join the same outcome instead of
  /// receiving an immediate apparent success while the first attempt may fail.
  Future<void>? _connectOperation;

  /// Whether a user-initiated connect is currently running. Surfaced so the UI
  /// can show a truthful "Connecting…" busy affordance and disable the
  /// Connect/Disconnect controls until it resolves (connect is not abortable
  /// mid-flight, so both must wait it out).
  bool get isConnecting => _connectOperation != null;

  final _GuidingCommandGate _commandGate = _GuidingCommandGate();

  LoggingService get _logger => ref.read(loggingServiceProvider);

  /// Whether a UI-issued guiding command is currently in flight. Surfaced so
  /// controls can stay busy/disabled until the command is accepted or fails.
  bool get isCommandInFlight => _commandGate.isBusy;

  /// Escalating waits between crash-relaunch attempts. The first is short
  /// (PHD2 restarting after a transient crash), the later ones give a
  /// wedged host time to recover. Bounded so a permanently broken setup
  /// (uninstalled PHD2, dead remote host) does not loop all night.
  static const List<Duration> _relaunchDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  Phd2Controller(this.ref, this.backend, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _init();
  }

  /// PHD2 closed externally (EOF) or bridge published [Disconnected].
  void _handlePhd2LinkLost() {
    _resetStarLoss();
    ref.read(phd2StateProvider.notifier).state = Phd2State.stopped;
    ref.read(guiderStateProvider.notifier).setDisconnected();

    if (_linkLossHandled) return;
    _linkLossHandled = true;

    // An explicit Disconnect already owns backend teardown. For an unexpected
    // loss, clear stale Rust registration/storage exactly once; that cleanup
    // may itself publish Disconnected, which the episode latch above absorbs.
    if (!_userDisconnectRequested) {
      unawaited(_syncPhd2BackendAfterLinkLost());
    }
    unawaited(_attemptAutoRelaunch());
  }

  /// Crash recovery: the Rust socket layer retries the TCP link, but a
  /// DEAD PHD2 process never re-opens its port — only a relaunch does.
  /// Each attempt routes through [DeviceService.connectGuider], which
  /// re-runs `Phd2Launcher.ensureRunning` (spawn if local + port closed)
  /// before connecting. Skipped entirely for deliberate disconnects and
  /// when auto-reconnect is disabled for the guider.
  Future<void> _attemptAutoRelaunch() async {
    if (_relaunchInFlight || _disposed) return;
    // Deliberate disconnect (durable, and the coordinator's short debounce):
    // never resurrect a guider the user explicitly took down.
    if (_userDisconnectRequested) return;
    final deviceService = ref.read(deviceServiceProvider);
    if (deviceService.isUserInitiatedDisconnect(kPhd2CanonicalId)) {
      return;
    }
    if (!ref.read(guiderStateProvider).autoReconnectEnabled) return;

    _relaunchInFlight = true;
    try {
      for (final delay in _relaunchDelays) {
        await _sleep(delay);
        if (_disposed || _userDisconnectRequested) return;
        final state = ref.read(guiderStateProvider);
        if (state.connectionState == DeviceConnectionState.connected) {
          return; // something else (native retry, user) already recovered
        }
        if (deviceService.isUserInitiatedDisconnect(kPhd2CanonicalId)) {
          return; // user disconnected while we were waiting — respect it
        }
        _logger.warning(
          'PHD2 link lost — attempting automatic relaunch/reconnect…',
          source: 'Phd2Controller',
        );
        try {
          await deviceService.connectGuider(kPhd2CanonicalId);
          _logger.info(
            'PHD2 automatic relaunch/reconnect succeeded',
            source: 'Phd2Controller',
          );
          return;
        } catch (e) {
          _logger.warning(
            'PHD2 auto-relaunch attempt failed: $e',
            source: 'Phd2Controller',
          );
        }
      }
      _logger.error(
        'PHD2 auto-relaunch gave up after ${_relaunchDelays.length} attempts',
        source: 'Phd2Controller',
      );
      if (_disposed) return;
      try {
        ref
            .read(uiNotificationProvider.notifier)
            .showError(
              'PHD2 connection lost and automatic relaunch failed after '
              '${_relaunchDelays.length} attempts. Reconnect the guider '
              'manually.',
              title: 'PHD2',
            );
      } on Object {
        // Notification surface unavailable (headless/teardown) — the log
        // entries above remain the record.
      }
    } finally {
      _relaunchInFlight = false;
    }
  }

  /// Cancellable backoff sleep for the relaunch loop. Completes normally after
  /// [delay], or early when [_cancelRelaunch] fires (user Disconnect / dispose).
  Future<void> _sleep(Duration delay) {
    _relaunchTimer?.cancel();
    final completer = Completer<void>();
    _relaunchWake = completer;
    _relaunchTimer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  /// Wake the relaunch backoff immediately so a pending auto-launch/reconnect
  /// timer is cancelled the moment the user disconnects (the loop then re-reads
  /// [_userDisconnectRequested] and bails).
  void _cancelRelaunch() {
    _relaunchTimer?.cancel();
    _relaunchTimer = null;
    final wake = _relaunchWake;
    _relaunchWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Clear Rust registration/storage so status polls and device lists match UI.
  Future<void> _syncPhd2BackendAfterLinkLost() async {
    try {
      await backend.phd2Disconnect();
    } catch (e, st) {
      _logger.debug(
        'PHD2 backend cleanup after link loss: $e\n$st',
        source: 'Phd2Controller',
      );
    }
  }

  void _init() {
    // Listen to backend events
    _eventSub = backend.eventStream.listen(
      (event) {
        if (event.category != EventCategory.guiding) return;
        if (_disposed) return;

        _logger.debug(
          'Received guiding event: ${event.eventType}',
          source: 'Phd2Controller',
        );

        // Update the main GuiderState used by the UI
        final guiderNotifier = ref.read(guiderStateProvider.notifier);

        switch (event.eventType) {
          case 'Connected':
            _linkLossHandled = false;
            ref.read(guiderStateProvider.notifier).setConnected();
            unawaited(_refreshPixelScale());
            break;
          case 'Disconnected':
            _handlePhd2LinkLost();
            return;
          case 'AppState':
            _updateStateFromString(event.data['State']);
            break;
          case 'GuideStep':
            _logger.debug(
              'Processing GuideStep event',
              source: 'Phd2Controller',
            );
            _handleGuideStep(event.data);
            break;
          case 'GuideStats':
            _logger.debug(
              'Processing GuideStats event',
              source: 'Phd2Controller',
            );
            _handleGuideStats(event.data);
            break;
          case 'GuidingStarted':
            ref.read(phd2StateProvider.notifier).state = Phd2State.guiding;
            guiderNotifier.setGuiding(true);
            unawaited(_refreshPixelScale());
            break;
          case 'GuidingStopped':
            _resetStarLoss();
            ref.read(phd2StateProvider.notifier).state = Phd2State.stopped;
            guiderNotifier.setGuiding(false);
            break;
          case 'Paused':
            ref.read(phd2StateProvider.notifier).state = Phd2State.paused;
            break;
          case 'Resumed':
            ref.read(phd2StateProvider.notifier).state = Phd2State.guiding;
            guiderNotifier.setGuiding(true);
            break;
          case 'StarLost':
            ref.read(phd2StateProvider.notifier).state = Phd2State.lostLock;
            _handleStarLost();
            break;
          case 'Settling':
            ref.read(phd2StateProvider.notifier).state = Phd2State.settling;
            break;
          case 'SettleDone':
            // Settle complete - return to guiding state
            ref.read(phd2StateProvider.notifier).state = Phd2State.guiding;
            _logger.info('Settle complete', source: 'PHD2');
            break;
          case 'LoopingExposures':
            ref.read(phd2StateProvider.notifier).state = Phd2State.looping;
            break;
          case 'Calibrating':
            ref.read(phd2StateProvider.notifier).state = Phd2State.calibrating;
            break;
          case 'CalibrationComplete':
            _logger.info('Calibration complete', source: 'PHD2');
            final calibrationNotifier = ref.read(
              calibrationStateProvider.notifier,
            );
            if (calibrationNotifier.mounted) {
              unawaited(calibrationNotifier.refreshCalibrationData());
            }
            unawaited(_refreshPixelScale());
            break;
          // Note: StarSelected is handled by LockPositionNotifier's own event listener
        }

        // Liveness traffic only — never promote back to connected after Disconnected.
        if (isPhd2GuidingHeartbeatEvent(event.eventType) &&
            ref.read(guiderStateProvider).connectionState !=
                DeviceConnectionState.connected) {
          guiderNotifier.setConnected();
        }
      },
      onError: (err) {
        _logger.error('Controller Event Error: $err', source: 'PHD2');
        _handlePhd2LinkLost();
      },
    );
  }

  void _updateStateFromString(String? stateStr) {
    if (stateStr == null) return;

    Phd2State state;
    switch (stateStr) {
      case 'Stopped':
        state = Phd2State.stopped;
        break;
      case 'Selected':
        state = Phd2State.selected;
        break;
      case 'Calibrating':
        state = Phd2State.calibrating;
        break;
      case 'Guiding':
        state = Phd2State.guiding;
        break;
      case 'LostLock':
        state = Phd2State.lostLock;
        break;
      case 'Paused':
        state = Phd2State.paused;
        break;
      case 'Looping':
        state = Phd2State.looping;
        break;
      default:
        // An unrecognised AppState must NOT collapse to `stopped` — that would
        // falsely enable Start over a process that may well be live. Surface it
        // as `unknown` so the controls stay conservative (Stop, not Start).
        _logger.warning(
          'Unrecognised PHD2 AppState "$stateStr" — treating as unknown',
          source: 'Phd2Controller',
        );
        state = Phd2State.unknown;
    }

    ref.read(phd2StateProvider.notifier).state = state;

    // Update UI provider
    final guiderNotifier = ref.read(guiderStateProvider.notifier);
    guiderNotifier.setGuiding(state == Phd2State.guiding);
  }

  void _handleGuideStep(Map<String, dynamic> json) {
    // GuideStatsNotifier handles the proper rolling RMS calculation
    // Just update the UI state provider with the current stats
    final stats = ref.read(guideStatsProvider);
    if (_starLossActive) {
      final rms = stats.rmsTotal;
      if (rms.isFinite && rms > 0 && rms <= 2) {
        final now = _now();
        _stableGuidingSince ??= now;
        if (now.difference(_stableGuidingSince!) >=
            const Duration(seconds: 10)) {
          _logger.info(
            'Guide star recovered; guiding has remained within 2 px '
            'for 10 seconds.',
            source: 'PHD2',
          );
          _resetStarLoss();
        }
      } else {
        _stableGuidingSince = null;
      }
    }

    ref
        .read(guiderStateProvider.notifier)
        .updateRms(stats.rmsRa, stats.rmsDec, stats.rmsTotal);
  }

  void _handleGuideStats(Map<String, dynamic> json) {
    // Update SNR and star mass from GuideStats event
    final snr = (json['SNR'] as num?)?.toDouble() ?? 0;
    final starMass = (json['StarMass'] as num?)?.toDouble() ?? 0;

    // Update the guide stats provider with SNR and star mass
    ref.read(guideStatsProvider.notifier).updateStarData(snr, starMass);
  }

  void _resetStarLoss() {
    _starLossActive = false;
    _stableGuidingSince = null;
    _lastStarLossWarning = null;
  }

  void _handleStarLost() {
    // Record the event timestamp
    ref.read(starLostEventProvider.notifier).state = DateTime.now();

    // Update UI state: the star is gone, so we are no longer actively guiding.
    // The `phd2StateProvider` is already `lostLock` (set by the caller), which
    // the capability layer treats as a busy/uncertain phase — the controls
    // therefore offer Stop/Disconnect, never an enabled Start, over a rig that
    // may recover on its own when the star returns.
    final guiderNotifier = ref.read(guiderStateProvider.notifier);
    guiderNotifier.setGuiding(false);

    final now = _now();
    _starLossActive = true;
    _stableGuidingSince = null;
    if (_lastStarLossWarning == null ||
        now.difference(_lastStarLossWarning!) >= const Duration(minutes: 1)) {
      _logger.warning('Guide star lost — guiding suspended.', source: 'PHD2');
      _lastStarLossWarning = now;
    }

    // RECOVERY POLICY (explicit, by design):
    // This controller deliberately does NOT drive its own star-recovery loop.
    // Inventing aggressive re-selection/recalibration here would race the
    // canonical recovery authority — the sequencer's RecoveryNode/recovery
    // provider — which already watches [starLostEventProvider] and applies the
    // user-configured bounded retry policy (interval / max-duration / abort
    // rules from AppSettings) when a run is active. PHD2 itself also re-locks
    // automatically once the star reappears within its own timeout. The
    // controller's job is only to surface the loss truthfully; escalation is
    // owned upstream so there is exactly one recovery decision-maker.
  }

  Future<void> connect(String host, int port) {
    final existing = _connectOperation;
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = _connect(host, port).whenComplete(() {
      if (identical(_connectOperation, operation)) {
        _connectOperation = null;
      }
    });
    _connectOperation = operation;
    return operation;
  }

  /// Read the guide camera's pixel scale (arcsec/px) into [guiderStateProvider].
  ///
  /// PHD2 computes it from its profile's focal length and pixel size, so it
  /// is read when the link comes up and again when calibration or guiding
  /// starts, the points at which a profile change would have taken effect.
  /// A guider with no scale, or a failed read, leaves it null: the guide
  /// chart then stays in pixels rather than converting with a guess.
  Future<void> _refreshPixelScale() async {
    try {
      final status = await backend.phd2GetStatus();
      if (_disposed || !status.connected) return;
      ref.read(guiderStateProvider.notifier).setPixelScale(status.pixelScale);
    } catch (e) {
      if (_disposed) return;
      _logger.debug(
        'Could not read the guider pixel scale: $e',
        source: 'Phd2Controller',
      );
    }
  }

  Future<void> _connect(String host, int port) async {
    if (host.trim().isEmpty || port < 1 || port > 65535) {
      throw ArgumentError('PHD2 host must be non-empty and port 1-65535.');
    }
    // Explicit reconnect clears the "stay disconnected" latch a prior user
    // Disconnect set, re-enabling crash-relaunch for this session.
    _userDisconnectRequested = false;
    _linkLossHandled = false;

    if (backend is FfiBackend) {
      // Desktop owns launch + socket connect via DeviceService (polls port,
      // launches the configured binary). The requested endpoint is honoured
      // rather than silently discarded — for a local host DeviceService still
      // auto-launches; for a remote host it connects over TCP without spawning.
      await ref
          .read(deviceServiceProvider)
          .connectGuider(kPhd2CanonicalId, host: host, port: port);
      return;
    }

    ref
        .read(guiderStateProvider.notifier)
        .setConnecting(kPhd2CanonicalId, 'Connecting to PHD2');
    try {
      // Remote companions delegate launch + socket connect to the imaging
      // host via POST /api/phd2/connect. Never spawn PHD2 locally on mobile.
      await backend.phd2Connect(host: host, port: port);
      final status = await pollPhd2Connected(backend);
      if (!status.connected) {
        throw StateError(
          'Imaging host did not report a PHD2 connection after connect '
          'request.',
        );
      }
      ref.read(guiderStateProvider.notifier).setConnected();
    } catch (e) {
      _logger.error(
        'Failed to connect to PHD2 at $host:$port: $e',
        source: 'PHD2',
      );
      ref.read(guiderStateProvider.notifier).setDisconnected();
      rethrow;
    }
  }

  /// Authoritative user Disconnect.
  ///
  /// Order matters and every authoritative step runs SYNCHRONOUSLY before the
  /// first await, so a Disconnected event racing back cannot re-trigger the
  /// crash-relaunch path:
  ///   1. latch [_userDisconnectRequested] (survives the coordinator debounce),
  ///   2. cancel any pending relaunch backoff timer,
  ///   3. mark the disconnect user-initiated in DeviceService (cancels the
  ///      coordinator's own reconnect timers for this device).
  /// Only then do we tear the socket down through the canonical
  /// DeviceService path (which also clears Rust registration + UI state).
  Future<void> disconnect() async {
    _userDisconnectRequested = true;
    _cancelRelaunch();

    final deviceService = ref.read(deviceServiceProvider);
    deviceService.markUserInitiatedDisconnect(kPhd2CanonicalId);

    // Interrupt and join a pending connect, then issue the final teardown. A
    // Disconnect tap must not return while an older Connect can still succeed.
    final connecting = _connectOperation;
    if (connecting != null) {
      try {
        await backend.phd2Disconnect();
      } catch (_) {
        // Best-effort interruption. The authoritative teardown below reports
        // any persistent failure.
      }
      try {
        await connecting;
      } catch (_) {
        // A connect interrupted by this explicit disconnect is expected.
      }
    }

    final status = await readPhd2StatusOrDisconnected(backend);
    if (status.connected && status.state.toLowerCase() != 'stopped') {
      await backend.phd2StopGuiding();
    }

    try {
      await deviceService.disconnectGuider();
    } on DeviceNotConnectedException {
      // No live guider record (a prior connect never completed): fall back to a
      // direct backend teardown so the socket + UI still end up disconnected.
      await backend.phd2Disconnect();
    }

    ref.read(phd2StateProvider.notifier).state = Phd2State.stopped;
    ref.read(guiderStateProvider.notifier).setDisconnected();
  }

  /// A settle needs its timeout to be at least the required stable duration,
  /// otherwise it can NEVER succeed — PHD2 would abort with a settle timeout
  /// before `settleTime` seconds of "in range" have elapsed. The settle-time
  /// and settle-timeout sliders have overlapping ranges (time up to 60 s,
  /// timeout down to 30 s), so this impossible ordering is reachable from the
  /// UI. Normalise it at the backend boundary so a mis-set pair degrades to a
  /// just-achievable settle instead of a guaranteed failure.
  static double _effectiveSettleTimeout(
    double settleTime,
    double settleTimeout,
  ) => math.max(settleTimeout, settleTime + 1.0);

  static void _validateSettle({
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
  }) {
    if (!settlePixels.isFinite || settlePixels < 0.05 || settlePixels > 20) {
      throw RangeError('settlePixels must be between 0.05 and 20.');
    }
    if (!settleTime.isFinite || settleTime < 0 || settleTime > 120) {
      throw RangeError.range(settleTime, 0, 120, 'settleTime');
    }
    if (!settleTimeout.isFinite || settleTimeout < 1 || settleTimeout > 600) {
      throw RangeError.range(settleTimeout, 1, 600, 'settleTimeout');
    }
  }

  Future<void> startGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) {
    return _commandGate.runPositive('start', () async {
      _validateSettle(
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      );
      final guiderId =
          ref.read(guiderStateProvider).deviceId ?? kPhd2CanonicalId;
      await backend.guiderStartGuiding(
        deviceId: guiderId,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: _effectiveSettleTimeout(settleTime, settleTimeout),
      );
    });
  }

  Future<void> stopGuiding() {
    // Stop rides its own gate slot so it can always pre-empt a settling Start
    // (the safe abort direction); only a second concurrent Stop is rejected.
    return _commandGate.runStop('stop', () async {
      final guiderId =
          ref.read(guiderStateProvider).deviceId ?? kPhd2CanonicalId;
      await backend.guiderStopGuiding(deviceId: guiderId);
    });
  }

  Future<void> pauseGuiding() {
    return _commandGate.runPositive('pause', () async {
      _requirePhd2('Pause');
      await backend.phd2SetPaused(true);
    });
  }

  Future<void> resumeGuiding() {
    return _commandGate.runPositive('resume', () async {
      _requirePhd2('Resume');
      await backend.phd2SetPaused(false);
    });
  }

  void _requirePhd2(String command) {
    final guiderId = ref.read(guiderStateProvider).deviceId;
    if (guiderId != null && !isPhd2DeviceId(guiderId)) {
      throw UnsupportedError(
        '$command is only available when PHD2 is the active guider.',
      );
    }
  }

  Future<void> dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) {
    return _commandGate.runPositive('dither', () async {
      _validateSettle(
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      );
      if (!amount.isFinite || amount < 0.1 || amount > 100) {
        throw RangeError('amount must be between 0.1 and 100.');
      }
      final guiderState = ref.read(guiderStateProvider);
      // PHD2 rejects dither outside the Guiding state with an opaque RPC
      // error; pre-check so the user (and the sequencer log) gets an
      // actionable message instead.
      if (!guiderState.isGuiding) {
        throw StateError(
          'Cannot dither: guiding is not active. Start guiding first '
          '(PHD2 must be in the Guiding state to accept a dither).',
        );
      }
      final guiderId = guiderState.deviceId ?? kPhd2CanonicalId;
      await backend.guiderDither(
        deviceId: guiderId,
        amount: amount,
        raOnly: raOnly,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: _effectiveSettleTimeout(settleTime, settleTimeout),
      );
    });
  }

  /// Start looping exposures without guiding
  Future<void> loop() {
    return _commandGate.runPositive('loop', () async {
      final guiderId =
          ref.read(guiderStateProvider).deviceId ?? kPhd2CanonicalId;
      await backend.guiderLoop(deviceId: guiderId);
    });
  }

  void dispose() {
    _disposed = true;
    _cancelRelaunch();
    _eventSub?.cancel();
  }
}

part of '../guiding_provider.dart';

/// A guide-step axis, or null when it is missing or not a finite number.
/// Those steps are dropped, not drawn at 0.
/// The raw RA and Dec residuals of a guide step, or null when either is not
/// a finite number.
({double ra, double dec})? finiteGuideResiduals(GuidingEvent_Correction step) =>
    step.raRaw.isFinite && step.decRaw.isFinite
    ? (ra: step.raRaw, dec: step.decRaw)
    : null;

/// Enabled only after a host supplies the guiding snapshot. Until then a
/// client still builds its graph from the events it receives.
final hostGuidingMirrorActiveProvider = StateProvider<bool>((ref) {
  ref.watch(backendProvider);
  return false;
});

/// Listens to [backendProvider.eventStream] and re-binds when the backend
/// instance changes (e.g. mobile companion connects via [NetworkBackend]).
class _BackendGuidingEventBinding {
  _BackendGuidingEventBinding(this._ref, this._onEvent);

  final Ref _ref;
  final void Function(SkotiqEvent event) _onEvent;
  StreamSubscription<SkotiqEvent>? _sub;
  int _generation = 0;

  void start() {
    _bind(_ref.read(backendProvider));
    _ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      _bind(next);
    });
  }

  void _bind(SkotiqBackend backend) {
    final generation = ++_generation;
    final previous = _sub;
    _sub = backend.eventStream.listen((event) {
      if (generation != _generation) return;
      _onEvent(event);
    });
    // The generation guard makes already-queued events harmless while the
    // asynchronous cancellation finishes.
    previous?.cancel();
  }

  void dispose() {
    _generation++;
    _sub?.cancel();
  }
}

/// Provider for PHD2 connection status - derived from guiderStateProvider
/// This is a computed provider that automatically stays in sync
final phd2ConnectedProvider = Provider<bool>((ref) {
  final guiderState = ref.watch(guiderStateProvider);
  return guiderState.connectionState == DeviceConnectionState.connected;
});

/// Provider for PHD2 state (Guiding, Stopped, etc.)
final phd2StateProvider = StateProvider<Phd2State>((ref) => Phd2State.stopped);

/// Provider for star lost events (timestamp of last star lost event)
final starLostEventProvider = StateProvider<DateTime?>((ref) => null);

/// Why the guider is stopped or held, as the native layer names it (the
/// guider status's `stopReason`); null while guiding runs. Kept from the
/// guider's StopReason events, so a planned stop (autofocus, a flip, a
/// tracking-limit hold) is never shown as lost guiding.
final guidingStopReasonProvider = StateProvider<String?>((ref) => null);

/// When PHD2 last gave up waiting for the guider to settle, and its words.
/// A settle that runs out is not a lost star: the star may still be locked.
final guiderSettleTimeoutProvider =
    StateProvider<({DateTime at, String error})?>((ref) => null);

/// Provider for current guide stats with rolling RMS calculation
final guideStatsProvider =
    StateNotifierProvider<GuideStatsNotifier, Phd2GuideStats>((ref) {
      return GuideStatsNotifier(ref);
    });

/// Notifier that maintains rolling RMS statistics
class GuideStatsNotifier extends StateNotifier<Phd2GuideStats> {
  final Ref ref;
  late final _BackendGuidingEventBinding _events;
  LoggingService get _logger => ref.read(loggingServiceProvider);

  final _rmsRaCalculator = RollingRmsCalculator(windowSize: 100);
  final _rmsDecCalculator = RollingRmsCalculator(windowSize: 100);
  int _frameCount = 0;
  int _loopFrameCount = 0;

  GuideStatsNotifier(this.ref)
    : super(
        const Phd2GuideStats(
          rmsRa: 0,
          rmsDec: 0,
          rmsTotal: 0,
          snr: 0,
          starMass: 0,
          frameCount: 0,
        ),
      ) {
    _events = _BackendGuidingEventBinding(ref, _onBackendEvent);
    _events.start();

    // Each Loop Exposures run counts its own frames from one. The count is
    // armed and cleared off [phd2StateProvider] — the same provider the Star
    // Statistics card reads to decide WHICH count to show — so the number on
    // screen and the run it belongs to cannot disagree. Both producers of the
    // looping state reach it (the `LoopingExposures` event and PHD2's polled
    // AppState), which a flag set from the event stream alone would not.
    ref.listen<Phd2State>(phd2StateProvider, (previous, next) {
      if (next == Phd2State.looping && previous != Phd2State.looping) {
        _loopFrameCount = 0;
        state = state.copyWith(loopFrameCount: 0);
      }
    });
  }

  void _onBackendEvent(SkotiqEvent event) {
    if (!mounted || ref.read(hostGuidingMirrorActiveProvider)) return;
    switch (guidingEventOf(event)) {
      case final GuidingEvent_Correction step:
        _logger.debug('Received GuideStep event', source: 'GuideStatsNotifier');
        _handleGuideStep(step);
      case GuidingEvent_GuideStats(:final snr, :final starMass):
        _logger.debug(
          'Received GuideStats: SNR=$snr, StarMass=$starMass',
          source: 'GuideStatsNotifier',
        );
        // A looping guider publishes exactly one `GuideStats` per captured
        // frame, so this event IS the loop's frame. Counted here and not in
        // [updateStarData] because `Phd2Controller` calls that method for this
        // same event — a count kept there would advance twice per frame.
        if (ref.read(phd2StateProvider) == Phd2State.looping) {
          _loopFrameCount++;
        }
        updateStarData(snr, starMass);
      case GuidingEvent_GuidingStopped():
        _logger.debug('Received GuidingStopped', source: 'GuideStatsNotifier');
        reset();
      case _:
        break;
    }
  }

  void _handleGuideStep(GuidingEvent_Correction step) {
    final residuals = finiteGuideResiduals(step);
    if (residuals == null) return;
    final raDistance = residuals.ra;
    final decDistance = residuals.dec;

    _rmsRaCalculator.add(raDistance);
    _rmsDecCalculator.add(decDistance);
    _frameCount++;

    // Formula: sqrt(mean(x²)) for each axis
    final rmsRa = _rmsRaCalculator.rms;
    final rmsDec = _rmsDecCalculator.rms;

    // Per-axis PEAK is the worst single-frame absolute excursion over the same
    // rolling window the RMS is computed from. RollingRmsCalculator already
    // tracks it; surface it so the panel's RA/Dec Peak tiles read the real
    // worst-case figure instead of a never-populated 0.00.
    final peakRa = _rmsRaCalculator.peak;
    final peakDec = _rmsDecCalculator.peak;

    // Total RMS is pythagorean combination of RA and Dec RMS
    final rmsTotal = math.sqrt(rmsRa * rmsRa + rmsDec * rmsDec);

    state = Phd2GuideStats(
      rmsRa: rmsRa,
      rmsDec: rmsDec,
      rmsTotal: rmsTotal,
      peakRa: peakRa,
      peakDec: peakDec,
      // A guide step carries no star statistics; the GuideStats event sent
      // with each step does.
      snr: state.snr,
      starMass: state.starMass,
      frameCount: _frameCount,
      loopFrameCount: _loopFrameCount,
    );
  }

  void reset() {
    _rmsRaCalculator.clear();
    _rmsDecCalculator.clear();
    _frameCount = 0;
    _loopFrameCount = 0;
    state = const Phd2GuideStats(
      rmsRa: 0,
      rmsDec: 0,
      rmsTotal: 0,
      snr: 0,
      starMass: 0,
      frameCount: 0,
    );
  }

  void applyHostStats(Phd2GuideStats stats) {
    _frameCount = stats.frameCount;
    _loopFrameCount = stats.loopFrameCount;
    state = stats;
  }

  /// Update just the star data (SNR and star mass) from a separate event
  void updateStarData(double snr, double starMass) {
    if (ref.read(hostGuidingMirrorActiveProvider)) return;
    state = Phd2GuideStats(
      rmsRa: state.rmsRa,
      rmsDec: state.rmsDec,
      rmsTotal: state.rmsTotal,
      peakRa: state.peakRa,
      peakDec: state.peakDec,
      snr: snr,
      starMass: starMass,
      frameCount: state.frameCount,
      loopFrameCount: _loopFrameCount,
    );
  }

  @override
  void dispose() {
    _events.dispose();
    super.dispose();
  }
}

// Per-star tracked-star provider (built-in multi-star guider)
//
// The internal guider tracks up to 8 reference stars natively, but only its
// aggregate PHD2-shaped stats reached Dart — so its star-list UI rendered empty.
// This provider polls the guiding status (which now carries a `trackedStars`
// JSON array) while the built-in guider is active and exposes the per-star list
// so the guider panel can show per-star SNR + lock + residual alongside the same
// CompactGuidingGraph the PHD2 path drives.

/// Per-star tracked-star list from the built-in multi-star guider.
///
/// Empty for PHD2 / external guiders (they report a single aggregate lock star).
/// Populated only while the built-in guider is the active guider AND it is
/// looping/guiding/calibrating; cleared on disconnect.
final guideStarsProvider =
    StateNotifierProvider<GuideStarsNotifier, List<GuideStar>>((ref) {
      return GuideStarsNotifier(ref);
    });

class GuideStarsNotifier extends StateNotifier<List<GuideStar>> {
  GuideStarsNotifier(this.ref) : super(const []) {
    // Poll only while the built-in guider is active and producing frames,
    // including when it already was before anything asked for the list.
    ref.listen<Phd2State>(phd2StateProvider, (previous, next) {
      if (!_isBuiltin) {
        _stopPolling();
        if (state.isNotEmpty) state = const [];
        return;
      }
      if (next == Phd2State.guiding ||
          next == Phd2State.looping ||
          next == Phd2State.calibrating ||
          next == Phd2State.settling) {
        _startPolling();
      } else {
        _stopPolling();
      }
    }, fireImmediately: true);

    // Clear on disconnect so a stale list never lingers across sessions.
    ref.listen<GuiderState>(guiderStateProvider, (previous, next) {
      if (next.connectionState == DeviceConnectionState.disconnected) {
        _stopPolling();
        if (state.isNotEmpty) state = const [];
      }
    });

    // A pending status request belongs to the backend that issued it. Switching
    // rigs invalidates that request immediately so equal guider IDs on two
    // hosts cannot leak the old host's stars into the new session.
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      _stopPolling();
      if (state.isNotEmpty) state = const [];
    });
  }

  final Ref ref;
  Timer? _pollTimer;
  int _pollGeneration = 0;
  bool _pollInFlight = false;
  int _consecutiveFailures = 0;
  LoggingService get _logger => ref.read(loggingServiceProvider);

  bool get _isBuiltin => ref.read(isBuiltinGuiderProvider);

  void _startPolling() {
    _stopPolling();
    final generation = _pollGeneration;
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) => _fetch(generation),
    );
    unawaited(_fetch(generation));
  }

  void _stopPolling() {
    _pollGeneration++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollInFlight = false;
    _consecutiveFailures = 0;
  }

  Future<void> _fetch(int generation) async {
    if (!mounted || generation != _pollGeneration || _pollInFlight) return;
    final backend = ref.read(backendProvider);
    final guiderId = ref.read(guiderStateProvider).deviceId;
    if (!_isBuiltin || guiderId == null) return;
    _pollInFlight = true;
    try {
      final status = await backend.guiderGetStatus();
      if (!mounted ||
          generation != _pollGeneration ||
          ref.backendScopeOver(backend).isStale ||
          ref.read(guiderStateProvider).deviceId != guiderId ||
          !_isBuiltin) {
        return;
      }
      _consecutiveFailures = 0;
      // Only adopt the list when it actually changed — avoids churning the
      // graph/list rebuilds every poll when nothing moved.
      if (!_listEquals(status.trackedStars, state)) {
        state = status.trackedStars;
      }
    } catch (e) {
      if (mounted &&
          generation == _pollGeneration &&
          ref.backendScopeOver(backend).isCurrent &&
          ref.read(guiderStateProvider).deviceId == guiderId &&
          _isBuiltin) {
        _consecutiveFailures++;
        // A transient missed poll should not erase the graph or spam logs.
        // After sustained failure, clear the now-stale stars and emit one
        // actionable warning; later ticks keep trying and recover naturally.
        if (_consecutiveFailures == 3) {
          if (state.isNotEmpty) state = const [];
          _logger.warning(
            'Built-in guider star status is unavailable after 3 polls: $e',
            source: 'GuideStarsNotifier',
          );
        }
      }
    } finally {
      if (generation == _pollGeneration) _pollInFlight = false;
    }
  }

  /// Test/imperative hook: directly seed the tracked-star list (used by the
  /// guider UI golden + provider override in tests, and by any future
  /// event-driven push path).
  void setStars(List<GuideStar> stars) {
    if (!mounted) return;
    state = List.unmodifiable(stars);
  }

  static bool _listEquals(List<GuideStar> a, List<GuideStar> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}

class GuideGraphPoint {
  final double ra;
  final double dec;
  final DateTime time;

  GuideGraphPoint(this.ra, this.dec, this.time);
}

/// Provider for guiding graph data (last N points)
final guideGraphProvider =
    StateNotifierProvider<GuideGraphNotifier, List<GuideGraphPoint>>((ref) {
      return GuideGraphNotifier(ref);
    });

class GuideGraphNotifier extends StateNotifier<List<GuideGraphPoint>> {
  final Ref ref;
  late final _BackendGuidingEventBinding _events;
  // ~2.5–7 min of history at PHD2's typical 0.5–2 Hz guide cadence.
  static const int maxPoints = 400;
  final Queue<GuideGraphPoint> _buffer = Queue<GuideGraphPoint>();
  LoggingService get _logger => ref.read(loggingServiceProvider);

  GuideGraphNotifier(this.ref) : super([]) {
    _events = _BackendGuidingEventBinding(ref, _onBackendEvent);
    _events.start();

    ref.listen<GuiderState>(guiderStateProvider, (previous, next) {
      if (next.connectionState == DeviceConnectionState.disconnected) {
        clear();
      }
    });
  }

  void _onBackendEvent(SkotiqEvent event) {
    if (!mounted || ref.read(hostGuidingMirrorActiveProvider)) return;
    final guiding = guidingEventOf(event);
    if (guiding is GuidingEvent_Correction) {
      final residuals = finiteGuideResiduals(guiding);
      if (residuals == null) return;
      final (:ra, :dec) = residuals;
      _logger.debug(
        'Adding point: RA=$ra, Dec=$dec',
        source: 'GuideGraphNotifier',
      );
      addPoint(
        ra,
        dec,
        at: event.timestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(event.timestamp)
            : DateTime.now(),
      );
    } else if (guiding is GuidingEvent_GuidingStopped) {
      clear();
    }
  }

  void addPoint(double ra, double dec, {DateTime? at}) {
    if (!ra.isFinite || !dec.isFinite) return;
    final point = GuideGraphPoint(ra, dec, at ?? DateTime.now());
    _buffer.add(point);
    if (_buffer.length > maxPoints) {
      _buffer.removeFirst();
    }
    state = _buffer.toList(); // Single list creation instead of two
  }

  void applyHostHistory(List<GuideGraphPoint> points) {
    _buffer
      ..clear()
      ..addAll(points.where((p) => p.ra.isFinite && p.dec.isFinite));
    while (_buffer.length > maxPoints) {
      _buffer.removeFirst();
    }
    state = List.unmodifiable(_buffer);
  }

  void clear() {
    _buffer.clear();
    state = [];
  }

  @override
  void dispose() {
    _events.dispose();
    super.dispose();
  }
}

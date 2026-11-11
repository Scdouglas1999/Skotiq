part of '../guiding_provider.dart';

final brainParamsProvider =
    StateNotifierProvider<BrainParamsNotifier, AsyncValue<Phd2BrainParams>>((
      ref,
    ) {
      return BrainParamsNotifier(ref);
    });

/// Notifier that fetches and caches PHD2 brain parameters
class BrainParamsNotifier extends StateNotifier<AsyncValue<Phd2BrainParams>> {
  final Ref ref;
  bool _hasFetched = false;
  int _backendGeneration = 0;
  int _fetchGeneration = 0;
  LoggingService get _logger => ref.read(loggingServiceProvider);

  BrainParamsNotifier(this.ref) : super(const AsyncValue.loading()) {
    // Auto-fetch when PHD2 is connected
    final guiderState = ref.read(guiderStateProvider);
    if (guiderState.connectionState == DeviceConnectionState.connected &&
        guiderState.deviceId == 'phd2_guider') {
      fetch();
    }

    ref.listen<GuiderState>(guiderStateProvider, (previous, next) {
      if (next.connectionState == DeviceConnectionState.connected &&
          next.deviceId == 'phd2_guider' &&
          !_hasFetched) {
        fetch();
      } else if (next.connectionState == DeviceConnectionState.disconnected) {
        _hasFetched = false;
        state = const AsyncValue.loading();
      } else if (next.connectionState == DeviceConnectionState.connected &&
          next.deviceId != 'phd2_guider') {
        _hasFetched = false;
        state = const AsyncValue.loading();
      }
    });

    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      _backendGeneration++;
      _fetchGeneration++;
      _hasFetched = false;
      state = const AsyncValue.loading();
    });
  }

  Future<void> fetch() async {
    if (!mounted) return;
    state = const AsyncValue.loading();

    final backend = ref.read(backendProvider);
    final backendGeneration = _backendGeneration;
    final fetchGeneration = ++_fetchGeneration;

    try {
      final raNames = await backend.phd2GetAlgoParamNames(axis: 'ra');
      if (!_isCurrentFetch(backend, backendGeneration, fetchGeneration)) return;
      final decNames = await backend.phd2GetAlgoParamNames(axis: 'dec');
      if (!_isCurrentFetch(backend, backendGeneration, fetchGeneration)) return;

      // PHD2 only exposes guide-algorithm parameters once equipment is
      // connected to the profile (a mount/guide-algorithm is configured). If
      // both axes come back empty the dump is meaningless — the panel would
      // render two blank axis sections that read as "nothing loaded". Surface
      // that as a real, actionable error instead of a silently empty success.
      if (raNames.isEmpty && decNames.isEmpty) {
        throw StateError(
          'PHD2 returned no guide-algorithm parameters. Connect PHD2 to its '
          'equipment profile (mount + guide camera) and try again.',
        );
      }

      final raParams = <String, double>{};
      for (final name in raNames) {
        raParams[name] = await backend.phd2GetAlgoParam(axis: 'ra', name: name);
        if (!_isCurrentFetch(backend, backendGeneration, fetchGeneration)) {
          return;
        }
      }

      final decParams = <String, double>{};
      for (final name in decNames) {
        decParams[name] = await backend.phd2GetAlgoParam(
          axis: 'dec',
          name: name,
        );
        if (!_isCurrentFetch(backend, backendGeneration, fetchGeneration)) {
          return;
        }
      }

      if (_isCurrentFetch(backend, backendGeneration, fetchGeneration)) {
        _hasFetched = true;
        state = AsyncValue.data(
          Phd2BrainParams(
            raParamNames: raNames,
            decParamNames: decNames,
            raParams: raParams,
            decParams: decParams,
          ),
        );
      }
    } catch (e, st) {
      _logger.error('Failed to load PHD2 brain params: $e', source: 'PHD2');
      if (_isCurrentFetch(backend, backendGeneration, fetchGeneration)) {
        state = AsyncValue.error(e, st);
      }
    }
  }

  bool _isCurrentFetch(
    SkotiqBackend backend,
    int backendGeneration,
    int fetchGeneration,
  ) =>
      mounted &&
      backendGeneration == _backendGeneration &&
      fetchGeneration == _fetchGeneration &&
      identical(backend, ref.read(backendProvider));

  Future<void> setParam(String axis, String name, double value) async {
    final backend = ref.read(backendProvider);
    final backendGeneration = _backendGeneration;

    try {
      await backend.phd2SetAlgoParam(axis: axis, name: name, value: value);

      if (backendGeneration != _backendGeneration ||
          !identical(backend, ref.read(backendProvider))) {
        throw StateError(
          'The imaging host changed while updating PHD2 brain settings.',
        );
      }

      state.whenData((params) {
        if (axis == 'ra' || axis == 'x') {
          final newRaParams = Map<String, double>.from(params.raParams);
          newRaParams[name] = value;
          state = AsyncValue.data(params.copyWith(raParams: newRaParams));
        } else {
          final newDecParams = Map<String, double>.from(params.decParams);
          newDecParams[name] = value;
          state = AsyncValue.data(params.copyWith(decParams: newDecParams));
        }
      });
    } catch (e) {
      _logger.error('Failed to set brain param $name: $e', source: 'PHD2');
      rethrow;
    }
  }
}

final calibrationStateProvider =
    StateNotifierProvider<CalibrationStateNotifier, Phd2CalibrationData>((ref) {
      return CalibrationStateNotifier(ref);
    });

class CalibrationStateNotifier extends StateNotifier<Phd2CalibrationData> {
  final Ref ref;
  late final _BackendGuidingEventBinding _events;
  bool _hasFetched = false;
  int _backendGeneration = 0;
  int _fetchGeneration = 0;
  LoggingService get _logger => ref.read(loggingServiceProvider);

  CalibrationStateNotifier(this.ref) : super(const Phd2CalibrationData()) {
    _logger.debug('CalibrationStateNotifier: Initializing...', source: 'PHD2');

    _events = _BackendGuidingEventBinding(ref, _onBackendEvent);
    _events.start();
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      _backendGeneration++;
      _fetchGeneration++;
      _hasFetched = false;
      state = const Phd2CalibrationData();
    });

    // Fetch calibration data when PHD2 connects
    ref.listen<GuiderState>(guiderStateProvider, (previous, next) {
      _logger.debug(
        'CalibrationStateNotifier: guiderState changed from ${previous?.connectionState} to ${next.connectionState}',
        source: 'PHD2',
      );
      if (next.connectionState == DeviceConnectionState.connected &&
          next.deviceId == 'phd2_guider' &&
          !_hasFetched) {
        _logger.debug(
          'CalibrationStateNotifier: PHD2 connected, fetching calibration data...',
          source: 'PHD2',
        );
        unawaited(refreshCalibrationData());
      } else if (next.connectionState == DeviceConnectionState.disconnected) {
        _logger.debug(
          'CalibrationStateNotifier: PHD2 disconnected, resetting state',
          source: 'PHD2',
        );
        _hasFetched = false;
        state = const Phd2CalibrationData();
      } else if (next.connectionState == DeviceConnectionState.connected &&
          next.deviceId != 'phd2_guider') {
        _hasFetched = false;
        state = const Phd2CalibrationData();
      }
    });

    // Also check current state on initialization
    final guiderState = ref.read(guiderStateProvider);
    _logger.debug(
      'CalibrationStateNotifier: Initial guiderState.connectionState = ${guiderState.connectionState}',
      source: 'PHD2',
    );
    if (guiderState.connectionState == DeviceConnectionState.connected &&
        guiderState.deviceId == 'phd2_guider') {
      _logger.debug(
        'CalibrationStateNotifier: Already connected on init, fetching calibration data...',
        source: 'PHD2',
      );
      unawaited(refreshCalibrationData());
    }
  }

  void _onBackendEvent(SkotiqEvent event) {
    if (!mounted || event.category != EventCategory.guiding) return;
    switch (event.eventType) {
      case 'CalibrationComplete':
        _logger.info('CalibrationComplete event received', source: 'PHD2');
        state = state.copyWith(
          isCalibrated: true,
          calibratedAt: DateTime.now(),
        );
        break;
      case 'CalibrationFailed':
        _logger.warning('CalibrationFailed event received', source: 'PHD2');
        state = state.copyWith(isCalibrated: false);
        break;
      case 'CalibrationDataFlipped':
        _logger.info('Calibration data flipped', source: 'PHD2');
        unawaited(refreshCalibrationData());
        break;
      // PHD2's calibration can change between guiding sessions without a
      // calibration event reaching here (restored, adjusted or redone in
      // PHD2). A value read once at connect went stale for the whole night.
      case 'GuidingStarted':
      case 'GuidingStopped':
        if (_hasFetched) unawaited(refreshCalibrationData());
        break;
    }
  }

  Future<void> refreshCalibrationData() async {
    final backend = ref.read(backendProvider);
    final backendGeneration = _backendGeneration;
    final fetchGeneration = ++_fetchGeneration;
    try {
      final data = await backend.phd2GetCalibrationData();
      if (!_isCurrentFetch(backend, backendGeneration, fetchGeneration)) return;
      _hasFetched = true;

      if (_isCurrentFetch(backend, backendGeneration, fetchGeneration)) {
        state = data;
        _logger.info(
          'Fetched calibration data - calibrated: ${data.isCalibrated}',
          source: 'PHD2',
        );
      }
    } catch (e) {
      if (_isCurrentFetch(backend, backendGeneration, fetchGeneration)) {
        _logger.error('Failed to fetch calibration data: $e', source: 'PHD2');
      }
    }
  }

  bool _isCurrentFetch(
    SkotiqBackend backend,
    int backendGeneration,
    int fetchGeneration,
  ) =>
      mounted &&
      backendGeneration == _backendGeneration &&
      fetchGeneration == _fetchGeneration &&
      identical(backend, ref.read(backendProvider));

  Future<void> clearCalibration({String which = 'both'}) async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    await backend.phd2ClearCalibration(which: which);
    _ensureBackendUnchanged(backend, generation, 'clearing calibration');
    state = const Phd2CalibrationData(isCalibrated: false);
  }

  /// Flip calibration (after meridian flip)
  Future<void> flipCalibration() async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    await backend.phd2FlipCalibration();
    _ensureBackendUnchanged(backend, generation, 'flipping calibration');
  }

  void _ensureBackendUnchanged(
    SkotiqBackend backend,
    int generation,
    String action,
  ) {
    if (generation == _backendGeneration &&
        identical(backend, ref.read(backendProvider))) {
      return;
    }
    throw StateError('The imaging host changed while $action.');
  }

  @override
  void dispose() {
    _backendGeneration++;
    _fetchGeneration++;
    _events.dispose();
    super.dispose();
  }
}

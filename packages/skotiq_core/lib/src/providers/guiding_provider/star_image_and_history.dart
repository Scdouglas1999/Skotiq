part of '../guiding_provider.dart';

// PHD2 star image provider - polls star image for guide star view

/// Provider for star image polling configuration
final starImageSizeProvider = StateProvider<int>((ref) => 50);

/// Provider for star image polling interval (milliseconds)
final starImagePollIntervalProvider = StateProvider<int>((ref) => 500);

/// Provider for star image data
final starImageProvider =
    StateNotifierProvider<StarImageNotifier, AsyncValue<Phd2StarImage>>((ref) {
      return StarImageNotifier(ref);
    });

/// Notifier that polls PHD2 for star image data
class StarImageNotifier extends StateNotifier<AsyncValue<Phd2StarImage>> {
  final Ref ref;
  Timer? _pollTimer;
  int _pollGeneration = 0;
  bool _pollInFlight = false;

  StarImageNotifier(this.ref) : super(const AsyncValue.loading()) {
    // Start polling when guiding or looping
    ref.listen<Phd2State>(phd2StateProvider, (previous, next) {
      if (next == Phd2State.guiding ||
          next == Phd2State.looping ||
          next == Phd2State.calibrating) {
        _startPolling();
      } else {
        _stopPolling();
      }
    });

    // Stop polling and reset state when PHD2 disconnects
    ref.listen<GuiderState>(guiderStateProvider, (previous, next) {
      if (next.connectionState == DeviceConnectionState.disconnected) {
        _stopPolling();
        state = const AsyncValue.loading();
      }
    });

    // A response belongs to the backend and guider that issued it. Invalidate
    // pending work immediately on a host switch so host A's late image cannot
    // appear in host B's guide-star panel.
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      _stopPolling();
      state = const AsyncValue.loading();
    });
  }

  void _startPolling() {
    _stopPolling();
    final generation = _pollGeneration;
    final interval = ref.read(starImagePollIntervalProvider);
    _pollTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
      unawaited(_fetchStarImage(generation));
    });
    // Fetch immediately
    unawaited(_fetchStarImage(generation));
  }

  void _stopPolling() {
    _pollGeneration++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollInFlight = false;
  }

  Future<void> _fetchStarImage(int generation) async {
    if (!mounted || generation != _pollGeneration || _pollInFlight) return;
    final backend = ref.read(backendProvider);
    final size = ref.read(starImageSizeProvider);
    final guiderId = ref.read(guiderStateProvider).deviceId;

    if (guiderId == null || guiderId.isEmpty) {
      return;
    }

    _pollInFlight = true;
    try {
      final image = await backend.guiderGetStarImage(
        deviceId: guiderId,
        size: size,
      );
      if (mounted &&
          generation == _pollGeneration &&
          identical(backend, ref.read(backendProvider)) &&
          ref.read(guiderStateProvider).deviceId == guiderId) {
        state = AsyncValue.data(image);
      }
    } catch (e) {
      if (mounted &&
          generation == _pollGeneration &&
          identical(backend, ref.read(backendProvider)) &&
          ref.read(guiderStateProvider).deviceId == guiderId) {
        state = AsyncValue.error(e, StackTrace.current);
      }
    } finally {
      if (generation == _pollGeneration) _pollInFlight = false;
    }
  }

  /// Manually trigger a fetch
  Future<void> refresh() async {
    await _fetchStarImage(_pollGeneration);
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}

// Target display history provider - tracks error history for target display

/// Maximum number of error points to keep
const int maxTargetHistoryPoints = 50;

/// Provider for target display error history
final targetDisplayHistoryProvider =
    StateNotifierProvider<TargetDisplayHistoryNotifier, List<GuideErrorPoint>>((
      ref,
    ) {
      return TargetDisplayHistoryNotifier(ref);
    });

/// Notifier that tracks guide error history for target display
class TargetDisplayHistoryNotifier
    extends StateNotifier<List<GuideErrorPoint>> {
  final Ref ref;
  late final _BackendGuidingEventBinding _events;
  final Queue<GuideErrorPoint> _buffer = Queue<GuideErrorPoint>();
  LoggingService get _logger => ref.read(loggingServiceProvider);

  TargetDisplayHistoryNotifier(this.ref) : super([]) {
    _events = _BackendGuidingEventBinding(ref, _onBackendEvent);
    _events.start();
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (!identical(previous, next)) clear();
    });
  }

  void _onBackendEvent(SkotiqEvent event) {
    if (!mounted || event.category != EventCategory.guiding) return;
    switch (event.eventType) {
      case 'GuideStep':
        _logger.debug(
          'Received GuideStep event',
          source: 'TargetDisplayHistoryNotifier',
        );
        final json = event.data;
        final raError = (json['RADistanceRaw'] ?? 0).toDouble();
        final decError = (json['DECDistanceRaw'] ?? 0).toDouble();
        _addPoint(raError, decError);
        break;
      case 'GuidingStopped':
      case 'GuidingStarted':
        clear();
        break;
    }
  }

  void _addPoint(double raError, double decError) {
    if (!mounted) return;
    final point = GuideErrorPoint(
      raError: raError,
      decError: decError,
      timestamp: DateTime.now(),
    );
    _buffer.add(point);
    if (_buffer.length > maxTargetHistoryPoints) {
      _buffer.removeFirst();
    }
    state = _buffer.toList();
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

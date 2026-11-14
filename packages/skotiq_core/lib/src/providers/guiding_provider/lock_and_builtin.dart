part of '../guiding_provider.dart';

/// Provider for current guide star lock position
final lockPositionProvider =
    StateNotifierProvider<LockPositionNotifier, ({double x, double y})?>((ref) {
      return LockPositionNotifier(ref);
    });

/// Notifier that tracks guide star lock position
class LockPositionNotifier extends StateNotifier<({double x, double y})?> {
  final Ref ref;
  late final _BackendGuidingEventBinding _events;
  int _backendGeneration = 0;

  LockPositionNotifier(this.ref) : super(null) {
    _events = _BackendGuidingEventBinding(ref, _onBackendEvent);
    _events.start();
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (!identical(previous, next)) {
        _backendGeneration++;
        state = null;
      }
    });
  }

  void _onBackendEvent(SkotiqEvent event) {
    if (!mounted || event.category != EventCategory.guiding) return;
    if (event.eventType == 'StarSelected' ||
        event.eventType == 'LockPositionSet') {
      final x = (event.data['X'] ?? event.data['x'] ?? 0).toDouble();
      final y = (event.data['Y'] ?? event.data['y'] ?? 0).toDouble();
      state = (x: x, y: y);
    }
  }

  Future<void> setLockPosition(double x, double y, {bool exact = false}) async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    await backend.guiderSetLockPosition(x: x, y: y, exact: exact);
    _ensureBackendUnchanged(backend, generation, 'setting the guide star');
    state = (x: x, y: y);
  }

  /// Find a star automatically
  Future<void> findStar() async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    final pos = await backend.guiderFindStar();
    _ensureBackendUnchanged(backend, generation, 'finding a guide star');
    state = (x: pos.$1, y: pos.$2);
  }

  Future<void> deselectStar() async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    await backend.guiderDeselectStar();
    _ensureBackendUnchanged(backend, generation, 'deselecting the guide star');
    state = null;
  }

  void _ensureBackendUnchanged(
    SkotiqBackend backend,
    int generation,
    String action,
  ) {
    if (generation == _backendGeneration &&
        ref.backendScopeOver(backend).isCurrent) {
      return;
    }
    throw StateError('The imaging host changed while $action.');
  }

  @override
  void dispose() {
    _backendGeneration++;
    _events.dispose();
    super.dispose();
  }
}

/// Provider that exposes whether the currently connected guider is the built-in
/// guider (as opposed to PHD2 or another external guider).
final isBuiltinGuiderProvider = Provider<bool>((ref) {
  final guiderState = ref.watch(guiderStateProvider);
  return guiderState.deviceId == builtinGuiderDeviceId;
});

/// The built-in guider's configuration on the current host. The host keeps
/// one whether or not the guider is connected, so it is read at once and again
/// when the guider connects or disconnects and when the host changes.
final builtinGuiderConfigProvider =
    StateNotifierProvider<
      BuiltinGuiderConfigNotifier,
      AsyncValue<BuiltinGuiderConfig>
    >((ref) {
      return BuiltinGuiderConfigNotifier(ref);
    });

class BuiltinGuiderConfigNotifier
    extends StateNotifier<AsyncValue<BuiltinGuiderConfig>> {
  final Ref ref;
  int _backendGeneration = 0;
  int _fetchGeneration = 0;
  LoggingService get _logger => ref.read(loggingServiceProvider);

  BuiltinGuiderConfigNotifier(this.ref) : super(const AsyncValue.loading()) {
    ref.listen<bool>(isBuiltinGuiderProvider, (previous, next) {
      if (previous != next) fetch();
    });
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      _backendGeneration++;
      fetch();
    });
    fetch();
  }

  /// Fetch the current config from the Rust backend.
  Future<void> fetch() async {
    if (!mounted) return;
    state = const AsyncValue.loading();
    final backend = ref.read(backendProvider);
    final backendGeneration = _backendGeneration;
    final fetchGeneration = ++_fetchGeneration;

    try {
      final config = await backend.builtinGuiderGetConfig();
      if (_isCurrent(backend, backendGeneration, fetchGeneration)) {
        state = AsyncValue.data(config);
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to fetch built-in guider config: $e',
        source: 'BuiltinGuiderConfig',
      );
      if (_isCurrent(backend, backendGeneration, fetchGeneration)) {
        // Defaults are not evidence of the hardware's current configuration.
        // Surface the fetch failure so the editor cannot overwrite an unknown
        // real configuration while claiming it loaded successfully.
        state = AsyncValue.error(e, stackTrace);
      }
    }
  }

  bool _isCurrent(
    SkotiqBackend backend,
    int backendGeneration,
    int fetchGeneration,
  ) =>
      mounted &&
      backendGeneration == _backendGeneration &&
      fetchGeneration == _fetchGeneration &&
      ref.backendScopeOver(backend).isCurrent;

  /// Update the full config and push to the backend.
  Future<void> updateConfig(BuiltinGuiderConfig newConfig) async {
    if (!mounted) return;

    final previousState = state;
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    state = AsyncValue.data(newConfig);

    try {
      await backend.builtinGuiderSetConfig(newConfig);
      if (generation != _backendGeneration ||
          ref.backendScopeOver(backend).isStale) {
        throw StateError(
          'The imaging host changed while updating built-in guider settings.',
        );
      }
    } catch (e) {
      _logger.error(
        'Failed to set built-in guider config: $e',
        source: 'BuiltinGuiderConfig',
      );
      // Revert on failure
      if (mounted &&
          generation == _backendGeneration &&
          ref.backendScopeOver(backend).isCurrent) {
        state = previousState;
      }
      rethrow;
    }
  }

  Future<void> resetToDefaults() async {
    await updateConfig(BuiltinGuiderConfig.defaults);
  }

  @override
  void dispose() {
    _backendGeneration++;
    _fetchGeneration++;
    super.dispose();
  }
}

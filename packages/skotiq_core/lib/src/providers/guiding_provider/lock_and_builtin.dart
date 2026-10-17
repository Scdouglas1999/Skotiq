part of '../guiding_provider.dart';

// PHD2 lock position provider

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

  /// Set a new lock position
  Future<void> setLockPosition(double x, double y, {bool exact = false}) async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    final guiderId = ref.read(guiderStateProvider).deviceId ?? 'phd2_guider';
    await backend.guiderSetLockPosition(
      deviceId: guiderId,
      x: x,
      y: y,
      exact: exact,
    );
    _ensureBackendUnchanged(backend, generation, 'setting the guide star');
    state = (x: x, y: y);
  }

  /// Find a star automatically
  Future<void> findStar() async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    final guiderId = ref.read(guiderStateProvider).deviceId ?? 'phd2_guider';
    final pos = await backend.guiderFindStar(deviceId: guiderId);
    _ensureBackendUnchanged(backend, generation, 'finding a guide star');
    state = (x: pos.$1, y: pos.$2);
  }

  /// Deselect the current star
  Future<void> deselectStar() async {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    final guiderId = ref.read(guiderStateProvider).deviceId ?? 'phd2_guider';
    await backend.guiderDeselectStar(deviceId: guiderId);
    _ensureBackendUnchanged(backend, generation, 'deselecting the guide star');
    state = null;
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
    _events.dispose();
    super.dispose();
  }
}

// Built-in guider config provider

/// The device ID used by the built-in multi-star guider.
const String builtinGuiderDeviceId = 'native:builtin_guider:multi_star';

/// Provider that exposes whether the currently connected guider is the built-in
/// guider (as opposed to PHD2 or another external guider).
final isBuiltinGuiderProvider = Provider<bool>((ref) {
  final guiderState = ref.watch(guiderStateProvider);
  return guiderState.deviceId == builtinGuiderDeviceId;
});

/// Provider for the built-in guider configuration.
/// Fetches the config from the Rust backend and allows updating it.
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
    // Auto-fetch when the built-in guider is connected
    final isBuiltin = ref.read(isBuiltinGuiderProvider);
    if (isBuiltin) {
      fetch();
    }

    // Listen for guider changes to fetch/clear config
    ref.listen<bool>(isBuiltinGuiderProvider, (previous, next) {
      if (next && previous != true) {
        fetch();
      } else if (!next) {
        state = const AsyncValue.loading();
      }
    });
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      _backendGeneration++;
      _fetchGeneration++;
      state = const AsyncValue.loading();
    });
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
      identical(backend, ref.read(backendProvider));

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
          !identical(backend, ref.read(backendProvider))) {
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
          identical(backend, ref.read(backendProvider))) {
        state = previousState;
      }
      rethrow;
    }
  }

  /// Reset config to defaults.
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

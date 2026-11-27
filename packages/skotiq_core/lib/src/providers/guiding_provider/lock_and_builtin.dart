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
    if (!mounted) return;
    if (guidingEventOf(event) case GuidingEvent_StarSelected(
      :final x,
      :final y,
    )) {
      state = (x: x, y: y);
    }
  }

  void applyHostPosition(({double x, double y})? position) {
    state = position;
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

/// Which guider a screen is describing, and so which controls and settings
/// it has.
enum GuiderKind {
  /// PHD2, or no guider chosen yet: PHD2 is the default guider.
  phd2,

  /// Skotiq's own multi-star guider.
  builtin,

  /// The demo rig's simulated guider, which has no settings.
  demo,

  /// Any other guider driver, configured from Equipment.
  external,
}

/// The kind of the guider with [deviceId] (null when none is chosen) on a
/// backend whose host is [place].
GuiderKind guiderKindOf(String? deviceId, HostPlace place) {
  if (deviceId == null || isPhd2DeviceId(deviceId)) return GuiderKind.phd2;
  if (deviceId == builtinGuiderDeviceId) return GuiderKind.builtin;
  return place == HostPlace.demo ? GuiderKind.demo : GuiderKind.external;
}

/// The kind of the connected guider.
final connectedGuiderKindProvider = Provider<GuiderKind>((ref) {
  final id = ref.watch(guiderStateProvider.select((s) => s.deviceId));
  if (id != null && !isPhd2DeviceId(id) && ref.watch(isBuiltinGuiderProvider)) {
    return GuiderKind.builtin;
  }
  return guiderKindOf(
    id,
    ref.watch(backendProvider.select((b) => b.hostPlace)),
  );
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

  /// Replace the config from the host without writing it back.
  void applyHostConfig(BuiltinGuiderConfig config) {
    _fetchGeneration++;
    state = AsyncValue.data(config);
  }

  /// Update the full config and push to the backend.
  Future<void> updateConfig(BuiltinGuiderConfig newConfig) async {
    if (!mounted) return;

    final previousState = state;
    // A fetch started before this write must not put the old config back.
    _fetchGeneration++;
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

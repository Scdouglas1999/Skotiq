part of '../settings_provider.dart';

/// Main app settings notifier that persists all settings to database
class AppSettingsNotifier extends AsyncNotifier<AppSettingsState> {
  models.AppSettings? _remoteSettingsSnapshot;

  /// True only once a remote `GET /api/settings` (or a `__snapshot__` push)
  /// has populated real host settings. Guards remote writes: after a failed
  /// fetch `build()` remains in [AsyncError], and writes are refused until a
  /// good fetch lands so local defaults can never overwrite the host.
  bool _remoteFetchSucceeded = false;

  // Push-event subscription, live only when the
  // active backend is a NetworkBackend. The host emits one
  // `settings.changed` event per field that differs in a POST
  // /api/settings call; the notifier applies the change in-place so
  // every connected client stays consistent without re-fetching the
  // full settings blob.
  StreamSubscription<SkotiqEvent>? _settingsEventSub;

  /// `correlatingCommandId`s of POSTs this notifier itself originated, so its
  /// own echoes are dropped and a local write does not fight the in-flight UI
  /// by overwriting state with the value it just sent.
  /// Bounded at 64 entries — far more than any realistic in-flight
  /// burst, but cheap to keep.
  final List<String> _ownCommandIds = <String>[];

  /// Settings controls frequently emit several writes without awaiting each
  /// other (sliders, text fields, paired host/port inputs). Keep those writes
  /// in invocation order. This is especially important remotely, where every
  /// request carries a full settings snapshot and concurrent requests built
  /// from the same stale state would otherwise revert each other's fields.
  Future<void> _settingsWriteTail = Future<void>.value();
  // Per-filter autofocus updates are read-modify-write operations against one
  // JSON setting. Serialize the whole mutation (not just the final DAO write)
  // so quick edits to different fields or filters cannot overwrite each other
  // from the same stale snapshot.
  Future<void> _filterAutofocusWriteTail = Future<void>.value();
  int _backendGeneration = 0;
  bool _disposeHookRegistered = false;

  Future<void> _writeRemoteSettings(
    AppSettingsState settings, {
    required NetworkBackend backend,
    required int generation,
  }) async {
    if (generation != _backendGeneration ||
        !identical(ref.read(backendProvider), backend)) {
      throw StateError(
        'The settings host changed before this write could start. Try again.',
      );
    }

    if (!_remoteFetchSucceeded) {
      throw StateError(
        'Refusing remote settings write before a successful host fetch; '
        'a write now would overwrite host settings with local defaults',
      );
    }

    final remote = _toRemoteSettings(settings);
    // Generate a command id, register it in the
    // local echo-suppression list, and forward to the host. The host
    // stamps `correlatingCommandId` on every `settings.changed` event
    // emitted from this POST; our event handler drops events whose id
    // matches so we don't fight ourselves.
    final commandId = _generateLocalCommandId();
    _registerOwnCommandId(commandId);
    try {
      await backend.updateSettingsWithCommandId(remote, commandId: commandId);
    } catch (_) {
      _ownCommandIds.remove(commandId);
      rethrow;
    }
    if (generation != _backendGeneration ||
        !identical(ref.read(backendProvider), backend)) {
      throw StateError(
        'The settings host changed while saving. Verify the value on the new host.',
      );
    }
    _remoteSettingsSnapshot = remote;
  }

  /// Bounded FIFO insertion so the echo-suppression list doesn't grow
  /// without bound if the server is offline / dropping events.
  void _registerOwnCommandId(String id) {
    if (_ownCommandIds.length >= 64) {
      _ownCommandIds.removeAt(0);
    }
    _ownCommandIds.add(id);
  }

  /// Cheap, opaque command id generator. We deliberately don't pull
  /// `package:uuid` for one call site — a `timestamp-random` pair is
  /// collision-resistant enough for echo-suppression (the id only has
  /// to be unique among an individual client's recent in-flight
  /// writes).
  static int _commandIdCounter = 0;
  static String _generateLocalCommandId() {
    _commandIdCounter += 1;
    final ts = DateTime.now().microsecondsSinceEpoch;
    return 'settings-${ts.toRadixString(36)}-$_commandIdCounter';
  }

  /// Apply a single `settings.changed` event by
  /// merging its `{key, value}` into the current state. Returns silently
  /// when the event is malformed, the state is not yet loaded, or the
  /// originating command id matches one we wrote ourselves.
  void _applySettingsChangedEvent(SkotiqEvent event) {
    if (event.eventType != settingsChangedEventType) return;

    // Origin filter: drop our own echo so we don't churn the UI.
    final originId = event.correlatingCommandId;
    if (originId != null && _ownCommandIds.remove(originId)) {
      return;
    }

    final current = state.valueOrNull;
    if (current == null) {
      // The build() future is still resolving; the subsequent fetch
      // will include the new value, so skipping is correct.
      return;
    }

    final key = event.data['key'];
    if (key is! String || key.isEmpty) return;

    // Full-snapshot variant emitted when the host couldn't read the
    // previous settings (first-write / recovery path).
    if (key == '__snapshot__') {
      final snapshot = event.data['value'];
      if (snapshot is Map<String, dynamic>) {
        try {
          final remote = models.AppSettings.fromJson(snapshot);
          _remoteSettingsSnapshot = remote;
          _remoteFetchSucceeded = true;
          state = AsyncData(_fromRemoteSettings(remote));
        } catch (e, st) {
          developer.log(
            'settings.changed snapshot parse failed: $e\n$st',
            name: 'AppSettingsNotifier',
            level: 900,
          );
        }
      }
      return;
    }

    final value = event.data['value'];
    // Merge into the cached remote snapshot so future diffs are
    // accurate; the snapshot mirrors what the host has on disk.
    final snapshot = _remoteSettingsSnapshot;
    if (snapshot != null) {
      final updatedRemoteJson = Map<String, dynamic>.from(snapshot.toJson())
        ..[key] = value;
      try {
        _remoteSettingsSnapshot = models.AppSettings.fromJson(
          updatedRemoteJson,
        );
      } catch (e) {
        // Schema mismatch (e.g. forward-incompat key from a newer host).
        // Keep the previous snapshot to preserve diff integrity.
        developer.log(
          'settings.changed snapshot merge skipped for key=$key: $e',
          name: 'AppSettingsNotifier',
          level: 900,
        );
      }
    }

    final merged = _applyJsonSettingChange(current, key, value);
    if (merged != null && merged != current) {
      state = AsyncData(merged);
    }
  }

  @override
  Future<AppSettingsState> build() async {
    final generation = ++_backendGeneration;
    _remoteFetchSucceeded = false;
    _remoteSettingsSnapshot = null;
    _ownCommandIds.clear();
    _settingsWriteTail = Future<void>.value();
    final backend = ref.watch(backendProvider);

    // Tear down any previous subscription before
    // re-binding for the freshly-read backend. `build()` is called every
    // time the backend changes (FFI → Network → Disconnected etc.) and
    // each variant needs its own subscription policy. Await cancellation and
    // generation-gate callbacks so a late event from the previous host can
    // never mutate the newly selected host's settings.
    await _settingsEventSub?.cancel();
    _settingsEventSub = null;
    if (generation != _backendGeneration) {
      throw StateError('Settings backend changed while reloading.');
    }

    if (!_disposeHookRegistered) {
      _disposeHookRegistered = true;
      ref.onDispose(() {
        unawaited(_settingsEventSub?.cancel());
        _settingsEventSub = null;
      });
    }

    if (backend is NetworkBackend) {
      // Subscribe BEFORE the GET so an event that lands between the
      // POST acknowledgment and the GET's response can be re-applied
      // when the future resolves.
      _settingsEventSub = backend.eventStream.listen(
        (event) {
          if (generation != _backendGeneration ||
              !identical(ref.read(backendProvider), backend)) {
            return;
          }
          if (event.category != EventCategory.system) return;
          if (event.eventType != settingsChangedEventType) return;
          _applySettingsChangedEvent(event);
        },
        onError: (Object error) {
          if (generation != _backendGeneration) return;
          developer.log(
            'settings.changed stream error: $error',
            name: 'AppSettingsNotifier',
            level: 1000,
            error: error,
          );
        },
      );
      try {
        final remoteSettings = await backend.getSettings();
        if (generation != _backendGeneration ||
            !identical(ref.read(backendProvider), backend)) {
          throw StateError('Settings host changed while fetching.');
        }
        _remoteSettingsSnapshot = remoteSettings;
        _remoteFetchSucceeded = true;
        // Overlay this device's own display prefs on top of the host's —
        // theme/accent/font/UI-scale are per-device and were saved locally,
        // so a reconnect must not snap the phone back to the desktop's look.
        return _overlayDeviceLocalDisplayPrefs(
          _fromRemoteSettings(remoteSettings),
        );
      } catch (e, stackTrace) {
        developer.log(
          'Remote settings fetch failed: $e\n$stackTrace',
          name: 'AppSettingsNotifier',
          level: 1000,
          error: e,
          stackTrace: stackTrace,
        );
        Error.throwWithStackTrace(e, stackTrace);
      }
    }

    _remoteSettingsSnapshot = null;
    final dao = ref.read(settingsDaoProvider);
    final allSettings = await dao.getAllSettings();

    return _refreshPlateSolverProjection(_settingsFromStoredMap(allSettings));
  }

  /// `plate_solver` is a projection of the native `PlateSolverPreference`, not
  /// a store of its own — the dispatcher only ever reads the preference. A
  /// projection that is written but never re-read goes stale silently, and
  /// this one did: profiles seeded before the Plate Solving page existed still
  /// carried `plate_solver=ASTAP` while the preference said Auto, and that
  /// stale row is what backup export and the remote wire model served.
  ///
  /// A failure here is not a settings failure — an unreachable solver config
  /// (disconnected backend, bridge not loaded under test) just leaves the
  /// stored value in place rather than taking the whole settings load down.
  Future<AppSettingsState> _refreshPlateSolverProjection(
    AppSettingsState stored,
  ) async {
    try {
      final pref = await ref.read(plateSolveServiceProvider).getConfig();
      final label = pref.choice.settingLabel;
      if (label == stored.plateSolver) return stored;
      // Persist so backups and `/api/settings` stop serving the stale name
      // even if nothing writes a setting this session. Straight to the DAO,
      // not `_saveSetting`: this runs while `build()` is still resolving, so
      // the loaded-state guard and the remote write path do not apply — this
      // is by construction the local store.
      await ref.read(settingsDaoProvider).setSetting('plate_solver', label);
      return stored.copyWith(plateSolver: label);
    } catch (error) {
      developer.log(
        'Plate-solver preference unavailable; keeping the stored '
        'plate_solver projection: $error',
        name: 'AppSettingsNotifier',
      );
      return stored;
    }
  }

  /// Display preferences that belong to the DEVICE rendering the UI, not to
  /// the imaging host: theme (incl. red-night), accent colour, font size, UI
  /// scale, and the side-rail collapsed state. On a remote client these
  /// persist to the LOCAL store and never round-trip to the host. Before
  /// this, a paired phone pushed them over `POST /api/settings` — which is
  /// admin-scoped (so a control token got "Access denied: Token scope is not
  /// permitted", and the theme reverted) and, worse, would have reskinned
  /// the DESKTOP to match the phone.
  static const Set<String> _deviceLocalDisplayKeys = {
    'theme',
    'accent_color',
    'font_size',
    'ui_scale',
    'sidebar_collapsed',
  };

  Future<void> _saveSetting(String key, String value) {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    // Device-local display prefs always persist to the local store, even
    // under a NetworkBackend — they are this device's rendering choice.
    final isDeviceLocalDisplay = _deviceLocalDisplayKeys.contains(key);
    final dao = (backend is NetworkBackend && !isDeviceLocalDisplay)
        ? null
        : ref.read(settingsDaoProvider);
    return _serializeSettingsWrite(key, generation, () async {
      if (generation != _backendGeneration ||
          !identical(ref.read(backendProvider), backend)) {
        throw StateError('The settings host changed before saving $key.');
      }
      _requireLoadedSettings('saving $key');
      if (backend is NetworkBackend && !isDeviceLocalDisplay) {
        final current = _requireLoadedSettings('saving $key');
        final updated = _applySettingsMap(current, {key: value});
        await _writeRemoteSettings(
          updated,
          backend: backend,
          generation: generation,
        );
        // Patch before releasing the write queue so the next request builds
        // its full remote snapshot from this successful value. Patch only the
        // submitted field to preserve unrelated pushes from other clients.
        _patchState((latest) => _applySettingsMap(latest, {key: value}));
        return;
      }
      await dao!.setSetting(key, value);
      if (generation != _backendGeneration ||
          !identical(ref.read(backendProvider), backend) ||
          !identical(ref.read(settingsDaoProvider), dao)) {
        throw StateError(
          'The settings store changed while saving $key. Verify the value in '
          'the active store.',
        );
      }
      // Local state is patched by the calling section setter after this write
      // resolves; the DAO persists every DB key directly, so there is no need
      // to project the change back into state here. Deliberately NOT routed
      // through `_applySettingsMap`, whose `_assertKeysRemotable` guard is a
      // remote-write concern and would wrongly reject host-only keys
      // (`start_minimized`, `database_path`, `horizon_profile_json`, ...).
    });
  }

  /// Apply this device's locally-stored display prefs (theme / accent / font
  /// size / UI scale) on top of a state built from the remote host, so the
  /// operator's per-device look survives a reconnect. Best-effort: a read
  /// failure or an unset key leaves the host value in place.
  Future<AppSettingsState> _overlayDeviceLocalDisplayPrefs(
    AppSettingsState fromHost,
  ) async {
    try {
      final dao = ref.read(settingsDaoProvider);
      var merged = fromHost;
      for (final key in _deviceLocalDisplayKeys) {
        final local = await dao.getSetting(key);
        if (local == null) continue;
        final next = _applyJsonSettingChange(merged, key, local);
        if (next != null) merged = next;
      }
      return merged;
    } catch (e) {
      // Display-only overlay: on failure the operator sees the host's theme
      // instead of this device's, which is visible and self-correcting. It is
      // logged because the same failure means the local settings DAO is not
      // readable, and that has non-cosmetic consequences elsewhere.
      developer.log(
        'Could not overlay device-local display preferences on host settings; '
        'keeping the host values: $e',
        name: 'AppSettings',
        level: 900,
      );
      return fromHost;
    }
  }

  Future<void> _saveSettings(Map<String, String> settings) {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    final dao = backend is NetworkBackend
        ? null
        : ref.read(settingsDaoProvider);
    return _serializeSettingsWrite(
      settings.keys.join(', '),
      generation,
      () async {
        if (generation != _backendGeneration ||
            !identical(ref.read(backendProvider), backend)) {
          throw StateError('The settings host changed before saving.');
        }
        _requireLoadedSettings('saving ${settings.keys.join(', ')}');
        if (backend is NetworkBackend) {
          final current = _requireLoadedSettings(
            'saving ${settings.keys.join(', ')}',
          );
          final updated = _applySettingsMap(current, settings);
          await _writeRemoteSettings(
            updated,
            backend: backend,
            generation: generation,
          );
          _patchState((latest) => _applySettingsMap(latest, settings));
          return;
        }
        await dao!.setSettings(settings);
        if (generation != _backendGeneration ||
            !identical(ref.read(backendProvider), backend) ||
            !identical(ref.read(settingsDaoProvider), dao)) {
          throw StateError(
            'The settings store changed while saving. Verify the values in '
            'the active store.',
          );
        }
        // Local state is patched by the calling section setter after this
        // write resolves (see `_saveSetting`). Not routed through
        // `_applySettingsMap` here so the remote-only `_assertKeysRemotable`
        // guard can't reject host-only batched keys (e.g. the
        // `default_image_directory` compatibility key co-written by
        // `setImageOutputPath`).
      },
    );
  }

  Future<void> _serializeSettingsWrite(
    String setting,
    int generation,
    Future<void> Function() write,
  ) {
    final tail = _settingsWriteTail;
    final operation = tail.then((_) {
      if (generation != _backendGeneration) {
        throw StateError('The settings host changed before saving $setting.');
      }
      return write();
    });
    _settingsWriteTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    unawaited(
      operation.then<void>(
        (_) {
          final failure = ref.read(appSettingsWriteFailureProvider);
          if (failure?.setting == setting) {
            ref.read(appSettingsWriteFailureProvider.notifier).state = null;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'Settings write failed for $setting: $error',
            name: 'AppSettingsNotifier',
            level: 1000,
            error: error,
            stackTrace: stackTrace,
          );
          ref
              .read(appSettingsWriteFailureProvider.notifier)
              .state = AppSettingsWriteFailure(
            setting: setting,
            error: error,
            occurredAt: DateTime.now(),
          );
        },
      ),
    );
    return operation;
  }

  /// Helper to update a single field in the current AppSettingsState.
  ///
  /// If the state was invalidated after a successful database write, the update
  /// is skipped because the replacement load will read that persisted value.
  void _patchState(
    AppSettingsState Function(AppSettingsState current) updater,
  ) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(updater(current));
  }

  /// Read-side companion to [_patchState] for section extensions.
  ///
  /// Section setters live in `settings_sections/*.dart` as extensions on this
  /// class. Riverpod's [AsyncNotifier.state] is `@protected` /
  /// `@visibleForTesting`, and the analyzer does not treat extension members as
  /// "instance members of subclasses", so reaching for `state` directly from a
  /// section file is a static warning. Sections that need the current value
  /// (e.g. read-modify-write of a JSON map) go through this accessor instead,
  /// keeping all `state` access inside the notifier class body.
  AppSettingsState? get _currentValueOrNull => state.valueOrNull;

  AppSettingsState _requireLoadedSettings(String action) {
    final current = state.valueOrNull;
    if (current == null) {
      throw StateError(
        'Application settings are unavailable; refusing $action because it '
        'could overwrite stored settings with defaults.',
      );
    }
    return current;
  }

  /// Test-only: round-trip a state through the stored-map serialiser and back.
  ///
  /// Exposed (instead of the two private mapping helpers) so the inverse
  /// invariant `_settingsFromStoredMap(_storedMapFromState(s)) == s` can be
  /// asserted exhaustively without leaking the DB-key map representation. See
  /// `app_settings_stored_roundtrip_test.dart`. The two helpers are extension
  /// methods that dispatch through `this`, hence this lives on the notifier.
  @visibleForTesting
  AppSettingsState debugRoundTripThroughStoredMap(AppSettingsState s) =>
      _settingsFromStoredMap(_storedMapFromState(s));

  /// Test-only: the stored DB-key snapshot for [s]. See
  /// [debugRoundTripThroughStoredMap].
  @visibleForTesting
  Map<String, String> debugStoredMapFromState(AppSettingsState s) =>
      _storedMapFromState(s);

  /// Apply a full remote [models.AppSettings] on the HOST and persist EVERY
  /// field to the database — the same store the desktop reads and writes.
  ///
  /// The remote wire model only carries the remotable subset, so we overlay
  /// those fields onto the current state (preserving host-only settings such as
  /// `database_path` / `logs_path` that are deliberately non-remotable) and
  /// then write the complete snapshot in one transaction. This is what the
  /// headless `POST /api/settings` uses so remote settings actually persist,
  /// instead of being silently dropped by the 7-field Rust-bridge round-trip
  /// (the original B16 bug).
  ///
  /// MUST run on a host container (non-[NetworkBackend]) — the desktop or the
  /// headless server itself; on that path [_saveSettings] writes straight to
  /// the [SettingsDao]. (On a network client, settings flow through the section
  /// setters / `_writeRemoteSettings` instead.)
  Future<void> applyRemoteSettings(models.AppSettings remote) async {
    final backend = ref.read(backendProvider);
    if (backend is NetworkBackend) {
      throw StateError(
        'applyRemoteSettings is host-only; refusing to relay a full snapshot '
        'through a remote client.',
      );
    }
    final generation = _backendGeneration;
    final dao = ref.read(settingsDaoProvider);
    await _serializeSettingsWrite(
      'remote settings snapshot',
      generation,
      () async {
        if (generation != _backendGeneration ||
            !identical(ref.read(backendProvider), backend) ||
            !identical(ref.read(settingsDaoProvider), dao)) {
          throw StateError(
            'The settings store changed before applying the remote snapshot.',
          );
        }

        final before = _requireLoadedSettings(
          'applying a remote settings snapshot',
        );
        var next = before;
        remote.toJson().forEach((key, value) {
          final updated = _applyJsonSettingChange(next, key, value);
          if (updated != null) next = updated;
        });

        // `plateSolver` is a read-only projection of the native
        // PlateSolverPreference — the only store the solve dispatcher reads —
        // so a settings snapshot must not be able to move it. Two reasons this
        // is pinned rather than applied: writing the row would change nothing
        // about which engine runs (an acknowledged write the solver never
        // sees), and the wire model defaults this field to 'ASTAP', so a
        // partial POST built without a previous snapshot would otherwise
        // announce a switch away from the operator's actual selection.
        // Clients change the engine through setPlateSolverConfig, which
        // reaches the store that matters; the value echoed back here stays
        // truthful either way.
        next = next.copyWith(plateSolver: before.plateSolver);

        await dao.setSettings(_storedMapFromState(next));
        if (generation != _backendGeneration ||
            !identical(ref.read(backendProvider), backend) ||
            !identical(ref.read(settingsDaoProvider), dao)) {
          throw StateError(
            'The settings store changed while applying the remote snapshot. '
            'Verify the values in the active store.',
          );
        }
        state = AsyncData(next);
      },
    );
  }

  /// The current settings projected to the remote wire model — companion to
  /// [applyRemoteSettings] for the headless `GET /api/settings` handler.
  models.AppSettings exportRemoteSettings() => _toRemoteSettings(
    _requireLoadedSettings('exporting a remote settings snapshot'),
  );

  // Section setters are defined in `settings_sections/*.dart` (split via
  // Dart `part` files). The class body below keeps only the lifecycle
  // (build), persistence writes (_saveSetting, _saveSettings), remote-sync
  // glue that needs protected notifier state, and the state accessors reused
  // by section extensions. Translation helpers live in the adjacent mapping
  // parts.
}

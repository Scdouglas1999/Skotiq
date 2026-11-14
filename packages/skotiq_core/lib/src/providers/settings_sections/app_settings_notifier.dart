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
  // app is a linked client. The host emits one
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
  // Backlash-calibration settings are the same shape of problem — one JSON
  // blob, several field editors — so they get their own serialized
  // read-modify-write tail rather than sharing the filter one.
  Future<void> _focuserBacklashCalibrationWriteTail = Future<void>.value();
  int _backendGeneration = 0;
  bool _disposeHookRegistered = false;
  StreamSubscription<Set<String>>? _hostStoreSub;

  /// Rows the notifier owns that the host's typed settings model does not
  /// carry. A linked client reads and writes them through the host's key/value
  /// store, and the host applies them through this notifier so its own copy
  /// stays current.
  static final Set<String> hostStoreKeys = AppSettingsCodec.hostStoreKeys;

  /// Every `app_settings` key this notifier reads and writes.
  static final Set<String> storedKeys = AppSettingsCodec.storedKeys;

  /// Fields of the host's typed settings that only a link with admin access
  /// to the host may change, and why.
  static final Map<String, AdminOnly> adminOnlyWireFields =
      AppSettingsCodec.adminOnlyWireFields;

  /// Every field of the host's typed settings a setting stands behind.
  static final Set<String> wireFields = AppSettingsCodec.wireFields;

  /// [settings] as the stored rows would hold them.
  Map<String, String> storedRowsOf(AppSettingsState settings) =>
      AppSettingsCodec.toRows(settings);

  /// Save stored rows through the same path as the section setters: the host
  /// on a linked client, this computer's database otherwise. On the local path
  /// the state is rebuilt from the merged rows, since no section setter is
  /// there to patch it.
  Future<void> saveRows(Map<String, String> rows) async {
    if (rows.isEmpty) return;
    final unknown = rows.keys.where((k) => !storedKeys.contains(k)).toList();
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(
        unknown,
        'rows',
        'not settings this notifier stores',
      );
    }
    await _saveSettings(rows);
    if (!ref.read(isRemoteModeProvider)) {
      _patchState(
        (current) => AppSettingsCodec.fromRows({
          ...AppSettingsCodec.toRows(current),
          ...rows,
        }),
      );
    }
  }

  /// On a linked client, replace the [hostStoreKeys] in [fromHost] with the
  /// host's own rows and follow later changes to them. A host too old to serve
  /// its key/value store leaves the typed model's values in place.
  Future<AppSettingsState> _overlayHostStoreRows(
    AppSettingsState fromHost,
    int generation,
  ) async {
    final store = ref.read(hostSettingsStoreProvider);
    if (store == null) return fromHost;
    try {
      await store.ensureLoaded();
    } catch (e) {
      Log.warning(
        'Host key/value settings unavailable; keeping the typed values for '
        '${hostStoreKeys.join(', ')}: $e',
        source: 'AppSettingsNotifier',
      );
      return fromHost;
    }
    if (generation != _backendGeneration) return fromHost;
    _hostStoreSub = store.changes.listen((keys) {
      if (generation != _backendGeneration) return;
      _applyHostRowChanges(keys, store.values);
    });
    return _applyHostStoreRows(fromHost, store.values);
  }

  /// Keys with a write from this client queued or on the wire, and how many.
  /// A host row change for one of them is not applied: it can only be this
  /// client's own value or an older one, and the write settles it.
  final Map<String, int> _pendingRemoteKeys = <String, int>{};

  void _trackPendingRemoteWrite(Iterable<String> keys, Future<void> write) {
    final tracked = keys.toList();
    for (final key in tracked) {
      _pendingRemoteKeys[key] = (_pendingRemoteKeys[key] ?? 0) + 1;
    }
    unawaited(
      write.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        for (final key in tracked) {
          final left = (_pendingRemoteKeys[key] ?? 1) - 1;
          if (left <= 0) {
            _pendingRemoteKeys.remove(key);
          } else {
            _pendingRemoteKeys[key] = left;
          }
        }
      }),
    );
  }

  /// Apply rows the host reports changed to this client's state, per key.
  ///
  /// The host announces every write to its settings rows, including the ones
  /// its own screen makes, which never produce a `settings.changed` event.
  /// Without this, a change made on the host's screen reached this client only
  /// at the next periodic re-fetch, and a save made here in the meantime sent
  /// the old value back.
  void _applyHostRowChanges(Set<String> keys, Map<String, String> rows) {
    final storeRows = keys.any(hostStoreKeys.contains);
    final typed = <String, String>{
      for (final key in keys)
        if (!hostStoreKeys.contains(key) &&
            AppSettingsCodec.hostKeys.contains(key) &&
            !AppSettingsCodec.clientOwnKeys.contains(key) &&
            !_pendingRemoteKeys.containsKey(key) &&
            rows.containsKey(key))
          key: rows[key]!,
    };
    if (!storeRows && typed.isEmpty) return;
    _patchState((current) {
      var next = current;
      if (storeRows) next = _applyHostStoreRows(next, rows);
      if (typed.isNotEmpty) next = _applySettingsMap(next, typed);
      return next;
    });
  }

  AppSettingsState _applyHostStoreRows(
    AppSettingsState current,
    Map<String, String> rows,
  ) => AppSettingsCodec.applyRows(current, {
    for (final key in hostStoreKeys)
      if (rows.containsKey(key)) key: rows[key]!,
  });

  /// Host side of `POST /api/settings/store` for [hostStoreKeys]: persist the
  /// rows locally and patch the state, so the host's in-memory settings and
  /// its database agree.
  Future<void> applyHostStoreRows(Map<String, String> rows) async {
    if (ref.read(isRemoteModeProvider)) {
      throw StateError('applyHostStoreRows is host-only.');
    }
    final unknown = rows.keys.where((k) => !hostStoreKeys.contains(k));
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(unknown.toList(), 'rows');
    }
    await future;
    await _saveSettings(rows);
    _patchState((current) => _applyHostStoreRows(current, rows));
  }

  Future<void> _writeRemoteSettings(
    AppSettingsState before,
    AppSettingsState settings, {
    required SkotiqBackend backend,
    required int generation,
  }) async {
    final host = ref.read(linkedHostRigSettingsProvider);
    if (host == null ||
        generation != _backendGeneration ||
        ref.backendScopeOver(backend).isStale) {
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

    final remote = _toWire(settings);
    // Send only the fields this save changes. The host merges them onto its
    // current settings, so a field changed elsewhere since this client last
    // read it (on the host's own screen, say) keeps that value instead of
    // being reverted by this client's copy.
    final patch = remoteSettingsPatch(_toWire(before), remote);
    if (patch.isEmpty) {
      _remoteSettingsSnapshot = remote;
      return;
    }
    // Generate a command id, register it in the
    // local echo-suppression list, and forward to the host. The host
    // stamps `correlatingCommandId` on every `settings.changed` event
    // emitted from this POST; our event handler drops events whose id
    // matches so we don't fight ourselves.
    final commandId = _generateLocalCommandId();
    _registerOwnCommandId(commandId);
    try {
      await host.updateSettingsPatchWithCommandId(patch, commandId: commandId);
    } catch (_) {
      _ownCommandIds.remove(commandId);
      rethrow;
    }
    if (generation != _backendGeneration ||
        ref.backendScopeOver(backend).isStale) {
      throw StateError(
        'The settings host changed while saving. Verify the value on the new host.',
      );
    }
    _remoteSettingsSnapshot = remote;
  }

  Future<void> _writeHostStoreRows(
    Map<String, String> rows,
    SkotiqBackend backend,
    int generation,
  ) async {
    final store = ref.read(hostSettingsStoreProvider);
    if (store == null) {
      throw StateError('No imaging host is linked to store these settings.');
    }
    await store.write(rows);
    if (generation != _backendGeneration ||
        ref.backendScopeOver(backend).isStale) {
      throw StateError(
        'The settings host changed while saving. Verify the value on the new host.',
      );
    }
    _patchState((latest) => _applyHostStoreRows(latest, rows));
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
    if (key == settingsSnapshotKey) {
      final snapshot = event.data['value'];
      if (snapshot is Map<String, dynamic>) {
        try {
          final remote = models.AppSettings.fromJson(snapshot);
          _remoteSettingsSnapshot = remote;
          _remoteFetchSucceeded = true;
          state = AsyncData(AppSettingsCodec.fromWire(remote));
        } catch (e, st) {
          Log.warning(
            'settings.changed snapshot parse failed: $e\n$st',
            source: 'AppSettingsNotifier',
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
        Log.warning(
          'settings.changed snapshot merge skipped for key=$key: $e',
          source: 'AppSettingsNotifier',
        );
      }
    }

    final merged = AppSettingsCodec.applyWireChange(current, key, value);
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
    _pendingRemoteKeys.clear();
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
    await _hostStoreSub?.cancel();
    _hostStoreSub = null;
    if (generation != _backendGeneration) {
      throw StateError('Settings backend changed while reloading.');
    }

    if (!_disposeHookRegistered) {
      _disposeHookRegistered = true;
      ref.onDispose(() {
        unawaited(_settingsEventSub?.cancel());
        _settingsEventSub = null;
        unawaited(_hostStoreSub?.cancel());
        _hostStoreSub = null;
      });
    }

    if (backend.linksToHost) {
      // Subscribe BEFORE the GET so an event that lands between the
      // POST acknowledgment and the GET's response can be re-applied
      // when the future resolves.
      _settingsEventSub = backend.eventStream.listen(
        (event) {
          if (generation != _backendGeneration ||
              ref.backendScopeOver(backend).isStale) {
            return;
          }
          if (event.category != EventCategory.system) return;
          if (event.eventType != settingsChangedEventType) return;
          _applySettingsChangedEvent(event);
        },
        onError: (Object error) {
          if (generation != _backendGeneration) return;
          Log.error(
            'settings.changed stream error: $error',
            source: 'AppSettingsNotifier',
            error: error,
          );
        },
      );
      try {
        final remoteSettings = await backend.getSettings();
        if (generation != _backendGeneration ||
            ref.backendScopeOver(backend).isStale) {
          throw StateError('Settings host changed while fetching.');
        }
        _remoteSettingsSnapshot = remoteSettings;
        _remoteFetchSucceeded = true;
        // Overlay this device's own display prefs on top of the host's —
        // theme/accent/font/UI-scale are per-device and were saved locally,
        // so a reconnect must not snap the phone back to the desktop's look.
        final fromHost = await _overlayHostStoreRows(
          AppSettingsCodec.fromWire(remoteSettings),
          generation,
        );
        return _overlayDeviceLocalDisplayPrefs(fromHost);
      } catch (e, stackTrace) {
        Log.error(
          'Remote settings fetch failed: $e\n$stackTrace',
          source: 'AppSettingsNotifier',
          error: e,
          stackTrace: stackTrace,
        );
        Error.throwWithStackTrace(e, stackTrace);
      }
    }

    _remoteSettingsSnapshot = null;
    final dao = ref.read(settingsDaoProvider);
    final allSettings = await dao.getAllSettings();

    return _refreshPlateSolverProjection(
      AppSettingsCodec.fromRows(allSettings),
    );
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
      Log.debug(
        'Plate-solver preference unavailable; keeping the stored '
        'plate_solver projection: $error',
        source: 'AppSettingsNotifier',
      );
      return stored;
    }
  }

  Future<void> _saveSetting(String key, String value) {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    // Device-local display prefs always persist to the local store, even
    // on a linked client — they are this device's rendering choice.
    final isDeviceLocalDisplay = AppSettingsCodec.clientOwnKeys.contains(key);
    final dao = (backend.linksToHost && !isDeviceLocalDisplay)
        ? null
        : ref.read(settingsDaoProvider);
    final write = _serializeSettingsWrite(key, generation, () async {
      if (generation != _backendGeneration ||
          ref.backendScopeOver(backend).isStale) {
        throw StateError('The settings host changed before saving $key.');
      }
      _requireLoadedSettings('saving $key');
      if (backend.linksToHost && hostStoreKeys.contains(key)) {
        await _writeHostStoreRows({key: value}, backend, generation);
        return;
      }
      if (backend.linksToHost && !isDeviceLocalDisplay) {
        final current = _requireLoadedSettings('saving $key');
        final updated = _applySettingsMap(current, {key: value});
        await _writeRemoteSettings(
          current,
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
          ref.backendScopeOver(backend).isStale ||
          ref.scopeOver(settingsDaoProvider, dao).isStale) {
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
    if (backend.linksToHost && !isDeviceLocalDisplay) {
      _trackPendingRemoteWrite([key], write);
    }
    return write;
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
      final own = <String, String>{};
      for (final key in AppSettingsCodec.clientOwnKeys) {
        final local = await dao.getSetting(key);
        if (local != null) own[key] = local;
      }
      return AppSettingsCodec.applyRows(fromHost, own);
    } catch (e) {
      // Display-only overlay: on failure the operator sees the host's theme
      // instead of this device's, which is visible and self-correcting. It is
      // logged because the same failure means the local settings DAO is not
      // readable, and that has non-cosmetic consequences elsewhere.
      Log.warning(
        'Could not overlay device-local display preferences on host settings; '
        'keeping the host values: $e',
        source: 'AppSettings',
      );
      return fromHost;
    }
  }

  Future<void> _saveSettings(Map<String, String> settings) {
    final backend = ref.read(backendProvider);
    final generation = _backendGeneration;
    final dao = backend.linksToHost ? null : ref.read(settingsDaoProvider);
    final write = _serializeSettingsWrite(
      settings.keys.join(', '),
      generation,
      () async {
        if (generation != _backendGeneration ||
            ref.backendScopeOver(backend).isStale) {
          throw StateError('The settings host changed before saving.');
        }
        _requireLoadedSettings('saving ${settings.keys.join(', ')}');
        if (backend.linksToHost) {
          final storeRows = {
            for (final entry in settings.entries)
              if (hostStoreKeys.contains(entry.key)) entry.key: entry.value,
          };
          final typed = {
            for (final entry in settings.entries)
              if (!hostStoreKeys.contains(entry.key)) entry.key: entry.value,
          };
          if (storeRows.isNotEmpty) {
            await _writeHostStoreRows(storeRows, backend, generation);
          }
          if (typed.isEmpty) return;
          final current = _requireLoadedSettings(
            'saving ${typed.keys.join(', ')}',
          );
          final updated = _applySettingsMap(current, typed);
          await _writeRemoteSettings(
            current,
            updated,
            backend: backend,
            generation: generation,
          );
          _patchState((latest) => _applySettingsMap(latest, typed));
          return;
        }
        await dao!.setSettings(settings);
        if (generation != _backendGeneration ||
            ref.backendScopeOver(backend).isStale ||
            ref.scopeOver(settingsDaoProvider, dao).isStale) {
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
    if (backend.linksToHost) {
      _trackPendingRemoteWrite(settings.keys, write);
    }
    return write;
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
          Log.error(
            'Settings write failed for $setting: $error',
            source: 'AppSettingsNotifier',
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
  /// invariant `AppSettingsCodec.fromRows(AppSettingsCodec.toRows(s)) == s` can be
  /// asserted exhaustively without leaking the DB-key map representation. See
  /// `app_settings_stored_roundtrip_test.dart`. The two helpers are extension
  /// methods that dispatch through `this`, hence this lives on the notifier.
  @visibleForTesting
  AppSettingsState debugRoundTripThroughStoredMap(AppSettingsState s) =>
      AppSettingsCodec.fromRows(AppSettingsCodec.toRows(s));

  /// Test-only: the stored DB-key snapshot for [s]. See
  /// [debugRoundTripThroughStoredMap].
  @visibleForTesting
  Map<String, String> debugStoredMapFromState(AppSettingsState s) =>
      AppSettingsCodec.toRows(s);

  /// Test-only: the state a stored DB-key snapshot loads as.
  @visibleForTesting
  AppSettingsState debugSettingsFromStoredMap(Map<String, String> stored) =>
      AppSettingsCodec.fromRows(stored);

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
  /// MUST run on a host container (not a linked client) — the desktop or the
  /// headless server itself; on that path [_saveSettings] writes straight to
  /// the [SettingsDao]. (On a network client, settings flow through the section
  /// setters / `_writeRemoteSettings` instead.)
  Future<void> applyRemoteSettings(models.AppSettings remote) async {
    final backend = ref.read(backendProvider);
    if (backend.linksToHost) {
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
            ref.backendScopeOver(backend).isStale ||
            ref.scopeOver(settingsDaoProvider, dao).isStale) {
          throw StateError(
            'The settings store changed before applying the remote snapshot.',
          );
        }

        final before = _requireLoadedSettings(
          'applying a remote settings snapshot',
        );
        var next = before;
        remote.toJson().forEach((key, value) {
          final updated = AppSettingsCodec.applyWireChange(next, key, value);
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

        await dao.setSettings(AppSettingsCodec.toRows(next));
        if (generation != _backendGeneration ||
            ref.backendScopeOver(backend).isStale ||
            ref.scopeOver(settingsDaoProvider, dao).isStale) {
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
  models.AppSettings exportRemoteSettings() =>
      _toWire(_requireLoadedSettings('exporting a remote settings snapshot'));

  // Section setters are defined in `settings_sections/*.dart` (split via
  // Dart `part` files). The class body below keeps only the lifecycle
  // (build), persistence writes (_saveSetting, _saveSettings), remote-sync
  // glue that needs protected notifier state, and the state accessors reused
  // by section extensions. Translation helpers live in the adjacent mapping
  // parts.

  models.AppSettings _toWire(AppSettingsState settings) =>
      AppSettingsCodec.toWire(settings, previous: _remoteSettingsSnapshot);

  /// [current] with [rows] applied, for a write a linked client sends to the
  /// host. A row the host's typed settings cannot carry would be dropped
  /// there, leaving the client showing a value that never took effect, so it
  /// is refused here instead.
  AppSettingsState _applySettingsMap(
    AppSettingsState current,
    Map<String, String> rows,
  ) {
    final unsupported = rows.keys
        .where((key) => !AppSettingsCodec.hostKeys.contains(key))
        .toList();
    if (unsupported.isNotEmpty) {
      throw UnsupportedError(
        'Cannot save setting${unsupported.length == 1 ? '' : 's'} on the '
        'host: ${unsupported.join(', ')}. The host\'s settings do not carry '
        '${unsupported.length == 1 ? 'it' : 'them'}.',
      );
    }
    return AppSettingsCodec.applyRows(current, rows);
  }

  /// Save [value] for [setting] and show it.
  Future<void> _set<T>(Setting<T> setting, T value) =>
      _setAll([setting.to(value)]);

  /// Save several settings in one write and show them.
  Future<void> _setAll(List<SettingValue<Object?>> values) async {
    final remote = ref.read(isRemoteModeProvider);
    final rows = <String, String>{
      for (final entry in values)
        for (final row in entry.rows.entries)
          // A mirrored older row exists only in this computer's database.
          if (!remote || row.key == entry.setting.key) row.key: row.value,
    };
    if (rows.length == 1) {
      await _saveSetting(rows.keys.single, rows.values.single);
    } else {
      await _saveSettings(rows);
    }
    _patchState((current) {
      var next = current;
      for (final entry in values) {
        next = next.withValue(entry.setting, entry.value);
      }
      return next;
    });
  }
}

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show mapEquals, visibleForTesting;

import '../../backend/network_backend.dart';
import '../../models/backend/host_mutation_event.dart';

/// How much of the imaging host's key/value settings this client can reach.
enum HostSettingsStoreSupport {
  /// The first fetch has not finished.
  unknown,

  /// The host serves `/api/settings/store`: every host-owned row is mirrored.
  full,

  /// The host predates `/api/settings/store`. Only the `science.*` and
  /// `smart_night.*` rows, which have their own endpoints, are mirrored; the
  /// rest of the host's rows cannot be read from this client.
  legacy,
}

/// The imaging host's `app_settings` rows as a linked client sees them.
///
/// Reads come from an in-memory snapshot fetched from the host; writes go to
/// the host first and update the snapshot only once the host accepted them.
/// [refresh] re-fetches at most once per [minRefreshInterval] however often it
/// is asked, and [changes] fires only for keys whose value actually differs
/// from the snapshot, so a host that announces settings activity many times a
/// second costs one small request per interval and no rebuilds.
class HostSettingsStore {
  HostSettingsStore(
    this._backend, {
    this.minRefreshInterval = const Duration(seconds: 2),
  });

  final NetworkBackend _backend;
  final Duration minRefreshInterval;

  /// Prefixes a legacy host serves through their own endpoints.
  static const String sciencePrefix = 'science.';
  static const String smartNightPrefix = 'smart_night.';

  Map<String, String> _values = const {};
  HostSettingsStoreSupport _support = HostSettingsStoreSupport.unknown;
  Future<void>? _initialLoad;
  Future<void>? _inFlight;
  Timer? _refreshTimer;
  bool _refreshQueued = false;
  DateTime? _lastRefreshStarted;
  int _writeGeneration = 0;
  bool _disposed = false;

  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();
  final Set<String> _unsharedKeys = <String>{};
  final StreamController<Set<String>> _unsharedChanges =
      StreamController<Set<String>>.broadcast();

  /// Keys whose host value changed under this client, from another client or
  /// from the host itself. Never fires for this client's own writes.
  Stream<Set<String>> get changes => _changes.stream;

  HostSettingsStoreSupport get support => _support;

  /// Host-owned keys this client has needed but the host could not serve, so
  /// their values came from this computer's own database.
  Set<String> get unsharedKeys => Set.unmodifiable(_unsharedKeys);

  /// Fires with [unsharedKeys] whenever a new key joins it.
  Stream<Set<String>> get unsharedKeyChanges => _unsharedChanges.stream;

  /// Record that [key] was read or written on this computer because the host
  /// cannot serve it.
  void noteUnsharedKey(String key) {
    if (_disposed || !_unsharedKeys.add(key)) return;
    _unsharedChanges.add(unsharedKeys);
  }

  /// The snapshot as last fetched or written.
  Map<String, String> get values => _values;

  /// Wait for the first fetch. A failed fetch is rethrown, and the next call
  /// tries again rather than serving an empty snapshot as the host's values.
  Future<void> ensureLoaded() {
    final pending = _initialLoad;
    if (pending != null) return pending;
    _followHostAnnouncements();
    final load = _fetchAndApply(notify: false);
    _initialLoad = load;
    load.catchError((Object _) {
      if (identical(_initialLoad, load)) _initialLoad = null;
    });
    return load;
  }

  /// Whether this client can read and write [key] on the host.
  bool covers(String key) {
    switch (_support) {
      case HostSettingsStoreSupport.full:
        return true;
      case HostSettingsStoreSupport.legacy:
        return key.startsWith(sciencePrefix) ||
            key.startsWith(smartNightPrefix);
      case HostSettingsStoreSupport.unknown:
        return false;
    }
  }

  /// Write [settings] to the host and drop [remove] from it.
  ///
  /// Throws [StateError] for a key the host cannot store, so the caller's
  /// write fails visibly instead of landing somewhere nobody reads it.
  Future<void> write(
    Map<String, String> settings, {
    List<String> remove = const [],
  }) async {
    await ensureLoaded();
    final keys = {...settings.keys, ...remove};
    final uncovered = keys.where((k) => !covers(k)).toList();
    if (uncovered.isNotEmpty) {
      throw HostSettingUnavailableError(uncovered);
    }
    _writeGeneration++;
    if (_support == HostSettingsStoreSupport.full) {
      await _backend.updateSettingsStore(settings, remove: remove);
    } else {
      if (remove.isNotEmpty) {
        throw HostSettingUnavailableError(remove);
      }
      final science = <String, String>{};
      final smartNight = <String, String>{};
      settings.forEach((key, value) {
        (key.startsWith(sciencePrefix) ? science : smartNight)[key] = value;
      });
      if (science.isNotEmpty) await _backend.updateScienceSettings(science);
      if (smartNight.isNotEmpty) {
        await _backend.updateSmartNightSettings(smartNight);
      }
    }
    _writeGeneration++;
    final next = Map<String, String>.from(_values)..addAll(settings);
    for (final key in remove) {
      next.remove(key);
    }
    _values = Map.unmodifiable(next);
  }

  /// The `namespace` a host mutation carries when it changed rows this store
  /// mirrors.
  static const Set<String> mirroredNamespaces = {
    'store',
    'science',
    'smart-night',
  };

  StreamSubscription<Object?>? _hostEvents;

  /// Refresh whenever the host announces a change to rows this store mirrors.
  void _followHostAnnouncements() {
    if (_hostEvents != null || _disposed) return;
    _hostEvents = _backend.eventStream.listen((event) {
      if (event.eventType != hostStateChangedEventType) return;
      if (event.data['entityType'] != HostMutationEntity.settings) return;
      if (!mirroredNamespaces.contains(event.data['namespace'])) return;
      refresh();
    }, onError: (Object _) {});
  }

  /// Re-fetch the host's rows, coalescing calls into at most one request per
  /// [minRefreshInterval].
  void refresh() {
    if (_disposed) return;
    if (_inFlight != null || _refreshTimer != null) {
      _refreshQueued = true;
      return;
    }
    final last = _lastRefreshStarted;
    final wait = last == null
        ? Duration.zero
        : minRefreshInterval - DateTime.now().difference(last);
    if (wait > Duration.zero) {
      _refreshTimer = Timer(wait, () {
        _refreshTimer = null;
        _startRefresh();
      });
      return;
    }
    _startRefresh();
  }

  void _startRefresh() {
    if (_disposed) return;
    _refreshQueued = false;
    final run = _fetchAndApply(notify: true).catchError((Object error) {
      developer.log(
        'Could not refresh the imaging host settings: $error',
        name: 'HostSettingsStore',
        level: 900,
      );
    });
    _inFlight = run;
    run.whenComplete(() {
      _inFlight = null;
      if (_refreshQueued) refresh();
    });
  }

  Future<void> _fetchAndApply({required bool notify}) async {
    _lastRefreshStarted = DateTime.now();
    final generation = _writeGeneration;
    final fetched = await _fetch();
    if (_disposed) return;
    if (generation != _writeGeneration) {
      // A write landed while this fetch was on the wire, so the response may
      // predate it. Fetch again rather than reverting the snapshot.
      _refreshQueued = true;
      return;
    }
    final previous = _values;
    _values = Map.unmodifiable(fetched);
    if (!notify || mapEquals(previous, fetched)) return;
    final changed = <String>{
      for (final key in {...previous.keys, ...fetched.keys})
        if (previous[key] != fetched[key]) key,
    };
    if (changed.isNotEmpty) _changes.add(changed);
  }

  Future<Map<String, String>> _fetch() async {
    final store = await _backend.getSettingsStore();
    if (store != null) {
      _support = HostSettingsStoreSupport.full;
      return store;
    }
    _support = HostSettingsStoreSupport.legacy;
    final results = await Future.wait([
      _backend.getScienceSettings(),
      _backend.getSmartNightSettings(),
    ]);
    return {...results[0], ...results[1]};
  }

  @visibleForTesting
  bool get hasPendingRefresh => _inFlight != null || _refreshTimer != null;

  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    unawaited(_hostEvents?.cancel());
    unawaited(_changes.close());
    unawaited(_unsharedChanges.close());
  }
}

/// A write named settings the connected imaging host cannot store.
class HostSettingUnavailableError extends StateError {
  HostSettingUnavailableError(this.keys)
    : super(
        'The imaging host does not share ${keys.join(', ')} with this '
        'computer. Change ${keys.length == 1 ? 'it' : 'them'} on the host, or '
        'update Skotiq on the host.',
      );

  final List<String> keys;
}

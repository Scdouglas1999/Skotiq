import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals, visibleForTesting;

import '../../backend/roles/host_data/host_rig_settings.dart';
import '../../database/daos/settings_dao.dart' show SettingsDao;
import '../../models/backend/event_types.dart' show SkotiqEvent;
import '../../models/backend/host_mutation_event.dart';
import '../../services/logging_service.dart';

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
    this._backend,
    this._events, {
    this.minRefreshInterval = const Duration(seconds: 2),
  });

  final HostRigSettings _backend;

  /// Read when the store starts following the host, not before.
  final Stream<SkotiqEvent> Function() _events;
  final Duration minRefreshInterval;

  Map<String, String> _values = const {};
  Future<void>? _initialLoad;
  Future<void>? _inFlight;
  Timer? _refreshTimer;
  bool _refreshQueued = false;
  DateTime? _lastRefreshStarted;
  int _writeGeneration = 0;
  bool _disposed = false;

  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();

  /// Keys whose host value changed under this client, from another client or
  /// from the host itself. Never fires for this client's own writes.
  Stream<Set<String>> get changes => _changes.stream;

  /// Whether this client's credential has admin access to the host, as the
  /// host last said; null before the first fetch.
  bool? get adminAccess => _adminAccess;
  bool? _adminAccess;

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

  /// Write [settings] to the host and drop [remove] from it.
  Future<void> write(
    Map<String, String> settings, {
    List<String> remove = const [],
  }) async {
    await ensureLoaded();
    _writeGeneration++;
    await _backend.updateSettingsStore(settings, remove: remove);
    _writeGeneration++;
    final next = Map<String, String>.from(_values)..addAll(settings);
    for (final key in remove) {
      next.remove(key);
    }
    _values = Map.unmodifiable(next);
  }

  /// Lay [fields] over the JSON object the host stores under [key] (or over
  /// [base] when it has none), on the host, so a field another writer changed
  /// meanwhile is kept. Returns the stored value.
  Future<String> mergeJsonObject(
    String key,
    Map<String, Object?> fields, {
    Map<String, Object?> base = const {},
  }) async {
    await ensureLoaded();
    final fallback = SettingsDao.mergeJsonObject(
      _values[key],
      fields,
      base: base,
    );
    _writeGeneration++;
    final stored = await _backend.mergeSettingsStore(
      {key: fields},
      fallback: {key: fallback},
      base: base.isEmpty ? const {} : {key: base},
    );
    _writeGeneration++;
    final value = stored[key] ?? fallback;
    _values = Map.unmodifiable({..._values, key: value});
    return value;
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
    _hostEvents = _events().listen((event) {
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
      Log.warning(
        'Could not refresh the imaging host settings: $error',
        source: 'HostSettingsStore',
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
    _adminAccess = store.adminAccess;
    return store.values;
  }

  @visibleForTesting
  bool get hasPendingRefresh => _inFlight != null || _refreshTimer != null;

  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    unawaited(_hostEvents?.cancel());
    unawaited(_changes.close());
  }
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../database/database.dart' show SkotiqDatabase;
import '../backend_provider.dart';
import '../settings_provider.dart';
import 'host_settings_store.dart';
import 'remote_settings_dao.dart';

export 'host_settings_store.dart'
    show
        HostSettingsStore,
        HostSettingsStoreSupport,
        HostSettingUnavailableError;
export 'remote_settings_dao.dart' show RemoteSettingsDao, AppSettingsRows;
export 'settings_key_scope.dart';

/// Bumped when the settings rows change underneath the providers that read
/// them: on a linked client when the host's rows change, and on the host when
/// a client writes them over the API. [settingsDaoProvider] watches it, so
/// every provider that watches the DAO reads the new values.
final settingsStoreRevisionProvider = StateProvider<int>((ref) => 0);

/// The imaging host's key/value settings, or null when this app owns the
/// hardware itself.
final hostSettingsStoreProvider = Provider<HostSettingsStore?>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is! NetworkBackend) return null;
  final store = HostSettingsStore(backend);
  final changes = store.changes.listen((_) {
    ref.read(settingsStoreRevisionProvider.notifier).state++;
  });
  ref.onDispose(() {
    unawaited(changes.cancel());
    store.dispose();
  });
  return store;
});

/// How much of the host's key/value settings this client reaches, or null
/// when this app owns the hardware itself.
final hostSettingsStoreSupportProvider =
    FutureProvider<HostSettingsStoreSupport?>((ref) async {
      final store = ref.watch(hostSettingsStoreProvider);
      if (store == null) return null;
      await store.ensureLoaded();
      return store.support;
    });

/// Host-owned settings this client has had to read from its own database
/// because the host could not serve them.
final hostSettingsUnsharedKeysProvider = StreamProvider<Set<String>>((
  ref,
) async* {
  final store = ref.watch(hostSettingsStoreProvider);
  if (store == null) {
    yield const {};
    return;
  }
  yield store.unsharedKeys;
  yield* store.unsharedKeyChanges;
});

/// The DAO a linked client reads `app_settings` through.
RemoteSettingsDao buildRemoteSettingsDao(
  Ref ref,
  HostSettingsStore store,
  SkotiqDatabase database,
) {
  return RemoteSettingsDao(
    database,
    store: store,
    appSettings: _NotifierAppSettingsRows(ref.container),
  );
}

class _NotifierAppSettingsRows implements AppSettingsRows {
  _NotifierAppSettingsRows(this._container);

  final ProviderContainer _container;

  static final Set<String> _keys = Set.unmodifiable(
    AppSettingsNotifier.storedKeys.difference(
      AppSettingsNotifier.hostStoreKeys,
    ),
  );

  @override
  Set<String> get keys => _keys;

  @override
  Future<Map<String, String>> read() async {
    final settings = await _container.read(appSettingsProvider.future);
    final rows = _container
        .read(appSettingsProvider.notifier)
        .storedRowsOf(settings);
    rows.removeWhere((key, _) => !_keys.contains(key));
    return rows;
  }

  @override
  Future<void> write(Map<String, String> settings) {
    // `default_image_directory` is a compatibility copy of
    // `image_output_path`; the host's typed model carries only the latter.
    final rows = Map<String, String>.from(settings);
    final legacyDirectory = rows.remove('default_image_directory');
    if (legacyDirectory != null) {
      rows.putIfAbsent('image_output_path', () => legacyDirectory);
    }
    return _container.read(appSettingsProvider.notifier).saveRows(rows);
  }

  @override
  Stream<void> get changes {
    late StreamController<void> controller;
    ProviderSubscription<AsyncValue<AppSettingsState>>? sub;
    controller = StreamController<void>(
      onListen: () {
        sub = _container.listen(appSettingsProvider, (previous, next) {
          if (next.hasValue && previous?.valueOrNull != next.valueOrNull) {
            controller.add(null);
          }
        });
      },
      onCancel: () {
        sub?.close();
        sub = null;
      },
    );
    return controller.stream;
  }
}

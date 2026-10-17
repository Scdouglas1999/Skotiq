// The Rust backend has no coordinate that means "no site".
//
// Its observer location is `Option<ObserverLocation>`; `None` is the only way
// to say the user never chose one, and every native consumer reads a `Some` as
// a site the user picked. The sync provider nevertheless pushed the settings
// triple unconditionally, so a fresh install — which seeds 0/0/0 before the
// user is asked anything — told the backend the operator observes from the
// Gulf of Guinea. Live, on the release bundle: the simulated mount then
// reported a parked altitude of −78.2° and the Dashboard's Equipment panel
// printed it, beside a status bar that honestly said `LST --:--`.
//
// The backend must get null until there is a site, and the site once there is.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/location_sync_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Settings pinned to one state; the real notifier reads the database.
class _FixedSettings extends AppSettingsNotifier {
  _FixedSettings(this._fixed);

  final AppSettingsState _fixed;

  @override
  Future<AppSettingsState> build() async => _fixed;
}

/// Records every site the sync hands the backend, null included.
class _RecordingBackend implements ProfileSettingsBackend {
  final pushes = <ObserverLocation?>[];

  @override
  Future<void> setLocation(ObserverLocation? location) async {
    pushes.add(location);
  }

  // setLocation is the only call on the sync path; anything else reaching
  // this fake means the provider drifted, so let it throw.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<List<ObserverLocation?>> _backendPushesFor(
  AppSettingsState settings,
) async {
  final backend = _RecordingBackend();
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(() => _FixedSettings(settings)),
      profileSettingsBackendProvider.overrideWithValue(backend),
    ],
  );
  addTearDown(container.dispose);

  // Settings are loaded before the sync provider first reads them, as at a
  // real launch, so the initial-value push is the one exercised.
  await container.read(appSettingsProvider.future);
  container.read(locationSyncProvider);
  // The push is scheduled in a microtask; drain a few event-loop turns.
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return backend.pushes;
}

void main() {
  test('a fresh install tells the backend there is no site, not 0/0/0',
      () async {
    // Exactly what the fresh profile stores.
    const fresh = AppSettingsState();
    expect(fresh.latitude, 0.0);
    expect(fresh.longitude, 0.0);

    final pushes = await _backendPushesFor(fresh);

    expect(pushes, hasLength(1), reason: 'one initial-value push');
    expect(
      pushes.single,
      isNull,
      reason: 'null is the only way to say "no site"; a 0/0/0 triple is a '
          'site in the Gulf of Guinea and the mount will compute an altitude '
          'from it',
    );
  });

  test('a configured site is pushed as itself', () async {
    const configured = AppSettingsState(
      latitude: 42.3601,
      longitude: -71.0589,
      elevation: 43.0,
    );

    final pushes = await _backendPushesFor(configured);

    expect(pushes, hasLength(1));
    expect(
      pushes.single,
      const ObserverLocation(
        latitude: 42.3601,
        longitude: -71.0589,
        elevation: 43.0,
      ),
    );
  });

  test('an elevation without coordinates is still no site', () async {
    const elevationOnly = AppSettingsState(elevation: 250.0);

    final pushes = await _backendPushesFor(elevationOnly);

    expect(pushes.single, isNull);
  });
}

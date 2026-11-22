// The planetarium reads the app's site through a provider override: no sync
// listener has to run first, and the 0/0 sentinel reads as no site.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/startup/location_sync_service.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

class _FixedSettings extends AppSettingsNotifier {
  _FixedSettings(this._fixed);

  final AppSettingsState _fixed;

  @override
  Future<AppSettingsState> build() async => _fixed;
}

Future<PlanetariumObserver> _observerFor(AppSettingsState settings) async {
  final container = ProviderContainer(
    overrides: [
      ...planetariumInputOverrides(),
      appSettingsProvider.overrideWith(() => _FixedSettings(settings)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appSettingsProvider.future);
  return container.read(observerLocationProvider);
}

void main() {
  test('a configured site is the planetarium observer', () async {
    final observer = await _observerFor(
      const AppSettingsState(latitude: 42.36, longitude: -71.06, elevation: 43),
    );
    expect(observer.site, (latitude: 42.36, longitude: -71.06));
    expect(observer.elevation, 43);
  });

  test('the unset sentinel is no site', () async {
    final observer = await _observerFor(const AppSettingsState());
    expect(observer.hasSite, isFalse);
  });
}

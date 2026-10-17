import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import '../harness/in_memory_database.dart';

class _SettingsNotifier extends AppSettingsNotifier {
  final AppSettingsState _settings;

  _SettingsNotifier(this._settings);

  @override
  Future<AppSettingsState> build() async => _settings;
}

void main() {
  group('LocationUnsetDetection', () {
    test('only the null-island sentinel is unset', () {
      expect(const AppSettingsState().isLocationSet, isFalse);
      expect(
        const AppSettingsState(latitude: 0.0, longitude: 12.5).isLocationSet,
        isTrue,
      );
      expect(
        const AppSettingsState(latitude: -23.4, longitude: 0.0).isLocationSet,
        isTrue,
      );
    });

    test('sea-level elevation does not unset a configured site', () {
      const settings = AppSettingsState(
        latitude: 51.5,
        longitude: -0.1,
        elevation: 0.0,
      );

      expect(settings.isLocationSet, isTrue);
    });

    test('observer selector maps only the 0,0 sentinel to null', () async {
      final unset = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(
            () => _SettingsNotifier(const AppSettingsState()),
          ),
        ],
      );
      addTearDown(unset.dispose);
      await unset.read(appSettingsProvider.future);
      expect(unset.read(appObserverLocationProvider), isNull);

      final equator = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(
            () => _SettingsNotifier(
              const AppSettingsState(latitude: 0, longitude: 12.5),
            ),
          ),
        ],
      );
      addTearDown(equator.dispose);
      await equator.read(appSettingsProvider.future);
      expect(equator.read(appObserverLocationProvider), isNotNull);
    });
  });
}

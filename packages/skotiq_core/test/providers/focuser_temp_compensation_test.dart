import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/equipment/focuser_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/focuser_temp_compensation_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import '../harness/in_memory_database.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  AppSettingsState _initial;

  void overrideState(AppSettingsState next) {
    _initial = next;
    state = AsyncValue.data(next);
  }

  @override
  Future<AppSettingsState> build() async => _initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FocuserTempCompensator (§2.1 WIRE-UP #7)', () {
    test('captures baseline on first temperature reading', () async {
      final notifier = _FakeAppSettingsNotifier(
        const AppSettingsState(tempCompensation: true, tempCoefficient: 10.0),
      );
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      // Wire up the compensator.
      container.read(focuserTempCompensationProvider);

      // Simulate the focuser connecting with a first temperature.
      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focuser-1');
      focuser.setConnected();
      focuser.updatePosition(5000);
      focuser.updateTemperature(15.0);

      // Allow listeners to fire.
      await Future<void>.delayed(Duration.zero);

      final baseline = container.read(focuserTempCompensationBaselineProvider);
      expect(baseline, isNotNull);
      expect(baseline!.temperature, 15.0);
      expect(baseline.position, 5000);
    });

    test('does not capture baseline when toggle is off', () async {
      final notifier = _FakeAppSettingsNotifier(
        const AppSettingsState(tempCompensation: false, tempCoefficient: 10.0),
      );
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      container.read(focuserTempCompensationProvider);

      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focuser-1');
      focuser.setConnected();
      focuser.updatePosition(5000);
      focuser.updateTemperature(15.0);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(focuserTempCompensationBaselineProvider), isNull);
    });

    test('clears baseline when focuser disconnects', () async {
      final notifier = _FakeAppSettingsNotifier(
        const AppSettingsState(tempCompensation: true, tempCoefficient: 10.0),
      );
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      container.read(focuserTempCompensationProvider);

      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focuser-1');
      focuser.setConnected();
      focuser.updatePosition(5000);
      focuser.updateTemperature(15.0);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(focuserTempCompensationBaselineProvider),
        isNotNull,
      );

      focuser.setDisconnected();
      await Future<void>.delayed(Duration.zero);
      expect(container.read(focuserTempCompensationBaselineProvider), isNull);
    });

    test('toggling tempCompensation off drops the baseline', () async {
      final notifier = _FakeAppSettingsNotifier(
        const AppSettingsState(tempCompensation: true, tempCoefficient: 10.0),
      );
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      container.read(focuserTempCompensationProvider);

      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focuser-1');
      focuser.setConnected();
      focuser.updatePosition(5000);
      focuser.updateTemperature(15.0);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(focuserTempCompensationBaselineProvider),
        isNotNull,
      );

      notifier.overrideState(
        const AppSettingsState(tempCompensation: false, tempCoefficient: 10.0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(focuserTempCompensationBaselineProvider), isNull);
    });
  });
}

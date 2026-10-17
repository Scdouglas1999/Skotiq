/// Pre-flight must catch the fail-closed weather gate BEFORE the run slews.
///
/// The Rust `WeatherUnsafe` trigger is always armed. With weather safety on and
/// the fail mode `failClosed`, a rig with no weather source is unsafe the moment
/// the trigger evaluates, and the action is `ParkAndAbort`. Reproduced on the
/// desktop build with the simulator camera: a 2-iteration loop captured exactly
/// ONE frame before "Trigger fired: Weather Unsafe - action: ParkAndAbort"
/// terminated it, with nothing in pre-flight to warn the operator.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/src/models/equipment/equipment_models.dart';
import 'package:nightshade_core/src/models/settings/app_settings.dart';
import 'package:nightshade_core/src/models/weather/weather_settings.dart';
import 'package:nightshade_core/src/providers/equipment_provider.dart';
import 'package:nightshade_core/src/providers/sequence/rules/weather_safety_rules.dart';
import 'package:nightshade_core/src/providers/sequence/sequence_validation.dart';
import 'package:nightshade_core/src/providers/settings_provider.dart';
import 'package:nightshade_core/src/providers/weather_providers.dart';
import 'package:nightshade_core/src/models/sequence/sequence_models.dart';

class _FakeAppSettings extends AppSettingsNotifier {
  _FakeAppSettings(this._initial);
  final AppSettingsState _initial;
  @override
  Future<AppSettingsState> build() async => _initial;
}

class _StubWeather extends WeatherStateNotifier {
  _StubWeather(super.ref, WeatherState initial) {
    state = initial;
  }
}

class _StubSafetyMonitor extends SafetyMonitorStateNotifier {
  _StubSafetyMonitor(super.ref, SafetyMonitorState initial) {
    state = initial;
  }
}

T _withRef<T>(ProviderContainer c, T Function(Ref ref) body) =>
    c.read(Provider<T>((ref) => body(ref)));

ProviderContainer _container({
  bool weatherSafetyEnabled = true,
  SafetyFailMode failMode = SafetyFailMode.failClosed,
  DeviceConnectionState weather = DeviceConnectionState.disconnected,
  DeviceConnectionState safetyMonitor = DeviceConnectionState.disconnected,
}) {
  final c = ProviderContainer(
    overrides: [
      weatherSettingsProvider.overrideWithValue(
        WeatherSettings(weatherSafetyEnabled: weatherSafetyEnabled),
      ),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettings(AppSettingsState(safetyFailMode: failMode)),
      ),
      weatherStateProvider.overrideWith(
        (ref) => _StubWeather(ref, WeatherState(connectionState: weather)),
      ),
      safetyMonitorStateProvider.overrideWith(
        (ref) => _StubSafetyMonitor(
          ref,
          SafetyMonitorState(connectionState: safetyMonitor),
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  // Settle the async settings notifier so `.value` is populated.
  c.read(appSettingsProvider);
  return c;
}

Sequence _seq() => Sequence(
  id: 'seq',
  name: 'S',
  nodes: const {},
  createdAt: DateTime.utc(2026),
  modifiedAt: DateTime.utc(2026),
);

void main() {
  group('WeatherSafetyNoSourceRule', () {
    final rule = WeatherSafetyNoSourceRule();

    test(
      'errors when fail-closed and no weather source is connected',
      () async {
        final c = _container();
        await c.read(appSettingsProvider.future);
        final issues = _withRef(
          c,
          (ref) => rule.validate(_seq(), ValidationContext(ref)),
        );
        expect(issues, hasLength(1));
        expect(issues.single.severity, ValidationSeverity.error);
        expect(issues.single.title, 'Weather Safety Will Abort This Run');
      },
    );

    test('clean when a weather device is connected', () async {
      final c = _container(weather: DeviceConnectionState.connected);
      await c.read(appSettingsProvider.future);
      expect(
        _withRef(c, (ref) => rule.validate(_seq(), ValidationContext(ref))),
        isEmpty,
      );
    });

    test('clean when a safety monitor is connected', () async {
      final c = _container(safetyMonitor: DeviceConnectionState.connected);
      await c.read(appSettingsProvider.future);
      expect(
        _withRef(c, (ref) => rule.validate(_seq(), ValidationContext(ref))),
        isEmpty,
      );
    });

    for (final mode in [SafetyFailMode.failOpen, SafetyFailMode.warnOnly]) {
      test(
        'warns without blocking when no source is connected ($mode)',
        () async {
          final c = _container(failMode: mode);
          await c.read(appSettingsProvider.future);
          final issues = _withRef(
            c,
            (ref) => rule.validate(_seq(), ValidationContext(ref)),
          );
          expect(issues.single.severity, ValidationSeverity.warning);
          expect(issues.single.description, contains('continue'));
        },
      );
    }

    test('clean when weather safety is disabled entirely', () async {
      final c = _container(weatherSafetyEnabled: false);
      await c.read(appSettingsProvider.future);
      expect(
        _withRef(c, (ref) => rule.validate(_seq(), ValidationContext(ref))),
        isEmpty,
      );
    });
  });
}

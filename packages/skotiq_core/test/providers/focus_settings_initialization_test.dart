import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import '../harness/in_memory_database.dart';

class _DelayedAppSettingsNotifier extends AppSettingsNotifier {
  _DelayedAppSettingsNotifier(this.result);

  final Future<AppSettingsState> result;

  @override
  Future<AppSettingsState> build() => result;
}

void main() {
  const loaded = AppSettingsState(
    afMethod: 'Hyperbolic',
    afStepSize: 240,
    afInitialOffsetSteps: 9,
    afExposuresPerPoint: 3,
    afExposureTime: 4.5,
  );

  test(
    'focus settings wait for the asynchronous app-settings snapshot',
    () async {
      final completer = Completer<AppSettingsState>();
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(
            () => _DelayedAppSettingsNotifier(completer.future),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(focusSettingsProvider), const FocusSettings());
      completer.complete(loaded);
      await container.read(appSettingsProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(focusSettingsProvider),
        const FocusSettings(
          stepSize: 240,
          method: 'Hyperbolic',
          afStepSize: 240,
          stepsOut: 9,
          exposuresPerPoint: 3,
          exposureTime: 4.5,
        ),
      );
    },
  );

  test('late settings load does not overwrite an early user edit', () async {
    final completer = Completer<AppSettingsState>();
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        appSettingsProvider.overrideWith(
          () => _DelayedAppSettingsNotifier(completer.future),
        ),
      ],
    );
    addTearDown(container.dispose);
    const edited = FocusSettings(method: 'Parabolic', exposureTime: 8);

    container.read(focusSettingsProvider.notifier).update(edited);
    completer.complete(loaded);
    await container.read(appSettingsProvider.future);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(focusSettingsProvider), edited);
  });
}

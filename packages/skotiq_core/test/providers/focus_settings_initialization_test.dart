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
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The fields the edit changed are kept and saved; the rest take the
    // persisted values.
    final focus = container.read(focusSettingsProvider);
    expect(focus.method, 'Parabolic');
    expect(focus.exposureTime, 8);
    expect(focus.stepsOut, 9);
    final settings = container.read(appSettingsProvider).requireValue;
    expect(settings.afMethod, 'Parabolic');
    expect(settings.afExposureTime, 8);
  });

  test('a panel edit is saved and a saved change shows on the panel', () async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    container.read(focusSettingsProvider);
    await Future<void>.delayed(Duration.zero);

    final notifier = container.read(focusSettingsProvider.notifier);
    notifier.update(
      container.read(focusSettingsProvider).copyWith(afStepSize: 80),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(appSettingsProvider).requireValue.afStepSize, 80);

    // Changed elsewhere (Settings, the host, a linked client).
    await container
        .read(appSettingsProvider.notifier)
        .setAfInitialOffsetSteps(6);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(focusSettingsProvider).stepsOut, 6);
    expect(container.read(focusSettingsProvider).afStepSize, 80);
  });
}

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import '../harness/in_memory_database.dart';

void main() {
  test(
    'corrupt persisted scheduler config is surfaced, not defaulted',
    () async {
      final database = db.SkotiqDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(database.close);
      final dao = SettingsDao(database);
      await dao.setSetting('scheduler_config', '{not valid json');

      await expectLater(
        SchedulerConfigStore(dao).load(),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'readiness does not construct an engine before authority loads',
    () async {
      final settingsCompleter = Completer<AppSettingsState>();
      final configCompleter = Completer<SchedulerConfig>();
      var engineConstructions = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(
            () => _ControlledSettings(settingsCompleter.future),
          ),
          schedulerPersistedConfigProvider.overrideWith(
            (ref) => configCompleter.future,
          ),
          schedulerEngineProvider.overrideWith((ref) {
            engineConstructions++;
            return _testEngine();
          }),
        ],
      );
      addTearDown(container.dispose);

      final ready = container.read(schedulerEngineReadyProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(engineConstructions, 0);

      settingsCompleter.complete(
        const AppSettingsState(latitude: 34.2, longitude: -118.3),
      );
      configCompleter.complete(
        SchedulerConfig.defaults.copyWith(minAltitudeDegrees: 41),
      );
      final engine = await ready;

      expect(engineConstructions, 1);
      expect(engine.site.latitudeDegrees, 34.2);
      expect(engine.site.longitudeDegrees, -118.3);
      expect(engine.config.minAltitudeDegrees, 41);
    },
  );

  test(
    'settings failure rejects readiness without constructing an engine',
    () async {
      var engineConstructions = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(
            () =>
                _ControlledSettings(Future.error(StateError('settings down'))),
          ),
          schedulerPersistedConfigProvider.overrideWith(
            (ref) async => SchedulerConfig.defaults,
          ),
          schedulerEngineProvider.overrideWith((ref) {
            engineConstructions++;
            return _testEngine();
          }),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(schedulerEngineReadyProvider.future),
        throwsA(isA<StateError>()),
      );
      expect(engineConstructions, 0);
    },
  );

  test('late scheduler hydration updates one stable engine in place', () async {
    final settingsCompleter = Completer<AppSettingsState>();
    final configCompleter = Completer<SchedulerConfig>();
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        appSettingsProvider.overrideWith(
          () => _ControlledSettings(settingsCompleter.future),
        ),
        schedulerPersistedConfigProvider.overrideWith(
          (ref) => configCompleter.future,
        ),
        schedulerTriggerStreamProvider.overrideWithValue(const Stream.empty()),
        activeProjectIdProvider.overrideWith(ActiveProjectNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    final engine = container.read(schedulerEngineProvider);
    expect(engine.config, SchedulerConfig.defaults);

    final persisted = SchedulerConfig.defaults.copyWith(minAltitudeDegrees: 37);
    configCompleter.complete(persisted);
    settingsCompleter.complete(
      const AppSettingsState(latitude: 34.2, longitude: -118.3),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(identical(container.read(schedulerEngineProvider), engine), isTrue);
    expect(engine.config.minAltitudeDegrees, 37);
    expect(engine.site.latitudeDegrees, 34.2);
    expect(engine.site.longitudeDegrees, -118.3);
  });

  test('late persisted config cannot overwrite an early user edit', () async {
    final configCompleter = Completer<SchedulerConfig>();
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        appSettingsProvider.overrideWith(
          () => _ControlledSettings(Future.value(const AppSettingsState())),
        ),
        schedulerPersistedConfigProvider.overrideWith(
          (ref) => configCompleter.future,
        ),
        schedulerTriggerStreamProvider.overrideWithValue(const Stream.empty()),
        activeProjectIdProvider.overrideWith(ActiveProjectNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    final engine = container.read(schedulerEngineProvider);
    container.read(schedulerConfigUserDirtyProvider.notifier).state = true;
    engine.updateConfig(engine.config.copyWith(minAltitudeDegrees: 52));

    configCompleter.complete(
      SchedulerConfig.defaults.copyWith(minAltitudeDegrees: 20),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(identical(container.read(schedulerEngineProvider), engine), isTrue);
    expect(engine.config.minAltitudeDegrees, 52);
  });
}

SchedulerEngine _testEngine() {
  return SchedulerEngine(
    site: const SchedulerSite(
      latitudeDegrees: 0,
      longitudeDegrees: 0,
      localOffset: Duration.zero,
    ),
    config: SchedulerConfig.defaults,
    sequenceSink: _NoopSequenceSink(),
    candidateLoader: () async => const [],
    triggerStream: const Stream.empty(),
  );
}

class _NoopSequenceSink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}

  @override
  Future<void> pauseSequence() async {}

  @override
  Future<void> resumeSequence() async {}

  @override
  Future<void> stopSequence() async {}

  @override
  Future<void> releaseSequenceOwnership() async {}

  @override
  Future<void> parkForEndOfNight() async {}
}

class _ControlledSettings extends AppSettingsNotifier {
  _ControlledSettings(this.settings);

  final Future<AppSettingsState> settings;

  @override
  Future<AppSettingsState> build() => settings;
}

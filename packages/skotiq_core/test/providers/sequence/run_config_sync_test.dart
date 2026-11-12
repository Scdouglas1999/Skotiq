// The host's executor runs with one run configuration built from the
// operator's settings and sent whole (`RunConfigSync`).
//
// What is pinned here: what default settings make (the same file the native
// side reads to prove it knows every key), that a catalog entry with a
// `runConfig` path reaches its field, which sections a run keeps from its
// start and which follow the settings while it lasts, that a manual capture
// and a sequence frame get one file format, and that a linked client never
// sends one.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/settings/app_settings_table.dart';

import '../../mocks/mock_backend.dart';

const _wireFixture = 'test/fixtures/run_config_wire.json';

class _RecordingBackend extends MockBackend {
  final List<Map<String, dynamic>> runConfigs = [];
  bool refuse = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sequencerApplyRunConfig) {
      if (refuse) return Future<void>.error(StateError('refused'));
      runConfigs.add(
        jsonDecode(invocation.positionalArguments.single as String)
            as Map<String, dynamic>,
      );
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation) ?? Future<void>.value();
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this._state);
  final AppSettingsState _state;

  @override
  Future<AppSettingsState> build() async => _state;

  void replace(AppSettingsState next) => state = AsyncData(next);
}

final _weather = StateProvider<WeatherSettings>(
  (ref) => WeatherSettings.defaultSettings.copyWith(weatherSafetyEnabled: true),
);

void main() {
  late _RecordingBackend backend;
  late SkotiqDatabase db;
  late ProviderContainer container;

  ProviderContainer build({
    AppSettingsState settings = const AppSettingsState(),
    bool remoteClient = false,
  }) {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(
          () => _FixedSettingsNotifier(settings),
        ),
        weatherSettingsProvider.overrideWith((ref) => ref.watch(_weather)),
        isRemoteClientProvider.overrideWithValue(remoteClient),
      ],
    );
    // Started as the host starts it: the always-on service list holds it.
    container.read(runConfigSyncProvider);
    return container;
  }

  /// Let the start-up load finish and the scheduled send go out.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void replaceSettings(AppSettingsState next) =>
      (container.read(appSettingsProvider.notifier) as _FixedSettingsNotifier)
          .replace(next);

  setUp(() {
    backend = _RecordingBackend();
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await settle();
    container.dispose();
    await db.close();
  });

  test(
    'default settings make the run config the executor is pinned to read',
    () async {
      build();
      final sync = container.read(runConfigSyncProvider);
      await settle();
      final built = sync.build();
      const encoder = JsonEncoder.withIndent('  ');
      final file = File(_wireFixture);
      if (Platform.environment['SKOTIQ_REGENERATE'] == '1') {
        file.writeAsStringSync('${encoder.convert(built)}\n');
      }
      expect(
        encoder.convert(built),
        encoder.convert(jsonDecode(file.readAsStringSync())),
        reason:
            'regenerate with SKOTIQ_REGENERATE=1, then run the native test '
            'every_key_the_app_sends_is_a_setting_the_executor_reads',
      );
      expect(backend.runConfigs.single, built, reason: 'sent once at start-up');
    },
  );

  test('a catalog entry with a run-config path reaches its field', () async {
    final settings = const AppSettingsState().copyWith(
      cameraRetries: 7,
      filterWheelRetries: 1,
      parkBeforeDawn: false,
      stopRunOnQualityProblems: true,
      cameraFileSaving: 'both',
      imageFormat: 'XISF',
      xisfCompression: 'zstd+sh',
      xisfChecksums: true,
      imageGradingRejectFolderPath: '/frames/rejected',
      recoveryAbortOnMeridian: false,
    );
    build(settings: settings);
    await settle();
    final config = container.read(runConfigSyncProvider).build();

    Object? at(String path) {
      Object? node = config;
      for (final key in path.split('.')) {
        node = (node as Map<String, Object?>)[key];
      }
      return node;
    }

    final tagged = kAppSettingsTable.where((s) => s.runConfig != null);
    expect(tagged, isNotEmpty);
    for (final setting in tagged) {
      expect(
        at(setting.runConfig!),
        settings.valueOf(setting),
        reason: setting.field,
      );
    }
  });

  test('settings worked out from more than one value', () async {
    container = build(
      settings: const AppSettingsState().copyWith(
        latitude: 0,
        longitude: 0,
        parkOnUnsafeWeather: true,
        recoveryDefaultRetryIntervalMins: 2,
        recoveryDefaultMaxDurationMins: 30,
        enableImageGrading: false,
        adaptiveExposureEnabled: false,
      ),
    );
    container.read(_weather.notifier).state = WeatherSettings.defaultSettings
        .copyWith(weatherSafetyEnabled: false, autoParkEnabled: false);
    await settle();
    final config = container.read(runConfigSyncProvider).build();

    // (0, 0) is how an unset site is stored; none is sent.
    expect(config['latitude'], isNull);
    expect(config['longitude'], isNull);
    // With weather safety off the poll must not fail closed.
    expect(config['safety_fail_mode'], 'FailOpen');
    expect(
      (config['park_policy']! as Map)['park_on_unsafe_weather'],
      isFalse,
      reason: "Weather Safety's auto-park off turns weather parking off",
    );
    expect((config['recovery']! as Map)['retry_interval_secs'], 120);
    expect((config['recovery']! as Map)['max_duration_secs'], 1800);
    expect(config['default_quality_check'], isNull);
    expect(config['default_adaptive_exposure'], isNull);
  });

  group('a run', () {
    test('keeps the autofocus tuning and the meridian-flip settings it started '
        'with, and follows every other setting', () async {
      build();
      final sync = container.read(runConfigSyncProvider);
      await settle();
      final warnings = <String>[];
      await sync.beginRun(onSendFailure: warnings.add);
      final atStart = backend.runConfigs.last;
      backend.runConfigs.clear();

      // The operator changes the autofocus step and the dither settle.
      replaceSettings(const AppSettingsState().copyWith(afStepSize: 99));
      await container
          .read(sequencerDefaultsProvider.notifier)
          .updateDitherDefaults(settleTime: 42);
      await settle();

      final during = backend.runConfigs.last;
      expect(during['autofocus'], atStart['autofocus']);
      expect(during['meridian_flip'], atStart['meridian_flip']);
      expect((during['dither']! as Map)['settle_time'], 42);

      sync.endRun();
      await settle();
      expect((backend.runConfigs.last['autofocus']! as Map)['step_size'], 99);
      expect(warnings, isEmpty);
    });

    test('starts on what the executor accepted, or not at all', () async {
      build();
      final sync = container.read(runConfigSyncProvider);
      await settle();
      backend.refuse = true;
      await expectLater(
        sync.beginRun(onSendFailure: (_) {}),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'puts a change the executor refuses on the run, not in silence',
      () async {
        build();
        final sync = container.read(runConfigSyncProvider);
        await settle();
        final warnings = <String>[];
        await sync.beginRun(onSendFailure: warnings.add);
        backend.refuse = true;
        replaceSettings(const AppSettingsState().copyWith(cameraRetries: 5));
        await settle();
        expect(warnings.single, contains('previous values'));
      },
    );
  });

  test('a manual capture and a sequence frame get one file format', () async {
    build(settings: const AppSettingsState().copyWith(imageFormat: 'XISF'));
    await settle();
    final config = container.read(runConfigSyncProvider).build();
    final frameFormat = config['frame_format']! as Map<String, Object?>;
    // A manual capture's file name takes its extension from the naming
    // pattern; the host names a sequence frame from the run config.
    expect(frameFormat['format'], 'XISF');
    expect(container.read(namingPatternProvider).format.extension, 'xisf');
  });

  test('a linked client sends no run config', () async {
    build(remoteClient: true);
    final sync = container.read(runConfigSyncProvider);
    replaceSettings(const AppSettingsState().copyWith(cameraRetries: 4));
    await settle();
    expect(backend.runConfigs, isEmpty);
    await expectLater(
      sync.beginRun(onSendFailure: (_) {}),
      throwsA(isA<StateError>()),
    );
  });
}

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// Every test here drives a backend whose credentials are live.
///
/// The remote poller reads `isAuthTokenRejected` before each fetch — terminal
/// credentials can only 403, so it stops polling rather than writing a
/// fail-mode warning into state every 10 s. It is a non-nullable `bool`, and
/// mocktail answers an unstubbed getter with null, so leaving it unstubbed
/// makes the notifier throw in its constructor before any test reaches its
/// own assertions.
_MockNetworkBackend _liveCredentialsBackend() {
  final backend = _MockNetworkBackend();
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  return backend;
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 30 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test('remote weather settings read and write the imaging host', () async {
    final backend = _liveCredentialsBackend();
    when(() => backend.getWeatherSettings()).thenAnswer(
      (_) async => {
        'triggerDistanceKm': 42.0,
        'cloudDensityThreshold': 55.0,
        'leadTimeMinutes': 22,
        'weatherSafetyEnabled': true,
        'maxHumidityPercent': 77.0,
        'maxWindSpeedKph': 24.0,
        'maxCloudCoverPercent': 66.0,
        'autoParkEnabled': true,
        'autoResumeEnabled': false,
        'preferredProvider': 'metno',
        'refreshIntervalSeconds': 180,
      },
    );
    when(() => backend.updateWeatherSettings(any())).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final settings = await container.read(weatherSettingsDataProvider.future);
    expect(settings.triggerDistanceKm, 42);
    expect(settings.maxHumidityPercent, 77);
    expect(settings.preferredProvider, RadarProviderType.metno);

    await container
        .read(weatherSettingsActionsProvider)
        .updateSettings(maxHumidityPercent: 70, autoResumeEnabled: true);

    final payload =
        verify(
              () => backend.updateWeatherSettings(captureAny()),
            ).captured.single
            as Map<String, dynamic>;
    expect(payload, {'maxHumidityPercent': 70.0, 'autoResumeEnabled': true});
    expect(await database.weatherSettingsDao.getSettings(), isNull);
  });

  test(
    'remote safety state mirrors the host and never evaluates locally',
    () async {
      final backend = _liveCredentialsBackend();
      when(() => backend.getSafetyStatus()).thenAnswer(
        (_) async => {
          'isSafe': true,
          'safetyStatus': 'safe',
          'dataSource': 'combined',
          'hardwareWeatherSafe': true,
          'safetyMonitorSafe': true,
          'apiWeatherSafe': true,
          'lastEvaluation': '2026-07-13T03:00:00Z',
        },
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(weatherSafetyProvider);
      await _pumpUntil(() => container.read(weatherSafetyProvider).isSafe);

      final state = container.read(weatherSafetyProvider);
      expect(state.status, WeatherSafetyStatus.safe);
      expect(state.dataSource, SafetyDataSource.combined);
      verify(() => backend.getSafetyStatus()).called(1);
      verifyNever(
        () => backend.sequencerUpdateWeatherVerdict(
          unsafeOverride: any(named: 'unsafeOverride'),
        ),
      );
    },
  );

  test(
    'a latched auth rejection does not leave the last host verdict on show',
    () async {
      final backend = _liveCredentialsBackend();
      var rejected = false;
      when(() => backend.isAuthTokenRejected).thenAnswer((_) => rejected);
      when(() => backend.getSafetyStatus()).thenAnswer(
        (_) async => {
          'isSafe': true,
          'safetyStatus': 'safe',
          'dataSource': 'combined',
          'hardwareWeatherSafe': true,
          'safetyMonitorSafe': true,
          'apiWeatherSafe': true,
          'lastEvaluation': '2026-07-13T03:00:00Z',
        },
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(weatherSafetyProvider);
      await _pumpUntil(() => container.read(weatherSafetyProvider).isSafe);
      expect(container.read(weatherSafetyProvider).isSafe, isTrue);

      // Another request latched the host's rejection of this device's token.
      // From here the client knows nothing about the host's sky.
      rejected = true;
      await container.read(weatherSafetyProvider.notifier).evaluateNow();

      final state = container.read(weatherSafetyProvider);
      expect(
        state.isSafe,
        isFalse,
        reason: 'a verdict the client can no longer refresh is not "safe"',
      );
      expect(state.failModeWarning, isNotNull);
    },
  );

  test(
    'remote safety preserves critical severity, reason, and exact actions',
    () async {
      final backend = _liveCredentialsBackend();
      when(() => backend.getSafetyStatus()).thenAnswer(
        (_) async => {
          'isSafe': false,
          'safetyStatus': 'unsafe',
          'currentAlertLevel': 'critical',
          'dataSource': 'combined',
          'hardwareWeatherSafe': false,
          'safetyMonitorSafe': true,
          'apiWeatherSafe': false,
          'actions': {
            'shouldPause': true,
            'shouldPark': true,
            'shouldCloseDome': true,
            'reason': 'Rain detected; roof closure required',
            'resumeCheckTime': '2026-07-13T03:30:00Z',
          },
          'lastEvaluation': '2026-07-13T03:00:00Z',
        },
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(weatherSafetyProvider);
      await _pumpUntil(
        () =>
            container.read(weatherSafetyProvider).currentAlertLevel ==
            AlertLevel.critical,
      );

      final state = container.read(weatherSafetyProvider);
      expect(state.status, WeatherSafetyStatus.unsafe);
      expect(state.currentAlertLevel, AlertLevel.critical);
      expect(state.hardwareWeatherSafe, isFalse);
      expect(state.safetyMonitorSafe, isTrue);
      expect(state.apiWeatherSafe, isFalse);
      expect(state.actions.shouldPause, isTrue);
      expect(state.actions.shouldPark, isTrue);
      expect(state.actions.shouldCloseDome, isTrue);
      expect(state.actions.reason, 'Rain detected; roof closure required');
      expect(
        state.actions.resumeCheckTime,
        DateTime.parse('2026-07-13T03:30:00Z'),
      );
    },
  );

  test(
    'remote cancel snooze exits snoozed state while host request is pending',
    () async {
      final backend = _liveCredentialsBackend();
      when(() => backend.getSafetyStatus()).thenAnswer(
        (_) async => {
          'isSafe': false,
          'safetyStatus': 'snoozed',
          'currentAlertLevel': 'warning',
          'dataSource': 'weatherApi',
          'hardwareWeatherSafe': true,
          'safetyMonitorSafe': true,
          'apiWeatherSafe': false,
          'actions': {
            'shouldPause': false,
            'shouldPark': false,
            'shouldCloseDome': false,
          },
          'snoozeUntil': '2026-07-13T04:00:00Z',
        },
      );
      final hostCancel = Completer<void>();
      when(
        () => backend.cancelSafetyAcknowledgement(),
      ).thenAnswer((_) => hostCancel.future);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(weatherSafetyProvider);
      await _pumpUntil(
        () =>
            container.read(weatherSafetyProvider).status ==
            WeatherSafetyStatus.snoozed,
      );

      container.read(weatherSafetyProvider.notifier).cancelSnooze();

      final pending = container.read(weatherSafetyProvider);
      expect(pending.status, WeatherSafetyStatus.unsafe);
      expect(pending.snoozeUntil, isNull);
      expect(pending.actions.shouldPause, isTrue);
      expect(pending.actions.reason, contains('re-evaluating'));
      verify(() => backend.cancelSafetyAcknowledgement()).called(1);

      hostCancel.complete();
    },
  );

  test('remote safety status failure remains fail closed', () async {
    final backend = _liveCredentialsBackend();
    when(
      () => backend.getSafetyStatus(),
    ).thenThrow(StateError('host unreachable'));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(weatherSafetyProvider);
    await _pumpUntil(
      () =>
          container.read(weatherSafetyProvider).failModeWarning?.isNotEmpty ??
          false,
    );

    final state = container.read(weatherSafetyProvider);
    expect(state.status, WeatherSafetyStatus.unsafe);
    expect(state.actions.shouldPause, isTrue);
    expect(state.failModeWarning, contains('host unreachable'));
  });
}

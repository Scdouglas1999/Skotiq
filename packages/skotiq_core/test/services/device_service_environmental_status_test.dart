import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart'
    show DeviceConnectionState, ShutterStatus;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';

class _EnvironmentalBackend extends Mock
    implements
        SkotiqBackend,
        EnvironmentalStatusBackend,
        DomeStatusBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late _EnvironmentalBackend backend;
  late ProviderContainer container;
  late StreamController<SkotiqEvent> events;

  setUp(() {
    backend = _EnvironmentalBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
      ],
    );
    container.read(deviceServiceProvider);
  });

  tearDown(() async {
    container.dispose();
    await events.close();
  });

  test(
    'weather connection publishes driver telemetry before connected',
    () async {
      const deviceId = 'simulator:weather-1';
      when(
        () => backend.connectDevice(DeviceType.weather, deviceId),
      ).thenAnswer((_) async {});
      when(() => backend.getHardwareWeatherConditions(deviceId)).thenAnswer(
        (_) async => const HardwareWeatherConditions(
          temperature: 7.5,
          humidity: 42,
          pressure: 1012.4,
          cloudCover: 8,
          dewPoint: -3,
          windSpeed: 1.25,
          windDirection: 210,
          skyQuality: 21.4,
          skyTemperature: -17,
          rainRate: 0,
        ),
      );

      await container.read(deviceServiceProvider).connectWeather(deviceId);

      final state = container.read(weatherStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.deviceId, deviceId);
      expect(state.temperature, 7.5);
      expect(state.humidity, 42);
      expect(state.skyTemperature, -17);
      expect(state.rainRate, 0);
    },
  );

  test(
    'safety connection fails closed and disconnects when status read fails',
    () async {
      const deviceId = 'simulator:safety-1';
      when(
        () => backend.connectDevice(DeviceType.safetyMonitor, deviceId),
      ).thenAnswer((_) async {});
      when(
        () => backend.getHardwareSafetyStatus(deviceId),
      ).thenThrow(StateError('safety sensor unavailable'));
      when(
        () => backend.disconnectDevice(DeviceType.safetyMonitor, deviceId),
      ).thenAnswer((_) async {});

      await expectLater(
        container.read(deviceServiceProvider).connectSafetyMonitor(deviceId),
        throwsA(isA<StateError>()),
      );

      verify(
        () => backend.disconnectDevice(DeviceType.safetyMonitor, deviceId),
      ).called(1);
      final state = container.read(safetyMonitorStateProvider);
      expect(state.connectionState, DeviceConnectionState.error);
      expect(state.isSafe, isFalse);
      expect(state.deviceId, deviceId);
      expect(state.lastError?.message, contains('safety sensor unavailable'));
    },
  );

  // Simulator campaign 2026-07-28 (S1): a safety monitor that started failing
  // its status reads dropped to `error`, and the poll loop skipped every
  // non-connected device — so it was never read again, even after the sensor
  // came back reporting UNSAFE. Only a manual reconnect resumed polling.
  test('polling resumes after a safety monitor read failure recovers', () {
    const deviceId = 'simulator:safety-1';
    var failReads = false;
    when(
      () => backend.connectDevice(DeviceType.safetyMonitor, deviceId),
    ).thenAnswer((_) async {});
    when(() => backend.getHardwareSafetyStatus(deviceId)).thenAnswer((_) async {
      if (failReads) throw StateError('safety sensor unavailable');
      return true;
    });

    fakeAsync((async) {
      unawaited(
        container.read(deviceServiceProvider).connectSafetyMonitor(deviceId),
      );
      async.elapse(const Duration(seconds: 1));
      expect(
        container.read(safetyMonitorStateProvider).connectionState,
        DeviceConnectionState.connected,
      );

      failReads = true;
      async.elapse(const Duration(seconds: 10));
      expect(
        container.read(safetyMonitorStateProvider).connectionState,
        DeviceConnectionState.error,
      );

      // Sensor comes back, now reporting UNSAFE.
      failReads = false;
      when(
        () => backend.getHardwareSafetyStatus(deviceId),
      ).thenAnswer((_) async => false);
      async.elapse(const Duration(seconds: 30));

      final recovered = container.read(safetyMonitorStateProvider);
      expect(recovered.connectionState, DeviceConnectionState.connected);
      expect(recovered.isSafe, isFalse);
    });
  });

  // A driver that accepts the status read and never answers would pin
  // `_environmentPollInFlight` for the rest of the process: every later tick
  // returns early, `setError` is never reached, and the safety card keeps
  // rendering the last good "SAFE". The read is capped so a wedged sensor
  // becomes a visible error.
  test('a status read that never completes surfaces as an error', () {
    const deviceId = 'simulator:safety-1';
    var wedge = false;
    when(
      () => backend.connectDevice(DeviceType.safetyMonitor, deviceId),
    ).thenAnswer((_) async {});
    when(() => backend.getHardwareSafetyStatus(deviceId)).thenAnswer((_) async {
      if (wedge) return Completer<bool>().future;
      return true;
    });

    fakeAsync((async) {
      unawaited(
        container.read(deviceServiceProvider).connectSafetyMonitor(deviceId),
      );
      async.elapse(const Duration(seconds: 1));
      expect(
        container.read(safetyMonitorStateProvider).connectionState,
        DeviceConnectionState.connected,
      );

      wedge = true;
      async.elapse(const Duration(seconds: 30));

      final state = container.read(safetyMonitorStateProvider);
      expect(
        state.connectionState,
        DeviceConnectionState.error,
        reason: 'a hung driver read must not keep reporting the last SAFE',
      );
      expect(state.isSafe, isFalse);
    });
  });

  group('dome telemetry', () {
    const deviceId = 'simulator:dome-1';

    setUp(() {
      when(
        () => backend.connectDevice(DeviceType.dome, deviceId),
      ).thenAnswer((_) async {});
    });

    test('connect seeds azimuth + shutter from the driver read', () async {
      when(() => backend.getHardwareDomeStatus(deviceId)).thenAnswer(
        (_) async => const HardwareDomeStatus(
          azimuth: 137.5,
          shutterStatus: 1,
          isParked: true,
        ),
      );

      await container.read(deviceServiceProvider).connectDome(deviceId);

      final state = container.read(domeStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.azimuth, 137.5);
      expect(state.shutterStatus, ShutterStatus.closed);
      expect(state.isParked, isTrue);
    });

    // `updateAzimuth` / `updateShutterStatus` with no callers leave a connected
    // dome rendering `Azimuth ---` / `Shutter Unknown` forever, with the shutter
    // button never flipping whatever the hardware does.
    test('the poll keeps shutter state live after the shutter opens', () {
      var shutterCode = 1;
      when(() => backend.getHardwareDomeStatus(deviceId)).thenAnswer(
        (_) async =>
            HardwareDomeStatus(azimuth: 90, shutterStatus: shutterCode),
      );

      fakeAsync((async) {
        unawaited(container.read(deviceServiceProvider).connectDome(deviceId));
        async.elapse(const Duration(seconds: 1));
        expect(
          container.read(domeStateProvider).shutterStatus,
          ShutterStatus.closed,
        );

        shutterCode = 2; // opening
        async.elapse(const Duration(seconds: 6));
        expect(
          container.read(domeStateProvider).shutterStatus,
          ShutterStatus.opening,
        );

        shutterCode = 0; // open
        async.elapse(const Duration(seconds: 6));
        expect(
          container.read(domeStateProvider).shutterStatus,
          ShutterStatus.open,
        );
      });
    });

    test('an unreported shutter stays unknown rather than reading closed', () {
      when(
        () => backend.getHardwareDomeStatus(deviceId),
      ).thenAnswer((_) async => const HardwareDomeStatus(azimuth: 12.0));

      fakeAsync((async) {
        unawaited(container.read(deviceServiceProvider).connectDome(deviceId));
        async.elapse(const Duration(seconds: 1));

        final state = container.read(domeStateProvider);
        expect(state.shutterStatus, ShutterStatus.unknown);
        expect(state.azimuth, 12.0);
      });
    });

    test('a failed first read still leaves the dome connected', () async {
      when(
        () => backend.getHardwareDomeStatus(deviceId),
      ).thenThrow(StateError('dome status unsupported'));

      await container.read(deviceServiceProvider).connectDome(deviceId);

      final state = container.read(domeStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.azimuth, isNull);
      expect(state.shutterStatus, ShutterStatus.unknown);
    });
  });
}

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_backend.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

ProviderContainer _container(MockBackend backend) {
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  final camera = container.read(cameraStateProvider.notifier);
  camera.setConnecting('simulator:camera:0');
  camera.setConnected();
  camera.setTargetTemp(-10);
  camera.setCooling(true);
  return container;
}

CameraStatus _status({
  required bool coolerOn,
  double? power,
  double temp = 11.1,
  double target = 11.1,
}) => CameraStatus(
  connected: true,
  state: CameraState.idle,
  sensorTemp: temp,
  coolerPower: power,
  targetTemp: target,
  coolerOn: coolerOn,
  gain: 0,
  offset: 0,
  binX: 1,
  binY: 1,
  sensorWidth: 100,
  sensorHeight: 100,
  pixelSizeX: 3.76,
  pixelSizeY: 3.76,
  maxAdu: 65535,
  canCool: true,
  canSetGain: true,
  canSetOffset: true,
);

/// Every cooler command the backend received, as (enabled, target).
List<(bool, double?)> _coolerCommands(MockBackend backend) {
  final calls = verify(
    () => backend.cameraSetCooling(
      deviceId: any(named: 'deviceId'),
      enabled: captureAny(named: 'enabled'),
      targetTemp: captureAny(named: 'targetTemp'),
    ),
  );
  final captured = calls.captured;
  return [
    for (var i = 0; i < captured.length; i += 2)
      (captured[i] as bool, captured[i + 1] as double?),
  ];
}

MockBackend _backendWithStatus(CameraStatus Function() status) {
  final backend = MockBackend();
  when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
  when(() => backend.getCameraStatus(any())).thenAnswer((_) async => status());
  when(
    () => backend.cameraSetCooling(
      deviceId: any(named: 'deviceId'),
      enabled: any(named: 'enabled'),
      targetTemp: any(named: 'targetTemp'),
    ),
  ).thenAnswer((_) async {});
  return backend;
}

void main() {
  test(
    'warming a camera whose cooler is off sends no cooler command',
    () async {
      final backend = _backendWithStatus(
        () => _status(coolerOn: false, power: 0),
      );
      final container = _container(backend);
      addTearDown(container.dispose);
      final camera = container.read(cameraStateProvider.notifier);
      camera.setCooling(false);
      camera.updateTemperature(11.1, 0);

      await container.read(deviceServiceProvider).warmCamera();

      verifyNever(
        () => backend.cameraSetCooling(
          deviceId: any(named: 'deviceId'),
          enabled: any(named: 'enabled'),
          targetTemp: any(named: 'targetTemp'),
        ),
      );
      expect(container.read(cameraStateProvider).isWarming, isFalse);
    },
  );

  test('an idle cooler is switched off at once, never re-seeded on', () async {
    final backend = _backendWithStatus(() => _status(coolerOn: true, power: 0));
    final container = _container(backend);
    addTearDown(container.dispose);

    await container.read(deviceServiceProvider).warmCamera();

    expect(_coolerCommands(backend), [(false, null)]);
    expect(container.read(cameraStateProvider).isWarming, isFalse);
    expect(container.read(cameraStateProvider).isCooling, isFalse);
  });

  test('canceling a warm-up puts back the set-point it replaced', () {
    fakeAsync((async) {
      final backend = _backendWithStatus(
        () => _status(coolerOn: true, power: 40, temp: -10, target: -10),
      );
      final container = _container(backend);
      final service = container.read(deviceServiceProvider);

      service.warmCamera();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      service.cancelWarmCamera();
      async.flushMicrotasks();

      final commands = _coolerCommands(backend);
      expect(commands.first, (true, -10.0));
      expect(commands.last, (true, -10.0), reason: '$commands');
      expect(container.read(cameraStateProvider).isWarming, isFalse);
      container.dispose();
    });
  });

  test(
    'a cancel while the seed is in flight still puts the set-point back',
    () {
      fakeAsync((async) {
        final backend = _backendWithStatus(
          () => _status(coolerOn: true, power: 40, temp: -8, target: -10),
        );
        final seed = Completer<void>();
        var first = true;
        when(
          () => backend.cameraSetCooling(
            deviceId: any(named: 'deviceId'),
            enabled: any(named: 'enabled'),
            targetTemp: any(named: 'targetTemp'),
          ),
        ).thenAnswer((_) {
          if (first) {
            first = false;
            return seed.future;
          }
          return Future.value();
        });
        final container = _container(backend);
        final service = container.read(deviceServiceProvider);

        service.warmCamera();
        async.flushMicrotasks();
        service.cancelWarmCamera();
        async.flushMicrotasks();
        seed.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();

        expect(_coolerCommands(backend).last, (true, -10.0));
        container.dispose();
      });
    },
  );

  test('a warm-up whose driver call never answers still ends', () {
    fakeAsync((async) {
      final backend = _backendWithStatus(
        () => _status(coolerOn: true, power: 1, temp: 5, target: -10),
      );
      var calls = 0;
      when(
        () => backend.cameraSetCooling(
          deviceId: any(named: 'deviceId'),
          enabled: any(named: 'enabled'),
          targetTemp: any(named: 'targetTemp'),
        ),
      ).thenAnswer((_) {
        calls++;
        return calls == 2 ? Completer<void>().future : Future.value();
      });
      when(() => backend.getCameraStatus(any())).thenAnswer(
        (_) async => _status(coolerOn: true, power: 40, temp: 5, target: -10),
      );
      final container = _container(backend);
      final service = container.read(deviceServiceProvider);

      service.warmCamera();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 35));
      async.flushMicrotasks();

      expect(container.read(cameraStateProvider).isWarming, isFalse);
      expect(_coolerCommands(backend).last.$1, isFalse);
      container.dispose();
    });
  });

  test('a run that owns the camera refuses a manual warm-up', () async {
    final backend = _backendWithStatus(
      () => _status(coolerOn: true, power: 40, temp: -10, target: -10),
    );
    final container = _container(backend);
    addTearDown(container.dispose);
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;

    await expectLater(
      container.read(deviceServiceProvider).warmCamera(),
      throwsA(isA<Exception>()),
    );
    verifyNever(
      () => backend.cameraSetCooling(
        deviceId: any(named: 'deviceId'),
        enabled: any(named: 'enabled'),
        targetTemp: any(named: 'targetTemp'),
      ),
    );
  });

  test(
    'failed seed command rolls warming state back and surfaces the error',
    () async {
      final backend = MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.cameraSetCooling(
          deviceId: any(named: 'deviceId'),
          enabled: any(named: 'enabled'),
          targetTemp: any(named: 'targetTemp'),
        ),
      ).thenThrow(StateError('driver rejected setpoint'));
      final container = _container(backend);
      addTearDown(container.dispose);

      await expectLater(
        container.read(deviceServiceProvider).warmCamera(),
        throwsA(isA<StateError>()),
      );

      expect(container.read(cameraStateProvider).isWarming, isFalse);
    },
  );

  test(
    'missing power telemetry does not masquerade as zero-power completion',
    () {
      fakeAsync((async) {
        final backend = MockBackend();
        when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
        when(
          () => backend.cameraSetCooling(
            deviceId: any(named: 'deviceId'),
            enabled: any(named: 'enabled'),
            targetTemp: any(named: 'targetTemp'),
          ),
        ).thenAnswer((_) async {});
        final container = _container(backend);
        final service = container.read(deviceServiceProvider);

        service.warmCamera();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        verifyNever(
          () => backend.cameraSetCooling(
            deviceId: any(named: 'deviceId'),
            enabled: false,
            targetTemp: any(named: 'targetTemp'),
          ),
        );
        expect(container.read(cameraStateProvider).isWarming, isTrue);

        service.cancelWarmCamera();
        container.dispose();
      });
    },
  );

  test(
    'cooler-off failure stays active and retries instead of claiming done',
    () {
      fakeAsync((async) {
        final backend = MockBackend();
        when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
        var offAttempts = 0;
        when(
          () => backend.cameraSetCooling(
            deviceId: any(named: 'deviceId'),
            enabled: any(named: 'enabled'),
            targetTemp: any(named: 'targetTemp'),
          ),
        ).thenAnswer((invocation) async {
          final enabled =
              invocation.namedArguments[const Symbol('enabled')] as bool;
          if (!enabled && ++offAttempts == 1) {
            throw StateError('temporary cooler-off failure');
          }
        });
        final container = _container(backend);
        container.read(cameraStateProvider.notifier).updateTemperature(-5, 30);
        final service = container.read(deviceServiceProvider);

        service.warmCamera();
        async.flushMicrotasks();
        container.read(cameraStateProvider.notifier).updateTemperature(-5, 1);
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(offAttempts, 1);
        expect(container.read(cameraStateProvider).isWarming, isTrue);
        expect(container.read(cameraStateProvider).isCooling, isTrue);

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(offAttempts, 2);
        expect(container.read(cameraStateProvider).isWarming, isFalse);
        expect(container.read(cameraStateProvider).isCooling, isFalse);

        container.dispose();
      });
    },
  );
}

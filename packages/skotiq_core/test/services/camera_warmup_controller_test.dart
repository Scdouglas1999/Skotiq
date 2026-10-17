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

void main() {
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
        container.read(cameraStateProvider.notifier).updateTemperature(-5, 1);
        final service = container.read(deviceServiceProvider);

        service.warmCamera();
        async.flushMicrotasks();
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

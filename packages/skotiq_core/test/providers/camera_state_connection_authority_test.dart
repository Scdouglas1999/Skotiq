import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockDeviceService extends Mock implements DeviceService {}

void main() {
  test(
    'late connect completion cannot mark a replacement camera connected',
    () async {
      final service = _MockDeviceService();
      final cameraAGate = Completer<void>();
      final cameraBGate = Completer<void>();
      when(
        () => service.connectCamera('camera-a'),
      ).thenAnswer((_) => cameraAGate.future);
      when(
        () => service.connectCamera('camera-b'),
      ).thenAnswer((_) => cameraBGate.future);
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          deviceServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(cameraStateProvider.notifier);

      final cameraA = notifier.connect('camera-a');
      final cameraB = notifier.connect('camera-b');
      cameraAGate.complete();
      await cameraA;

      var state = container.read(cameraStateProvider);
      expect(state.deviceId, 'camera-b');
      expect(state.connectionState, DeviceConnectionState.connecting);

      cameraBGate.complete();
      await cameraB;
      state = container.read(cameraStateProvider);
      expect(state.deviceId, 'camera-b');
      expect(state.connectionState, DeviceConnectionState.connected);
    },
  );

  test(
    'late disconnect completion cannot clear a replacement camera',
    () async {
      final service = _MockDeviceService();
      final disconnectGate = Completer<void>();
      final cameraBGate = Completer<void>();
      when(service.disconnectCamera).thenAnswer((_) => disconnectGate.future);
      when(
        () => service.connectCamera('camera-b'),
      ).thenAnswer((_) => cameraBGate.future);
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          deviceServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(cameraStateProvider.notifier);
      notifier.setConnecting('camera-a', 'Camera A');
      notifier.setConnected();

      final disconnect = notifier.disconnect();
      final cameraB = notifier.connect('camera-b');
      disconnectGate.complete();
      await disconnect;

      final state = container.read(cameraStateProvider);
      expect(state.deviceId, 'camera-b');
      expect(state.connectionState, DeviceConnectionState.connecting);
      cameraBGate.complete();
      await cameraB;
    },
  );
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockDeviceService extends Mock implements DeviceService {}

void main() {
  test(
    'late disconnect completion cannot clear a replacement camera',
    () async {
      final service = _MockDeviceService();
      final disconnectGate = Completer<void>();
      when(
        () => service.disconnect(DeviceType.camera),
      ).thenAnswer((_) => disconnectGate.future);
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
      // The device service connecting camera B while A is let go.
      notifier.setConnecting('camera-b', 'Camera B');
      disconnectGate.complete();
      await disconnect;

      final state = container.read(cameraStateProvider);
      expect(state.deviceId, 'camera-b');
      expect(state.connectionState, DeviceConnectionState.connecting);
    },
  );
}

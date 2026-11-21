import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/ffi_backend.dart';

void main() {
  test('a forgotten sweep is swept again, so a rescan shows what is plugged '
      'in now', () async {
    var sweeps = 0;
    final discovery = NativeDiscovery(() async {
      sweeps++;
      return {bridge.DeviceType.camera: const <bridge.DeviceInfo>[]};
    });

    await discovery.devices(bridge.DeviceType.camera);
    await discovery.devices(bridge.DeviceType.camera);
    expect(sweeps, 1, reason: 'callers inside the time to live share a sweep');

    discovery.forget();
    await discovery.devices(bridge.DeviceType.camera);
    expect(sweeps, 2);
  });

  test('an in-flight sweep invalidated by forget is not reused, and a sweep '
      'taken before native init is not cached', () async {
    final firstSweep =
        Completer<Map<bridge.DeviceType, List<bridge.DeviceInfo>>>();
    var calls = 0;
    var ready = false;
    final discovery = NativeDiscovery(() async {
      calls++;
      if (calls == 1) return firstSweep.future;
      return {
        bridge.DeviceType.camera: [
          const bridge.DeviceInfo(
            id: 'cam-fresh',
            name: 'Fresh Cam',
            deviceType: bridge.DeviceType.camera,
            driverType: bridge.DriverType.simulator,
            description: 'Simulator camera',
            driverVersion: '1.0',
            displayName: 'Fresh Cam',
          ),
        ],
      };
    }, canCache: () => ready);

    final pending = discovery.devices(bridge.DeviceType.camera);
    await Future<void>.delayed(Duration.zero);
    discovery.forget();
    firstSweep.complete({bridge.DeviceType.camera: const []});

    final cams = await pending;
    expect(calls, 2);
    expect(cams.map((c) => c.id), ['cam-fresh']);

    await discovery.devices(bridge.DeviceType.camera);
    expect(calls, 3, reason: 'an uncached sweep is not reused');

    ready = true;
    await discovery.devices(bridge.DeviceType.camera);
    await discovery.devices(bridge.DeviceType.camera);
    expect(calls, 4, reason: 'a ready sweep is reused within the time to live');
  });
}

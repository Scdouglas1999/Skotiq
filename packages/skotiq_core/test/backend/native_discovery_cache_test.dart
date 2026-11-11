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
}

// A connect sweep counts devices the way the equipment screen shows them: the
// built-in guider's guide camera is part of the guider.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/device_connection_progress_provider.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/services/device_exceptions.dart';

DeviceConnectProgress _event(
  String label,
  DeviceConnectProgressStatus status, {
  String? error,
}) =>
    DeviceConnectProgress(
      deviceType: label,
      deviceId: 'id-$label',
      status: status,
      errorMessage: error,
    );

DeviceConnectionProgressState _sweep(List<DeviceConnectProgress> events) =>
    DeviceConnectionProgressState(
      isSweeping: false,
      byDeviceType: {for (final e in events) e.deviceType: e},
    );

void main() {
  const ok = DeviceConnectProgressStatus.connected;
  const failed = DeviceConnectProgressStatus.failed;

  test('a guider and its guide camera count as one device', () {
    final sweep = _sweep([
      _event('camera', ok),
      _event('mount', ok),
      _event(guideCameraLabel, ok),
      _event('guider', ok),
    ]);

    expect(sweep.byDevice.keys, ['camera', 'mount', 'guider']);
    expect(sweep.connectedCount, 3);
    expect(sweep.failures, isEmpty);
  });

  test("a guide camera that failed is the guider's failure, with its reason",
      () {
    final sweep = _sweep([
      _event('camera', ok),
      _event(guideCameraLabel, failed, error: 'USB cable unplugged'),
      _event('guider', failed, error: 'no frames'),
    ]);

    expect(sweep.connectedCount, 1);
    final failure = sweep.failures.single;
    expect(failure.deviceType, 'guider');
    expect(failure.deviceId, 'id-guider');
    expect(failure.errorMessage, contains('guide camera'));
    expect(failure.errorMessage, contains('USB cable unplugged'));
  });

  test('a guide camera without a guider keeps its own entry', () {
    final sweep = _sweep([_event(guideCameraLabel, ok)]);

    expect(sweep.byDevice.keys, [guideCameraLabel]);
    expect(sweep.connectedCount, 1);
  });
}

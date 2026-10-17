import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/utils/connect_all_summary.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('formatConnectAllSnackBar', () {
    test('single failure includes device type and message', () {
      final text = formatConnectAllSnackBar(
        successCount: 0,
        failCount: 1,
        failures: const [
          ConnectAllFailure(
            deviceType: 'camera',
            message: 'NotConnectedException: device offline',
          ),
        ],
      );
      expect(text, contains('camera'));
      expect(text, contains('device offline'));
    });

    test('partial success mentions first failure', () {
      final text = formatConnectAllSnackBar(
        successCount: 2,
        failCount: 1,
        failures: const [
          ConnectAllFailure(deviceType: 'mount', message: 'timeout'),
        ],
      );
      expect(text, contains('Connected 2'));
      expect(text, contains('mount: timeout'));
    });

    test('fromProgress uses pretty error pipeline', () {
      final failure = ConnectAllFailure.fromProgress(
        const DeviceConnectProgress(
          deviceType: 'camera',
          deviceId: 'native:camera:1',
          status: DeviceConnectProgressStatus.failed,
          errorMessage: '0x80040403',
        ),
      );
      expect(failure.message, isNotEmpty);
    });
  });
}

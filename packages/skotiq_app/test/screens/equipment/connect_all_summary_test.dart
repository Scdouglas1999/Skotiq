import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/utils/connect_all_summary.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

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

    test('a failed device reads as its device card does', () {
      const raw = 'USB device not found (0x80040403)';
      final failure = ConnectAllFailure.fromProgress(
        const DeviceConnectProgress(
          deviceType: 'filter wheel',
          deviceId: 'ascom:ASCOM.EFW.FilterWheel',
          status: DeviceConnectProgressStatus.failed,
          errorMessage: raw,
        ),
      );
      final card = diagnoseConnectionFailure(
        deviceType: DeviceType.filterWheel,
        driverType: DriverType.ascom,
        rawError: raw,
      );
      expect(failure.message, card.headline);
      expect(failure.detail, contains(card.headline));
      expect(failure.detail, contains(raw));
    });

    test('the reason is said once, without its wrappers', () {
      final failure = ConnectAllFailure.fromProgress(
        const DeviceConnectProgress(
          deviceType: 'guider',
          deviceId: 'builtin:guider',
          status: DeviceConnectProgressStatus.failed,
          errorMessage: 'Failed to connect built-in guider: Operation failed: '
              'requires an active profile with a guide focal length',
        ),
      );
      expect(
          failure.detail,
          endsWith(
            ': requires an active profile with a guide focal length',
          ));
      expect(failure.detail, isNot(contains('Operation failed')));
      expect(failure.detail, isNot(contains('Failed to connect')));
    });
  });
}

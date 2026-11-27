import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

CoolerState _coolerState(CameraStateSnapshot camera) => camera.coolerState;

void main() {
  group('CameraStateSnapshot.coolerState', () {
    const connected = DeviceConnectionState.connected;

    test('reads the camera snapshot', () {
      expect(
        _coolerState(const CameraStateSnapshot()),
        CoolerState.notConnected,
      );
      // A camera that does not report its cooler is not shown as off.
      expect(
        _coolerState(const CameraStateSnapshot(connectionState: connected)),
        CoolerState.notReported,
      );
      expect(
        _coolerState(
          const CameraStateSnapshot(
            connectionState: connected,
            coolerOn: false,
          ),
        ),
        CoolerState.off,
      );
      expect(
        _coolerState(
          const CameraStateSnapshot(
            connectionState: connected,
            coolerOn: true,
            temperature: -9.7,
          ),
        ),
        CoolerState.atSetpoint,
      );
      expect(
        _coolerState(
          const CameraStateSnapshot(
            connectionState: connected,
            coolerOn: true,
            temperature: -7.4,
          ),
        ),
        CoolerState.cooling,
      );
      // Cooling with no temperature reading is not "at setpoint".
      expect(
        _coolerState(
          const CameraStateSnapshot(connectionState: connected, coolerOn: true),
        ),
        CoolerState.cooling,
      );
      expect(
        _coolerState(
          const CameraStateSnapshot(
            connectionState: connected,
            coolerOn: true,
            isWarming: true,
          ),
        ),
        CoolerState.warming,
      );
    });
  });
}

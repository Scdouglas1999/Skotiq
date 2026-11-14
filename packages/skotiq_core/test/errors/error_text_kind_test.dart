import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';

/// The FFI fallback ([SkotiqError.fromString]) and the device slots
/// ([DeviceError.fromException]) read an error's text one way.
void main() {
  const cases = {
    'Operation timed out': (
      ErrorTextKind.timeout,
      BackendErrorCategory.timeout,
      DeviceErrorType.timeout,
    ),
    'Device not found': (
      ErrorTextKind.notFound,
      BackendErrorCategory.connection,
      DeviceErrorType.deviceNotFound,
    ),
    'Failed to connect to camera': (
      ErrorTextKind.connection,
      BackendErrorCategory.connection,
      DeviceErrorType.connectionFailed,
    ),
    'Access denied': (
      ErrorTextKind.permission,
      BackendErrorCategory.system,
      DeviceErrorType.permissionDenied,
    ),
    'Filter wheel is busy': (
      ErrorTextKind.busy,
      BackendErrorCategory.busy,
      DeviceErrorType.busy,
    ),
    'Gain out of range': (
      ErrorTextKind.invalid,
      BackendErrorCategory.validation,
      DeviceErrorType.invalidParameter,
    ),
    'ASCOM driver threw': (
      ErrorTextKind.driver,
      BackendErrorCategory.driver,
      DeviceErrorType.driverError,
    ),
    'Something else': (
      ErrorTextKind.unknown,
      BackendErrorCategory.unknown,
      DeviceErrorType.unknown,
    ),
  };

  for (final MapEntry(key: text, value: want) in cases.entries) {
    test(text, () {
      expect(classifyErrorText(text), want.$1);
      expect(SkotiqError.fromString(text).category, want.$2);
      expect(DeviceError.fromException(Exception(text)).type, want.$3);
    });
  }

  test('a device error passes through unchanged', () {
    final error = DeviceError(
      type: DeviceErrorType.connectionFailed,
      message: 'Failed to open the port',
      timestamp: DateTime.utc(2026),
    );
    expect(DeviceError.fromException(error), same(error));
  });
}

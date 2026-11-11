import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/device_connect_exception.dart';
import 'package:skotiq_core/src/models/errors/server_error.dart';

void main() {
  test('a failed connect is explained in the driver\'s own words', () {
    const error = DeviceConnectException(
      'native:builtin_guider:multi_star',
      'SkotiqError.connectionFailed(...)',
      reason: 'The built-in guider needs a guide camera of its own.',
    );
    expect(
      connectFailureReason(error),
      'The built-in guider needs a guide camera of its own.',
    );
  });

  test('the technical text keeps what the troubleshooter matches on', () {
    const error = DeviceConnectException('ascom:Cam', 'boom', reason: 'r');
    expect(
      error.toString(),
      'Exception: Failed to connect to ascom:Cam via native bridge: boom',
    );
  });

  test('a connect with no driver sentence is explained by its cause', () {
    const error = DeviceConnectException('x', 'port busy');
    expect(connectFailureReason(error), 'port busy');
  });

  test('a linked client shows the message the imaging host wrote', () {
    const error = ServerError(
      code: 'device_connect_failed',
      message: 'The built-in guider needs a guide camera of its own.',
      httpStatus: 409,
    );
    expect(
      connectFailureReason(error),
      'The built-in guider needs a guide camera of its own.',
    );
  });

  test('Dart exception renderings are not shown as part of the reason', () {
    expect(
      connectFailureReason(StateError('The focuser did not report')),
      'The focuser did not report',
    );
    expect(
      connectFailureReason(Exception('Mount driver refused')),
      'Mount driver refused',
    );
  });
}

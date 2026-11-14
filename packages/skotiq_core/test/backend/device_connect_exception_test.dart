import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/device_connect_exception.dart';
import 'package:skotiq_core/src/errors/error_text.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/errors/server_error.dart';
import 'package:skotiq_remote_protocol/wire.dart';

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

  test('the body the host answers a failed connect with reads back as its '
      'sentence', () {
    const sentence = 'The focuser opened but did not report its position.';
    final body = const ApiErrorBody(
      code: 'device_connect_failed',
      message: sentence,
      layout: ApiErrorLayout.codeAsError,
      details: {'deviceId': 'sim_focuser', 'deviceType': 'focuser'},
    ).toJson();

    final error = ServerError.tryFromJson(body, httpStatus: 409);

    expect(error?.code, 'device_connect_failed');
    expect(connectFailureReason(error!), sentence);
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

  // A linked client whose connect request ran out of time showed
  // "TimeoutException after 0:00:30.000000: Future not completed".
  test('a connect that ran out of time is said in a sentence', () {
    expect(
      connectFailureReason(
        TimeoutException('Future not completed', const Duration(seconds: 30)),
      ),
      'No answer after 30 s. It may still be connecting.',
    );
  });

  // The slot of a device that did not connect showed "Failed to connect to
  // sim_focuser_1 via native bridge: ..." once nothing else overwrote it.
  test('a failed connect reads as its reason wherever errors are worded', () {
    const error = DeviceConnectException(
      'sim_focuser_1',
      'SkotiqError.connectionFailed(...)',
      reason: 'The hub lost power',
    );
    expect(userFacingError(error), 'The hub lost power');
    expect(DeviceError.fromException(error).message, 'The hub lost power');
  });
}

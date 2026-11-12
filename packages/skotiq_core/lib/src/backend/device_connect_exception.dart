import 'dart:async';

import '../models/errors/server_error.dart';
import 'bridge_error_message.dart';

/// A driver refused or failed a connect.
///
/// [toString] is the full technical text, which the log and the connection
/// troubleshooter read. [reason] is the driver's own sentence when it gave
/// one ("The built-in guider needs a guide camera of its own…"), for the
/// places that tell the operator why in one line.
class DeviceConnectException implements Exception {
  const DeviceConnectException(this.deviceId, this.cause, {this.reason});

  final String deviceId;
  final Object cause;
  final String? reason;

  @override
  String toString() =>
      'Exception: Failed to connect to $deviceId via native bridge: $cause';
}

/// Why a connect failed, for a one-line surface: the sentence the driver or
/// the imaging host wrote, not the rendering of the exception that carried
/// it.
String connectFailureReason(Object error) {
  final text = switch (error) {
    DeviceConnectException(:final reason?) => reason,
    DeviceConnectException(:final cause) => connectFailureReason(cause),
    ServerError(:final message) => message,
    StateError(:final message) => message,
    // The device was not refused; nobody answered in time, and the driver
    // may still be opening it.
    TimeoutException(:final duration) =>
      duration == null
          ? 'No answer in time. It may still be connecting.'
          : 'No answer after ${duration.inSeconds} s. It may still be '
                'connecting.',
    _ => bridgeErrorMessage(error) ?? error.toString(),
  };
  const dartException = 'Exception: ';
  return text.startsWith(dartException)
      ? text.substring(dartException.length)
      : text;
}

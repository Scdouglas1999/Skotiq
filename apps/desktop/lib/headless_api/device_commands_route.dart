import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'validation.dart';

/// The host's shared device command path ([DeviceCommands]): a command for
/// the device in the host's slot goes through `DeviceService`, exactly as the
/// host UI sends it, so a slave's, phone's or script's command gets the same
/// focus offsets, checks, state writes and log lines.
DeviceCommands deviceCommandsOf(ProviderContainer container) =>
    container.read(deviceCommandsProvider);

/// Run [command] and answer a refusal the way the host UI reports it: a busy
/// device (a move in progress, autofocus running) as 409 `device_busy`, a
/// target the device or driver range does not allow as 400, and a command
/// the driver cannot do as 400 `capability_unsupported`.
Future<T> runDeviceCommand<T>(
  String deviceId,
  Future<T> Function() command,
) async {
  try {
    return await command();
  } on StateError catch (e) {
    throw HandlerFailure(
      code: 'device_busy',
      message: e.message,
      statusCode: HttpStatus.conflict,
      details: {'deviceId': deviceId},
    );
  } on ArgumentError catch (e) {
    final field = e.name ?? 'value';
    throw BadRequestError(
      field: field,
      expected: e is RangeError && e.start != null && e.end != null
          ? '${e.start} to ${e.end}'
          : 'a value $deviceId accepts',
      message: '$deviceId refused $field ${e.invalidValue}: ${e.message}',
    );
  } on UnsupportedError catch (e) {
    throw HandlerFailure(
      code: 'capability_unsupported',
      message: e.message ?? '$deviceId does not support this command',
      statusCode: HttpStatus.badRequest,
      details: {'deviceId': deviceId},
    );
  }
}

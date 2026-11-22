import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

/// What the GUI reads (core's error) and what a remote client reads (the
/// host's REST reply) for one instance of every bridge error variant, pinned
/// in `fixtures/bridge_error_text.json`. `SKOTIQ_RECORD_REPLIES=1` rewrites it.
const _variants = <String, bridge.SkotiqError>{
  'deviceNotFound': bridge.SkotiqError.deviceNotFound('native:zwo:9'),
  'connectionFailed': bridge.SkotiqError.connectionFailed(
    deviceId: 'native:zwo:0',
    reason: 'USB device busy',
  ),
  'alreadyConnected': bridge.SkotiqError.alreadyConnected('native:zwo:0'),
  'notConnected': bridge.SkotiqError.notConnected('native:zwo:0'),
  'deviceDisconnected': bridge.SkotiqError.deviceDisconnected(
    deviceId: 'native:zwo:0',
    reason: 'cable pulled',
  ),
  'hardwareError': bridge.SkotiqError.hardwareError(
    deviceId: 'native:zwo:0',
    message: 'shutter jam',
    errorCode: 7,
  ),
  'hardwareErrorNoDevice': bridge.SkotiqError.hardwareError(
    deviceId: '',
    message: 'shutter jam',
  ),
  'communicationError': bridge.SkotiqError.communicationError(
    deviceId: 'native:zwo:0',
    message: 'usb stall',
  ),
  'timeout': bridge.SkotiqError.timeout('slew'),
  'deviceTimeout': bridge.SkotiqError.deviceTimeout(
    deviceId: 'native:zwo:0',
    operation: 'download',
    timeoutSecs: 30.25,
  ),
  'connectionTimeout': bridge.SkotiqError.connectionTimeout(
    deviceId: 'native:zwo:0',
    timeoutSecs: 10,
  ),
  'invalidParameter': bridge.SkotiqError.invalidParameter('gain'),
  'invalidInput': bridge.SkotiqError.invalidInput('nope'),
  'invalidDeviceId': bridge.SkotiqError.invalidDeviceId(
    deviceId: 'indi:x',
    reason: 'Invalid INDI device ID format',
  ),
  'invalidDeviceIdEmpty': bridge.SkotiqError.invalidDeviceId(
    deviceId: '',
    reason: 'Invalid INDI device ID format',
  ),
  'parameterOutOfRange': bridge.SkotiqError.parameterOutOfRange(
    paramName: 'gain',
    value: '99999',
    min: '0',
    max: '600',
  ),
  'operationFailed': bridge.SkotiqError.operationFailed('sdk blew up'),
  'operationFailedEmpty': bridge.SkotiqError.operationFailed('  '),
  'notSupported': bridge.SkotiqError.notSupported(
    deviceId: 'ascom:X',
    operation: 'setGain',
  ),
  'deviceBusy': bridge.SkotiqError.deviceBusy(
    deviceId: 'native:zwo:0',
    currentOperation: 'exposing',
  ),
  'refused': bridge.SkotiqError.refused(
    kind: bridge.Refusal.noLockPosition,
    message: 'Failed to get lock position: no lock',
  ),
  'refusedLightLeak': bridge.SkotiqError.refused(
    kind: bridge.Refusal.lightLeak,
    message: 'light leak: 3 of 9 frames',
  ),
  'invalidState': bridge.SkotiqError.invalidState(
    'Guiding is paused. Resume guiding before dithering.',
  ),
  'imageError': bridge.SkotiqError.imageError('bad stride'),
  'cameraError': bridge.SkotiqError.cameraError('no sensor'),
  'noImageAvailable': bridge.SkotiqError.noImageAvailable(),
  'exposureCancelled': bridge.SkotiqError.exposureCancelled(),
  'exposureFailed': bridge.SkotiqError.exposureFailed(
    cameraId: 'native:zwo:0',
    reason: 'Image is completely saturated',
  ),
  'downloadFailed': bridge.SkotiqError.downloadFailed(
    cameraId: 'native:zwo:0',
    reason: 'usb reset',
  ),
  'ioError': bridge.SkotiqError.ioError('disk gone'),
  'serializationError': bridge.SkotiqError.serializationError('bad json'),
  'plateSolveError': bridge.SkotiqError.plateSolveError('no match'),
  'sequenceError': bridge.SkotiqError.sequenceError('node missing'),
  'ascomError': bridge.SkotiqError.ascomError(
    progId: 'ASCOM.ASICamera2.Camera',
    message: 'Gain not implemented',
    errorCode: 1024,
  ),
  'alpacaError': bridge.SkotiqError.alpacaError(
    baseUrl: 'http://127.0.0.1:11111',
    deviceNumber: 0,
    message: 'NotImplemented',
    errorCode: 1024,
  ),
  'indiError': bridge.SkotiqError.indiError(
    server: 'localhost',
    port: 7624,
    deviceName: 'CCD Simulator',
    message: 'BLOB timeout',
  ),
  'nativeError': bridge.SkotiqError.nativeError(
    vendor: 'ZWO',
    message: 'ASI_ERROR_INVALID_SIZE',
    errorCode: 6,
  ),
  'comError': bridge.SkotiqError.comError(
    message: 'Member not found',
    hresult: 2147614723,
  ),
  'internal': bridge.SkotiqError.internal('bug'),
  'cancelled': bridge.SkotiqError.cancelled(),
  'runtimeInitFailed': bridge.SkotiqError.runtimeInitFailed('no tokio'),
  'resourceExhausted': bridge.SkotiqError.resourceExhausted(
    resource: 'disk',
    message: 'no space left',
  ),
};

final _fixture = File('test/headless_api/fixtures/bridge_error_text.json');

Map<String, Object?> _core(bridge.SkotiqError error) {
  final core = skotiqErrorFromBridge(error);
  return {
    'category': core.category.name,
    'message': core.message,
    'userMessage': core.userMessage,
    'reason': core.reason,
    'isRecoverable': core.isRecoverable,
    'shouldReconnect': core.shouldReconnect,
    'isTimeout': core.isTimeout,
    'deviceId': core.deviceId,
    'errorCode': core.errorCode,
    'bridgeErrorMessage': bridgeErrorMessage(error),
  };
}

Future<Map<String, Object?>> _host(bridge.SkotiqError error) async {
  final handler = errorTranslationMiddleware(
    logError: (_, {fields}) {},
    requestIdFor: (_) => 'test-request-id',
  )((_) => throw error);
  final response = await handler(
    Request('GET', Uri.parse('http://localhost/api/pin')),
  );
  return {
    'status': response.statusCode,
    'body': jsonDecode(await response.readAsString()),
    'describeBackendError': describeBackendError(error),
  };
}

void main() {
  final record = Platform.environment['SKOTIQ_RECORD_REPLIES'] == '1';
  final recorded = <String, Object?>{};
  final expected = record
      ? const <String, Object?>{}
      : jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>;

  test('every pinned variant has a row and every row a pin', () {
    if (record) return;
    expect(_variants.keys.toSet(), expected.keys.toSet());
  });

  for (final MapEntry(key: name, value: error) in _variants.entries) {
    test(name, () async {
      final row = {'core': _core(error), 'host': await _host(error)};
      if (record) {
        recorded[name] = row;
        return;
      }
      expect(row, expected[name]);
    });

    test('$name: a remote client reads the published sentence', () async {
      final sentence = bridgeErrorSentence(error).trim();
      if (sentence.isEmpty) return;
      final body = (await _host(error))['body'] as Map<String, Object?>;
      expect(body['message'], sentence);
    });
  }

  tearDownAll(() {
    if (!record) return;
    _fixture.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(recorded)}\n',
    );
  });
}

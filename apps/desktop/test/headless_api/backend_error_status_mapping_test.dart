import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

/// Pins the `SkotiqError` -> HTTP status table in
/// `errorTranslationMiddleware`.
///
/// The table exists so a remote client gets an actionable status instead of an
/// opaque 500, and only genuinely internal faults fall through to `orElse`.
/// Observed live: a completely saturated frame from a real ASI1600MM-Cool
/// answers `500 internal_error` when the bridge reports the rejection as the
/// unclassified `OperationFailed` and nothing maps the frame-rejection case.
/// `ExposureFailed` carries it and maps to 422.
void main() {
  Future<Response> throwing(bridge_error.SkotiqError error) async {
    final handler = errorTranslationMiddleware(
      logError: (_, {fields}) {},
      requestIdFor: (_) => 'test-request-id',
    )((_) => throw error);
    return await handler(Request('POST', Uri.parse('http://localhost/api/x')));
  }

  Future<({int status, Map<String, Object?> body})> call(
    bridge_error.SkotiqError error,
  ) async {
    final response = await throwing(error);
    final body =
        jsonDecode(await response.readAsString()) as Map<String, Object?>;
    return (status: response.statusCode, body: body);
  }

  test('a validation-rejected frame is 422, not 500', () async {
    const reason =
        'Image is completely saturated (min value 65224 >= 65024) - '
        'significantly reduce exposure time or gain';
    final result = await call(
      const bridge_error.SkotiqError.exposureFailed(
        cameraId: 'native:zwo:0',
        reason: reason,
      ),
    );

    expect(result.status, 422);
    // Below 500 the envelope must say `device_error`: the camera worked and the
    // server did not fail, so a retry-on-5xx client must not treat this as
    // transient.
    expect(result.body['error'], 'device_error');
    // The operator-actionable reason has to survive to the wire.
    expect(result.body['message'], contains('completely saturated'));
    expect(result.body['message'], contains('reduce exposure time or gain'));
    expect(result.body['requestId'], 'test-request-id');
    // The wire body must never carry the freezed constructor form. Named-field
    // variants have no `field0`, so before this was special-cased the message
    // shipped as
    // "SkotiqError.exposureFailed(cameraId: native:zwo:0, reason: ...)"
    // — observed live against the rig.
    expect(
      result.body['message'],
      reason,
      reason: 'reason verbatim, no wrapper',
    );
    expect(result.body['message'], isNot(contains('SkotiqError')));
    expect(result.body['message'], isNot(contains('cameraId:')));
  });

  test('genuine internal faults still answer 500 internal_error', () async {
    final result = await call(
      const bridge_error.SkotiqError.operationFailed(
        'SDK error: Failed to call method StartExposure',
      ),
    );

    expect(result.status, 500);
    expect(result.body['error'], 'internal_error');
  });

  // The wire `message` is rendered verbatim by remote/mobile clients, so it
  // must always be a sentence an operator can act on. Observed live on a
  // running instance with no image captured:
  //   GET /api/camera/last-image  -> {"error":"device_error",
  //        "message":"SkotiqError.noImageAvailable()"}
  //   GET /api/imaging/raw-data   -> same
  //   GET /api/run-watch/frame-thumbnail ->
  //        "Failed to fetch last image: SkotiqError.noImageAvailable()"
  // Cause: a message cleaner that only unwraps variants with a single
  // positional `field0` lets zero-arg and named-field variants fall through to
  // `toString()`, which is the freezed constructor form.
  test('no variant ever leaks the freezed constructor form', () async {
    final variants = <bridge_error.SkotiqError>[
      // zero-arg
      const bridge_error.SkotiqError.noImageAvailable(),
      const bridge_error.SkotiqError.exposureCancelled(),
      const bridge_error.SkotiqError.cancelled(),
      // named-field, previously unhandled
      const bridge_error.SkotiqError.comError(
        message: 'Member not found',
        hresult: -2147352573,
      ),
      const bridge_error.SkotiqError.ascomError(
        progId: 'ASCOM.ASICamera2.Camera',
        message: 'Gain not implemented',
        errorCode: 1024,
      ),
      const bridge_error.SkotiqError.alpacaError(
        baseUrl: 'http://127.0.0.1:11111',
        deviceNumber: 0,
        message: 'NotImplemented',
        errorCode: 1024,
      ),
      const bridge_error.SkotiqError.indiError(
        server: 'localhost',
        port: 7624,
        deviceName: 'CCD Simulator',
        message: 'BLOB timeout',
      ),
      const bridge_error.SkotiqError.nativeError(
        vendor: 'ZWO',
        message: 'ASI_ERROR_INVALID_SIZE',
        errorCode: 6,
      ),
      const bridge_error.SkotiqError.hardwareError(
        deviceId: 'native:zwo:0',
        message: 'shutter jam',
      ),
      const bridge_error.SkotiqError.communicationError(
        deviceId: 'native:zwo:0',
        message: 'usb stall',
      ),
      const bridge_error.SkotiqError.connectionFailed(
        deviceId: 'native:zwo:0',
        reason: 'device busy',
      ),
      const bridge_error.SkotiqError.deviceDisconnected(
        deviceId: 'native:zwo:0',
        reason: 'cable pulled',
      ),
      const bridge_error.SkotiqError.deviceTimeout(
        deviceId: 'native:zwo:0',
        operation: 'download',
        timeoutSecs: 30,
      ),
      const bridge_error.SkotiqError.connectionTimeout(
        deviceId: 'native:zwo:0',
        timeoutSecs: 10,
      ),
      const bridge_error.SkotiqError.parameterOutOfRange(
        paramName: 'gain',
        value: '99999',
        min: '0',
        max: '600',
      ),
      const bridge_error.SkotiqError.deviceBusy(
        deviceId: 'native:zwo:0',
        currentOperation: 'exposing',
      ),
      const bridge_error.SkotiqError.resourceExhausted(
        resource: 'disk',
        message: 'no space left',
      ),
      const bridge_error.SkotiqError.downloadFailed(
        cameraId: 'native:zwo:0',
        reason: 'usb reset',
      ),
      const bridge_error.SkotiqError.notSupported(
        deviceId: '',
        operation: 'Operation not supported',
      ),
      const bridge_error.SkotiqError.invalidDeviceId(
        deviceId: '',
        reason: 'Invalid INDI device ID format',
      ),
      // positional
      const bridge_error.SkotiqError.operationFailed('sdk blew up'),
      const bridge_error.SkotiqError.internal('bug'),
      const bridge_error.SkotiqError.runtimeInitFailed('no tokio'),
      const bridge_error.SkotiqError.alreadyConnected('native:zwo:0'),
      const bridge_error.SkotiqError.imageError('bad stride'),
      const bridge_error.SkotiqError.cameraError('no sensor'),
      const bridge_error.SkotiqError.ioError('disk gone'),
      const bridge_error.SkotiqError.serializationError('bad json'),
      const bridge_error.SkotiqError.plateSolveError('no match'),
      const bridge_error.SkotiqError.sequenceError('node missing'),
      const bridge_error.SkotiqError.invalidInput('nope'),
    ];

    for (final variant in variants) {
      final result = await call(variant);
      final message = result.body['message'] as String?;
      expect(
        message,
        isNotNull,
        reason: '${variant.runtimeType} produced no message',
      );
      expect(
        message,
        isNot(contains('SkotiqError')),
        reason: '${variant.runtimeType} leaked the constructor form: $message',
      );
      expect(
        message!.trim(),
        isNotEmpty,
        reason: '${variant.runtimeType} produced an empty message',
      );
    }
  });

  test('the rest of the mapping table is unchanged', () async {
    final expected = <bridge_error.SkotiqError, int>{
      const bridge_error.SkotiqError.notSupported(
        deviceId: 'ascom:X',
        operation: 'setGain',
      ): 501,
      const bridge_error.SkotiqError.notConnected('native:zwo:0'): 409,
      const bridge_error.SkotiqError.deviceNotFound('native:zwo:9'): 404,
      const bridge_error.SkotiqError.invalidParameter('gain'): 400,
      const bridge_error.SkotiqError.exposureCancelled(): 409,
      const bridge_error.SkotiqError.noImageAvailable(): 404,
      const bridge_error.SkotiqError.timeout('slew'): 504,
    };

    // The wire code per status. Only a genuine 500 is `internal_error`:
    // covering everything `>= 500` with it makes a capability the camera does
    // not have — `POST /api/camera/cooling` on a cooler-less camera — read as
    // an appliance fault.
    const codeForStatus = <int, String>{
      400: 'device_error',
      404: 'device_error',
      409: 'device_error',
      501: 'not_supported',
      502: 'device_unreachable',
      504: 'device_timeout',
    };

    for (final entry in expected.entries) {
      final result = await call(entry.key);
      expect(
        result.status,
        entry.value,
        reason: '${entry.key.runtimeType} should map to ${entry.value}',
      );
      expect(
        result.body['error'],
        codeForStatus[entry.value],
        reason:
            '${entry.key.runtimeType} (${entry.value}) must not be labelled '
            'internal_error — no retry and no restart clears a capability the '
            'device does not have',
      );
    }
  });

  test('a not-supported capability is not an internal fault', () async {
    // The exact rig case, kept as its own test because the label is the
    // finding: the status was right and the code pointed at the appliance.
    final result = await call(
      const bridge_error.SkotiqError.notSupported(
        deviceId: 'native:zwo:1',
        operation: 'setCoolerOn',
      ),
    );

    expect(result.status, 501);
    expect(result.body['error'], 'not_supported');
    expect(result.body['error'], isNot('internal_error'));
  });
}

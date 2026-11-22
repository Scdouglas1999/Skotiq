import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';

/// Today's answers of every error classification, pinned before the error
/// families are folded into one type. A row that changes here is a behavior
/// change and needs its own commit.
void main() {
  group('a text kind decides category, recoverable and reconnect', () {
    // (text, category, recoverable, reconnect) from SkotiqError.fromString,
    // (device type, recoverable) from DeviceError.fromException.
    const rows =
        <(String, BackendErrorCategory, bool, bool, DeviceErrorType, bool)>[
          (
            'Operation timed out',
            BackendErrorCategory.timeout,
            true,
            false,
            DeviceErrorType.timeout,
            true,
          ),
          (
            'Device not found',
            BackendErrorCategory.connection,
            false,
            false,
            DeviceErrorType.deviceNotFound,
            false,
          ),
          (
            'Failed to connect to camera',
            BackendErrorCategory.connection,
            true,
            true,
            DeviceErrorType.connectionFailed,
            true,
          ),
          (
            'Access denied',
            BackendErrorCategory.system,
            false,
            false,
            DeviceErrorType.permissionDenied,
            false,
          ),
          (
            'Filter wheel is busy',
            BackendErrorCategory.busy,
            true,
            false,
            DeviceErrorType.busy,
            true,
          ),
          (
            'Hardware fault on focuser',
            BackendErrorCategory.hardware,
            true,
            false,
            DeviceErrorType.communicationError,
            true,
          ),
          (
            'Gain out of range',
            BackendErrorCategory.validation,
            false,
            false,
            DeviceErrorType.invalidParameter,
            true,
          ),
          (
            'Pulse guiding unsupported',
            BackendErrorCategory.unsupported,
            false,
            false,
            DeviceErrorType.invalidParameter,
            true,
          ),
          (
            'Exposure aborted',
            BackendErrorCategory.imaging,
            false,
            false,
            DeviceErrorType.driverError,
            true,
          ),
          (
            'ASCOM driver threw',
            BackendErrorCategory.driver,
            false,
            false,
            DeviceErrorType.driverError,
            true,
          ),
          (
            'Something odd',
            BackendErrorCategory.unknown,
            false,
            false,
            DeviceErrorType.unknown,
            true,
          ),
        ];
    for (final (text, category, recoverable, reconnect, type, deviceOk)
        in rows) {
      test(text, () {
        final error = SkotiqError.fromString(text);
        expect(error.category, category);
        expect(error.isRecoverable, recoverable);
        expect(error.shouldReconnect, reconnect);
        expect(error.isTimeout, category == BackendErrorCategory.timeout);
        final device = DeviceError.fromException(Exception(text));
        expect(device.type, type);
        expect(device.recoverable, deviceOk);
      });
    }
  });

  group('a typed core error keeps its own answers on a device card', () {
    test('category picks the type, the flag the recoverability', () {
      const expected = {
        BackendErrorCategory.connection: DeviceErrorType.connectionFailed,
        BackendErrorCategory.hardware: DeviceErrorType.communicationError,
        BackendErrorCategory.timeout: DeviceErrorType.timeout,
        BackendErrorCategory.validation: DeviceErrorType.invalidParameter,
        BackendErrorCategory.unsupported: DeviceErrorType.invalidParameter,
        BackendErrorCategory.busy: DeviceErrorType.busy,
        BackendErrorCategory.imaging: DeviceErrorType.driverError,
        BackendErrorCategory.io: DeviceErrorType.driverError,
        BackendErrorCategory.sequence: DeviceErrorType.driverError,
        BackendErrorCategory.driver: DeviceErrorType.driverError,
        BackendErrorCategory.system: DeviceErrorType.unknown,
        BackendErrorCategory.unknown: DeviceErrorType.unknown,
      };
      for (final MapEntry(key: category, value: type) in expected.entries) {
        for (final recoverable in [true, false]) {
          final device = DeviceError.fromException(
            SkotiqError(
              category: category,
              message: 'm',
              userMessage: 'Shown',
              isRecoverable: recoverable,
              errorCode: 7,
              deviceId: 'cam',
            ),
          );
          expect(device.type, type, reason: '$category');
          expect(device.recoverable, recoverable);
          expect(device.message, 'Shown');
          expect(device.code, '7');
          expect(device.deviceId, 'cam');
        }
      }
    });
  });

  group('errors the Dart services raise', () {
    final rows = <(SkotiqException, String, String, String, bool, bool)>[
      // (error, toString, userFacingError, category, recoverable, reconnect)
      (
        const ConnectionException(
          message: 'Camera not connected',
          userMessage: 'The camera is not connected',
        ),
        'SkotiqException(connection): Camera not connected',
        'The camera is not connected',
        'connection',
        true,
        true,
      ),
      (
        ConnectionException.notFound('cam'),
        'SkotiqException(connection): Device not found: cam',
        'Device "cam" not found',
        'connection',
        false,
        false,
      ),
      (
        ConnectionException.disconnected('cam', 'cable'),
        'SkotiqException(connection): Device disconnected: cam - cable',
        '"cam" disconnected unexpectedly',
        'connection',
        true,
        true,
      ),
      (
        const DeviceBusyException(
          message: 'A sequence run owns the camera cooler',
          userMessage: 'The running sequence controls the camera cooler.',
          deviceId: 'cam',
        ),
        'SkotiqException(busy): A sequence run owns the camera cooler',
        'The running sequence controls the camera cooler.',
        'busy',
        true,
        false,
      ),
      (
        const ImagingException(
          message: 'Failed to write FITS',
          userMessage: 'The frame could not be saved',
        ),
        'SkotiqException(imaging): Failed to write FITS',
        'The frame could not be saved',
        'imaging',
        false,
        false,
      ),
      (
        ImagingException.cancelled(),
        'SkotiqException(imaging): Exposure cancelled',
        'Exposure was canceled',
        'imaging',
        false,
        false,
      ),
      (
        const IoException(message: 'Download failed', userMessage: 'No file'),
        'SkotiqException(io): Download failed',
        'No file',
        'io',
        false,
        false,
      ),
      (
        const ValidationException(
          message: 'Bad pattern',
          userMessage: 'The naming pattern is invalid',
        ),
        'SkotiqException(validation): Bad pattern',
        'The naming pattern is invalid',
        'validation',
        false,
        false,
      ),
      (
        ValidationException.outOfRange('gain', 900, 0, 600),
        'SkotiqException(validation): Parameter out of range: gain = 900 '
            '(valid: 0 to 600)',
        'gain value 900 is out of range (0 to 600)',
        'validation',
        false,
        false,
      ),
    ];
    for (final (error, rendered, shown, category, recoverable, reconnect)
        in rows) {
      test(rendered, () {
        expect(error.toString(), rendered);
        expect(userFacingError(error), shown);
        expect(error.category.toString().split('.').last, category);
        expect(error.isRecoverable, recoverable);
        expect(error.shouldReconnect, reconnect);
        expect(error.isTimeout, isFalse);
      });
    }

    test('a device card reads them by their text', () {
      final notConnected = DeviceError.fromException(
        const ConnectionException(
          message: 'Not connected to server.',
          userMessage: 'Not connected to a Skotiq Headless Server',
        ),
      );
      expect(notConnected.type, DeviceErrorType.connectionFailed);
      expect(notConnected.recoverable, isTrue);
      expect(notConnected.message, 'Not connected to a Skotiq Headless Server');

      final unavailable = DeviceError.fromException(
        const ConnectionException(
          message: 'No camera device ID available',
          userMessage: 'The camera device is not available',
        ),
      );
      expect(unavailable.type, DeviceErrorType.driverError);
      expect(unavailable.recoverable, isTrue);

      final notFound = DeviceError.fromException(
        ConnectionException.notFound('cam'),
      );
      expect(notFound.type, DeviceErrorType.deviceNotFound);
      expect(notFound.recoverable, isFalse);
    });

    test('describeError reads them through the known-failure table', () {
      final text = describeError(
        const ConnectionException(
          message: 'Device not connected',
          userMessage: 'The camera is not connected',
        ),
        domain: ErrorDomain.device,
      );
      expect(text.message, 'The camera is not connected.');
      expect(
        text.suggestion,
        'Connect to the device before performing this operation.',
      );
      expect(text.isRecoverable, isTrue);
    });
  });

  group('describeError of a typed core error', () {
    test('user message, reconnect hint, its own recoverability', () {
      final text = describeError(
        skotiqErrorFromBridge(const bridge.SkotiqError.notConnected('cam')),
        domain: ErrorDomain.device,
      );
      expect(text.message, "'cam' is not connected");
      expect(text.suggestion, 'Reconnect the device, then try again.');
      expect(text.isRecoverable, isFalse);
    });
  });

  group('cancellation is read from the message', () {
    test('both spellings, any family', () {
      expect(
        skotiqErrorFromBridge(
          const bridge.SkotiqError.cancelled(),
        ).isCancellation,
        isTrue,
      );
      expect(ImagingException.cancelled().isCancellation, isTrue);
      expect(SkotiqError.fromString('Move canceled').isCancellation, isTrue);
      expect(SkotiqError.fromString('Move failed').isCancellation, isFalse);
    });
  });

  group('bridgeErrorMessage per variant', () {
    final rows = <(bridge.SkotiqError, String?)>[
      (
        const bridge.SkotiqError.deviceNotFound('c'),
        "Device 'c' was not found",
      ),
      (
        const bridge.SkotiqError.connectionFailed(deviceId: 'c', reason: 'r'),
        'r',
      ),
      (
        const bridge.SkotiqError.alreadyConnected('c'),
        "'c' is already connected",
      ),
      (const bridge.SkotiqError.notConnected('c'), "'c' is not connected"),
      (
        const bridge.SkotiqError.deviceDisconnected(deviceId: 'c', reason: 'r'),
        'r',
      ),
      (
        const bridge.SkotiqError.hardwareError(deviceId: 'c', message: 'm'),
        'm',
      ),
      (
        const bridge.SkotiqError.communicationError(
          deviceId: 'c',
          message: 'm',
        ),
        'm',
      ),
      (const bridge.SkotiqError.timeout('m'), 'm'),
      (
        const bridge.SkotiqError.deviceTimeout(
          deviceId: 'c',
          operation: 'o',
          timeoutSecs: 2,
        ),
        null,
      ),
      (
        const bridge.SkotiqError.connectionTimeout(
          deviceId: 'c',
          timeoutSecs: 2,
        ),
        null,
      ),
      (const bridge.SkotiqError.invalidParameter('m'), 'm'),
      (const bridge.SkotiqError.invalidInput('m'), 'm'),
      (
        const bridge.SkotiqError.invalidDeviceId(deviceId: 'c', reason: 'r'),
        'r',
      ),
      (
        const bridge.SkotiqError.parameterOutOfRange(
          paramName: 'g',
          value: '1',
          min: '2',
          max: '3',
        ),
        null,
      ),
      (const bridge.SkotiqError.operationFailed('m'), 'm'),
      (
        const bridge.SkotiqError.notSupported(deviceId: 'c', operation: 'o'),
        "'c' does not support o",
      ),
      (
        const bridge.SkotiqError.deviceBusy(
          deviceId: 'c',
          currentOperation: 'o',
        ),
        "'c' is busy with o",
      ),
      (const bridge.SkotiqError.invalidState('m'), 'm'),
      (const bridge.SkotiqError.imageError('m'), 'm'),
      (const bridge.SkotiqError.cameraError('m'), 'm'),
      (const bridge.SkotiqError.noImageAvailable(), null),
      (const bridge.SkotiqError.exposureCancelled(), null),
      (
        const bridge.SkotiqError.exposureFailed(cameraId: 'c', reason: 'r'),
        'r',
      ),
      (
        const bridge.SkotiqError.downloadFailed(cameraId: 'c', reason: 'r'),
        'r',
      ),
      (const bridge.SkotiqError.ioError('m'), 'm'),
      (const bridge.SkotiqError.serializationError('m'), 'm'),
      (const bridge.SkotiqError.plateSolveError('m'), 'm'),
      (const bridge.SkotiqError.sequenceError('m'), 'm'),
      (
        const bridge.SkotiqError.ascomError(
          progId: 'p',
          message: 'm',
          errorCode: 1,
        ),
        'm',
      ),
      (
        const bridge.SkotiqError.alpacaError(
          baseUrl: 'u',
          deviceNumber: 0,
          message: 'm',
          errorCode: 1,
        ),
        'm',
      ),
      (
        const bridge.SkotiqError.indiError(
          server: 's',
          port: 1,
          deviceName: 'd',
          message: 'm',
        ),
        'm',
      ),
      (
        const bridge.SkotiqError.nativeError(
          vendor: 'v',
          message: 'm',
          errorCode: 1,
        ),
        'm',
      ),
      (const bridge.SkotiqError.comError(message: 'm', hresult: 5), 'm'),
      (const bridge.SkotiqError.internal('m'), 'm'),
      (const bridge.SkotiqError.cancelled(), null),
      (const bridge.SkotiqError.runtimeInitFailed('m'), 'm'),
      (
        const bridge.SkotiqError.resourceExhausted(resource: 'r', message: 'm'),
        'm',
      ),
      (
        const bridge.SkotiqError.refused(
          kind: bridge.Refusal.noLockPosition,
          message: 'm',
        ),
        'm',
      ),
    ];
    for (final (error, expected) in rows) {
      test('${error.runtimeType}', () {
        expect(bridgeErrorMessage(error), expected);
      });
    }
    test('every variant has a row', () {
      expect(rows.map((r) => r.$1.runtimeType).toSet(), hasLength(38));
    });
  });

  // A refusal is classified as the variant it was raised as before it had a
  // kind, whether read typed or after something turned it into text.
  group('a refusal classifies as the variant it replaced', () {
    for (final kind in bridge.Refusal.values) {
      test('$kind', () {
        const words = 'Failed to start sequence: Cannot start: busy';
        final refused = bridge.SkotiqError.refused(kind: kind, message: words);
        final before = kind == bridge.Refusal.lightLeak
            ? const bridge.SkotiqError.invalidInput(words)
            : const bridge.SkotiqError.operationFailed(words);
        // The message of an error read from text is that text itself.
        String core(SkotiqError e) =>
            '${e.category} ${e.isRecoverable} ${e.shouldReconnect} '
            '${e.isTimeout}';
        String device(DeviceError e) =>
            '${e.type} ${e.message} ${e.recoverable}';
        expect(classifyErrorText('$refused'), classifyErrorText('$before'));
        expect(
          core(SkotiqError.fromString('$refused')),
          core(SkotiqError.fromString('$before')),
        );
        expect(
          device(DeviceError.fromException(refused)),
          device(DeviceError.fromException(before)),
        );
        expect(
          device(DeviceError.fromException(Exception('$refused'))),
          device(DeviceError.fromException(Exception('$before'))),
        );
        expect(userFacingError(refused), userFacingError(before));
      });
    }
  });
}

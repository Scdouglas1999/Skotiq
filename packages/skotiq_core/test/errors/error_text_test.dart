import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('userFacingError', () {
    test('reads the authored message of Dart error types', () {
      expect(
        userFacingError(StateError('No push transport')),
        'No push transport',
      );
      expect(userFacingError(UnsupportedError('Not on Linux')), 'Not on Linux');
      expect(
        userFacingError(const FormatException('Bad header')),
        'Bad header',
      );
      expect(
        userFacingError(Exception('Camera not connected')),
        'Camera not connected',
      );
      expect(
        userFacingError(ArgumentError('Gain is out of range')),
        'Gain is out of range',
      );
    });

    test('keeps the name and value of an ArgumentError.value', () {
      expect(
        userFacingError(ArgumentError.value(7, 'bin', 'Unsupported')),
        contains('bin'),
      );
    });

    test('a timeout with no message still says what happened', () {
      expect(
        userFacingError(TimeoutException(null)),
        'The operation timed out',
      );
      expect(
        userFacingError(TimeoutException(null, const Duration(seconds: 30))),
        'No answer after 30 s',
      );
      expect(
        userFacingError(TimeoutException('Slew did not finish')),
        'Slew did not finish',
      );
    });

    test('a socket failure names the host', () {
      final text = userFacingError(
        SocketException(
          'Connection refused',
          address: InternetAddress('192.0.2.10'),
          port: 4400,
        ),
      );
      expect(text, 'Could not reach 192.0.2.10:4400 (Connection refused)');
    });

    test('typed backend errors give their user message', () {
      expect(
        userFacingError(
          const SkotiqError(
            category: BackendErrorCategory.unknown,
            message: 'tech',
            userMessage: 'The mount is parked',
          ),
        ),
        'The mount is parked',
      );
      expect(
        userFacingError(
          const ServerError(code: 'device_busy', message: 'Camera is exposing'),
        ),
        'Camera is exposing',
      );
    });

    test('a host error code before the sentence is dropped', () {
      // A refused warm-up toasted "Failed to warm up: run_owns_cooler: The
      // running sequence controls the camera cooler".
      expect(
        userFacingError(
          Exception(
            'run_owns_cooler: The running sequence controls the camera cooler.',
          ),
        ),
        'The running sequence controls the camera cooler.',
      );
    });

    test('ordinary text that starts with a word and a colon is kept', () {
      expect(
        userFacingError(Exception('Camera: not connected')),
        'Camera: not connected',
      );
    });

    test(
      'an error that crossed a boundary as text is cleaned the same way',
      () {
        expect(
          userFacingError('Exception: Invalid device: ZWO ASI2600'),
          'Invalid device: ZWO ASI2600',
        );
        expect(
          userFacingError('Exception: Bad state: Mount is parked'),
          'Mount is parked',
        );
        expect(
          userFacingError('SkotiqException(connection): Camera not connected'),
          'Camera not connected',
        );
        expect(
          userFacingError('Operation failed: Exception: slew aborted'),
          'slew aborted',
        );
        expect(
          userFacingError(
            'SkotiqError.operationFailed(field0: Filter wheel moving)',
          ),
          'Filter wheel moving',
        );
        expect(
          userFacingError(
            'SkotiqError.connectionFailed(deviceId: localhost:11111, '
            'reason: nothing is listening)',
          ),
          'nothing is listening',
        );
        expect(
          userFacingError('AnyhowException(driver said no)'),
          'driver said no',
        );
      },
    );

    test('a stack trace never reaches the screen', () {
      expect(
        userFacingError('Exception: boom\n#0      main (file.dart:3:5)\n#1 x'),
        'boom',
      );
      expect(
        userFacingError('driver failed\n\nStack backtrace:\n   0: std::rt'),
        'driver failed',
      );
    });

    test('null and empty have something to say', () {
      expect(userFacingError(null), 'Unknown error');
      expect(userFacingError(''), 'String');
    });
  });

  test('failureText puts the sentence after the action', () {
    expect(
      failureText('Could not save the profile', Exception('disk full')),
      'Could not save the profile: disk full',
    );
  });

  group('describeError', () {
    test('a known failure comes with what to do about it', () {
      final text = describeError(
        'Exception: Connection refused (os error 111)',
        domain: ErrorDomain.device,
      );
      expect(text.message, 'Could not connect to the device.');
      expect(text.suggestion, contains('no other software is using it'));
      expect(text.full, contains('\n\n'));
    });

    test('an unknown failure keeps its own words, as a sentence', () {
      final text = describeError(Exception('filter wheel jammed at slot 3'));
      expect(text.message, 'Filter wheel jammed at slot 3.');
      expect(text.suggestion, isNotNull);
    });

    test('short patterns do not match inside other words', () {
      // A bare "com" matched "command" and "completed", and a bare "limit"
      // matched "rate limit", so unrelated failures were reported as
      // "Windows COM interface error" and "Mount has reached a limit".
      expect(
        describeError('Command did not complete').message,
        'Command did not complete.',
      );
      expect(
        describeError('API rate limit hit, retry later').message,
        'API rate limit hit, retry later.',
      );
      expect(
        describeError('Recalibration is recommended').message,
        'Recalibration is recommended.',
      );
      expect(
        describeError('COM object error 0x80040154').message,
        'Windows COM interface error.',
      );
      expect(
        describeError('Slew refused: tracking limit reached').message,
        'Mount has reached a limit.',
      );
    });

    test('the asked-for domain wins when two tables match', () {
      expect(
        describeError(
          'PHD2: exposure failed',
          domain: ErrorDomain.guiding,
        ).message,
        'PHD2 guiding error.',
      );
      expect(
        describeError('PHD2: exposure failed').message,
        'The exposure failed.',
      );
    });

    test('a typed error keeps its own recoverability', () {
      final text = describeError(
        const SkotiqError(
          category: BackendErrorCategory.unknown,
          message: 'x',
          userMessage: 'Camera dropped off the bus',
          shouldReconnect: true,
        ),
      );
      expect(text.message, 'Camera dropped off the bus');
      expect(text.suggestion, contains('Reconnect'));
      expect(text.isRecoverable, isFalse);
    });
  });
}

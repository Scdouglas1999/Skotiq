import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('userFacingError', () {
    test('a database failure keeps the reason and drops the statement', () {
      final error = Exception(
        'SqliteException(1544): while executing statement, attempt to write a '
        'readonly database, attempt to write a readonly database (code 1544)\n'
        '  Causing statement: INSERT INTO "app_settings" ("key", "value") '
        'VALUES (?, ?), parameters: start_minimized, true',
      );
      expect(
        userFacingError(error),
        'database error: attempt to write a readonly database',
      );
    });

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

    test('a host that refuses the connection is named by the address asked '
        'for, without the socket dump', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();

      Object? error;
      try {
        await http.get(Uri.parse('http://127.0.0.1:$port/api/sessions'));
      } catch (e) {
        error = e;
      }

      expect(error, isA<http.ClientException>());
      expect(
        userFacingError(error),
        'Could not reach 127.0.0.1:$port (Connection refused)',
      );
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
      expect(userFacingError(''), 'Unknown error');
      expect(userFacingError(Exception('')), 'Unknown error');
    });
  });

  test('isAccessLevelRefusal recognizes the host refusing a low scope', () {
    expect(
      isAccessLevelRefusal(
        SkotiqError.fromString(
          'Access denied: Token scope is not permitted for this endpoint: '
          'this credential holds control on filesystem, and admin is '
          'required.',
        ),
      ),
      isTrue,
    );
    expect(
      isAccessLevelRefusal(
        const ServerError(
          code: 'invalid_auth_token',
          message: 'Access denied: Invalid authentication token',
          httpStatus: 403,
        ),
      ),
      isFalse,
    );
    expect(isAccessLevelRefusal(StateError('folder missing')), isFalse);
  });

  test('failureText puts the sentence after the action', () {
    expect(
      failureText('Could not save the profile', Exception('disk full')),
      'Could not save the profile: disk full',
    );
  });

  group('describeError', () {
    test('a known failure keeps its own words and says what to do', () {
      final text = describeError(
        'Exception: Connection refused (os error 111)',
        domain: ErrorDomain.device,
      );
      expect(text.message, 'Connection refused (os error 111).');
      expect(text.suggestion, contains('no other software is using it'));
      expect(text.full, contains('\n\n'));
    });

    test('the table never replaces what happened with a vaguer sentence', () {
      // The ASCOM row said "ASCOM driver error occurred." for every message
      // that mentioned ASCOM, including "ASCOM is only available on Windows".
      final text = describeError(
        'Exception: ASCOM is only available on Windows',
        domain: ErrorDomain.device,
      );
      expect(text.message, 'ASCOM is only available on Windows.');
      expect(text.suggestion, contains('ASCOM driver'));
    });

    test('an unknown failure points at the log', () {
      final text = describeError(Exception('filter wheel jammed at slot 3'));
      expect(text.message, 'Filter wheel jammed at slot 3.');
      expect(text.suggestion, contains('Settings > Logs'));
    });

    test('short patterns do not match inside other words', () {
      // A bare "com" matched "command" and a bare "limit" matched "rate
      // limit", so unrelated failures got COM and mount-limit advice.
      const generic = 'Settings > Logs';
      expect(
        describeError('Command did not complete').suggestion,
        contains(generic),
      );
      expect(
        describeError('API rate limit hit, retry later').suggestion,
        contains(generic),
      );
      expect(
        describeError('Recalibration is recommended').suggestion,
        contains(generic),
      );
      expect(
        describeError('COM object error 0x80040154').suggestion,
        contains('restarting the application'),
      );
      expect(
        describeError('Slew refused: tracking limit reached').suggestion,
        contains('meridian flip'),
      );
    });

    test('the asked-for domain wins when two rows match', () {
      expect(
        describeError(
          'PHD2: exposure failed',
          domain: ErrorDomain.guiding,
        ).suggestion,
        contains('PHD2 connection'),
      );
      expect(
        describeError('PHD2: exposure failed').suggestion,
        contains('camera connection'),
      );
    });

    test('a target below the horizon is not worth retrying', () {
      expect(describeError('Target below horizon').isRecoverable, isFalse);
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

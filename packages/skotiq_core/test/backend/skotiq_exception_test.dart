import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/skotiq_exception.dart';

/// Build a Rust-side `ErrorInfo` JSON envelope.
///
/// Field shape mirrors `native/skotiq_native/bridge/src/error.rs` lines
/// 725-758 (`ErrorInfo` serde-derived struct) — snake_case keys, optional
/// `device_id` and `error_code`.
String _rustErrorJson({
  required String category,
  required String message,
  required String userMessage,
  bool isRecoverable = false,
  bool shouldReconnect = false,
  bool isTimeout = false,
  String? deviceId,
  int? errorCode,
}) {
  return jsonEncode({
    'category': category,
    'message': message,
    'user_message': userMessage,
    'is_recoverable': isRecoverable,
    'should_reconnect': shouldReconnect,
    'is_timeout': isTimeout,
    'device_id': deviceId,
    'error_code': errorCode,
  });
}

void main() {
  group('SkotiqException.fromError — structured JSON round-trip', () {
    test('connection category maps to ConnectionException with all fields', () {
      final payload = _rustErrorJson(
        category: 'connection',
        message: 'Device disconnected: ZWO ASI2600MC',
        userMessage: '"ZWO ASI2600MC" disconnected unexpectedly',
        isRecoverable: true,
        shouldReconnect: true,
        deviceId: 'native:zwo:0',
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<ConnectionException>());
      expect(ex.category, 'connection');
      expect(ex.message, 'Device disconnected: ZWO ASI2600MC');
      expect(ex.userMessage, '"ZWO ASI2600MC" disconnected unexpectedly');
      expect(ex.isRecoverable, true);
      expect(ex.shouldReconnect, true);
      expect(ex.deviceId, 'native:zwo:0');
    });

    test('hardware category preserves device_id and error_code', () {
      final payload = _rustErrorJson(
        category: 'hardware',
        message: 'Camera communication error',
        userMessage: 'Camera failed to respond',
        isRecoverable: true,
        deviceId: 'ascom:ZWO.Camera',
        errorCode: -2147024891,
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<HardwareException>());
      expect(ex.category, 'hardware');
      expect(ex.deviceId, 'ascom:ZWO.Camera');
      expect(ex.errorCode, -2147024891);
      expect(ex.isRecoverable, true);
    });

    test('timeout category sets isTimeout flag', () {
      final payload = _rustErrorJson(
        category: 'timeout',
        message: 'Device timeout: mount operation "slew"',
        userMessage: 'Operation "slew" timed out',
        isRecoverable: true,
        isTimeout: true,
        deviceId: 'indi:localhost:7624:SkyWatcher Mount',
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<TimeoutException>());
      expect(ex.category, 'timeout');
      expect(ex.isTimeout, true);
      expect(ex.isRecoverable, true);
      expect(ex.shouldReconnect, false);
      expect(ex.deviceId, 'indi:localhost:7624:SkyWatcher Mount');
    });

    test('validation category produces ValidationException', () {
      final payload = _rustErrorJson(
        category: 'validation',
        message:
            'Parameter out of range: exposure_seconds = 7200 (valid: 0 to 3600)',
        userMessage: 'exposure_seconds value 7200 is out of range (0 to 3600)',
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<ValidationException>());
      expect(ex.category, 'validation');
      expect(ex.message, contains('exposure_seconds'));
      expect(ex.isRecoverable, false);
    });

    test('unsupported category produces UnsupportedOperationException', () {
      final payload = _rustErrorJson(
        category: 'unsupported',
        message: 'Operation not supported: pulse guiding on ASCOM mount',
        userMessage: 'Pulse guiding is not supported by this mount',
        deviceId: 'ascom:CelestronCGEM',
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<UnsupportedOperationException>());
      expect(ex.category, 'unsupported');
      expect(ex.deviceId, 'ascom:CelestronCGEM');
    });

    test('busy category produces DeviceBusyException', () {
      final payload = _rustErrorJson(
        category: 'busy',
        message: 'Device busy: focuser is moving',
        userMessage: 'Focuser is currently busy',
        isRecoverable: true,
        deviceId: 'native:focuser:0',
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<DeviceBusyException>());
      expect(ex.category, 'busy');
      expect(ex.deviceId, 'native:focuser:0');
      expect(ex.isRecoverable, true);
    });

    test('imaging category produces ImagingException', () {
      final payload = _rustErrorJson(
        category: 'imaging',
        message: 'Exposure failed: sensor read error',
        userMessage: 'Exposure failed due to sensor error',
        deviceId: 'native:zwo:0',
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<ImagingException>());
      expect(ex.category, 'imaging');
      expect(ex.deviceId, 'native:zwo:0');
    });

    test('io category produces IoException', () {
      final payload = _rustErrorJson(
        category: 'io',
        message: 'Plate solve error: ASTAP not found',
        userMessage: 'Plate solving failed',
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<IoException>());
      expect(ex.category, 'io');
      expect(ex.message, 'Plate solve error: ASTAP not found');
    });

    test('sequence category produces SequenceException', () {
      final payload = _rustErrorJson(
        category: 'sequence',
        message: 'Sequence aborted at node guide_check',
        userMessage: 'Sequence stopped due to guiding loss',
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<SequenceException>());
      expect(ex.category, 'sequence');
    });

    test('driver category preserves error_code and device_id', () {
      final payload = _rustErrorJson(
        category: 'driver',
        message: 'ASCOM error: 0x80040407',
        userMessage: 'Camera driver reported an error',
        deviceId: 'ascom:ZWO.Camera',
        errorCode: 1031,
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<DriverException>());
      expect(ex.category, 'driver');
      expect(ex.errorCode, 1031);
      expect(ex.deviceId, 'ascom:ZWO.Camera');
    });

    test('system category falls back to base SkotiqException', () {
      final payload = _rustErrorJson(
        category: 'system',
        message: 'Internal error: tokio runtime panicked',
        userMessage: 'An internal error occurred',
      );

      final ex = SkotiqException.fromError(payload);

      // The system category isn't switched on, so it should return the base
      // SkotiqException constructed in the default arm.
      expect(ex.category, 'system');
      expect(ex.message, 'Internal error: tokio runtime panicked');
      expect(ex.userMessage, 'An internal error occurred');
      expect(ex.runtimeType, SkotiqException);
    });

    test('null device_id and error_code decode as null', () {
      final payload = _rustErrorJson(
        category: 'connection',
        message: 'Discovery scan failed',
        userMessage: 'Could not discover devices',
        isRecoverable: true,
      );

      final ex = SkotiqException.fromError(payload);

      expect(ex, isA<ConnectionException>());
      expect(ex.deviceId, isNull);
      expect(ex.errorCode, isNull);
    });

    test('all 11 Rust categories round-trip without losing the category', () {
      // The full set listed in error.rs::error_category() at lines 600-649.
      const categories = <String>[
        'connection',
        'hardware',
        'timeout',
        'validation',
        'unsupported',
        'busy',
        'imaging',
        'io',
        'sequence',
        'driver',
        'system',
      ];

      for (final cat in categories) {
        final payload = _rustErrorJson(
          category: cat,
          message: '$cat-message',
          userMessage: '$cat-user',
        );
        final ex = SkotiqException.fromError(payload);
        expect(
          ex.category,
          cat,
          reason: 'category $cat should round-trip via fromError',
        );
        expect(
          ex.message,
          '$cat-message',
          reason: 'message for $cat should survive fromError',
        );
        expect(
          ex.userMessage,
          '$cat-user',
          reason: 'user_message for $cat should survive fromError',
        );
      }
    });
  });

  group('SkotiqException.fromError — heuristic fallback (R9)', () {
    test('non-JSON timeout message is classified as TimeoutException', () {
      final ex = SkotiqException.fromError('Operation timed out');
      expect(ex, isA<TimeoutException>());
      expect(ex.category, 'timeout');
      expect(ex.isTimeout, true);
    });

    test(
      'non-JSON connection message is classified as ConnectionException',
      () {
        final ex = SkotiqException.fromError(
          'Device disconnected unexpectedly',
        );
        expect(ex, isA<ConnectionException>());
        expect(ex.category, 'connection');
      },
    );

    test(
      'non-JSON validation message is classified as ValidationException',
      () {
        final ex = SkotiqException.fromError('Invalid parameter: foo');
        expect(ex, isA<ValidationException>());
        expect(ex.category, 'validation');
      },
    );

    test('non-JSON unsupported message is classified correctly', () {
      final ex = SkotiqException.fromError('Operation not supported');
      expect(ex, isA<UnsupportedOperationException>());
      expect(ex.category, 'unsupported');
    });

    test('non-JSON imaging message is classified as ImagingException', () {
      final ex = SkotiqException.fromError('Camera exposure failed');
      expect(ex, isA<ImagingException>());
      expect(ex.category, 'imaging');
    });

    test('generic non-JSON message falls back to system category', () {
      final ex = SkotiqException.fromError('Something went wrong');
      expect(ex.category, 'system');
      expect(ex.message, 'Something went wrong');
    });

    test('long generic message is truncated in userMessage', () {
      final long = 'A' * 250;
      final ex = SkotiqException.fromError(long);
      expect(ex.message, long);
      expect(ex.userMessage.length, lessThanOrEqualTo(103));
      expect(ex.userMessage, endsWith('...'));
    });
  });

  group('SkotiqException.fromError — malformed JSON fail-safe', () {
    test('JSON-looking string with truncation falls back to heuristic', () {
      // Why: malformed envelope must surface (via developer.log) and then
      // route through the heuristic classifier per R9.
      const malformed = '{"category":"connection","message":"timed out"';
      final ex = SkotiqException.fromError(malformed);
      // The string contains "timed out" so heuristic picks TimeoutException.
      expect(ex, isA<TimeoutException>());
    });

    test('JSON-looking garbage falls back to system category', () {
      final ex = SkotiqException.fromError('{not json at all}');
      // No heuristic keyword matches → system fallback.
      expect(ex.category, 'system');
    });

    test('JSON array (not object) is not treated as structured envelope', () {
      // jsonDecode succeeds but result isn't a Map → returns null → heuristic.
      final ex = SkotiqException.fromError('[1, 2, 3]');
      expect(ex.category, 'system');
    });

    test('leading whitespace before { is still detected', () {
      final payload =
          '  ${_rustErrorJson(category: 'hardware', message: 'sensor failure', userMessage: 'Sensor failed')}';
      final ex = SkotiqException.fromError(payload);
      expect(ex, isA<HardwareException>());
      expect(ex.category, 'hardware');
    });
  });

  group('SkotiqException.fromJson — direct payload decoding', () {
    test('unknown category falls back to base SkotiqException', () {
      final ex = SkotiqException.fromJson(<String, dynamic>{
        'category': 'something_new',
        'message': 'msg',
        'user_message': 'um',
        'is_recoverable': true,
        'should_reconnect': false,
        'is_timeout': false,
      });

      expect(ex.runtimeType, SkotiqException);
      expect(ex.category, 'something_new');
      expect(ex.isRecoverable, true);
    });

    test('missing category defaults to system', () {
      final ex = SkotiqException.fromJson(<String, dynamic>{
        'message': 'no category',
        'user_message': 'no category',
      });
      expect(ex.category, 'system');
    });
  });
}

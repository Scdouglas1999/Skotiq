// Characterization tests for [ServerError.tryFromJson], the single converged
// parser for the headless error envelope.
//
// The headless server emits several error shapes. This parser accepts ALL of
// them — the canonical {code, message}, the unified {error, code, message}
// transition envelope, and the legacy prose-only {error} bodies.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('ServerError.tryFromJson', () {
    test('parses the prior canonical {code, message} shape unchanged', () {
      final err = ServerError.tryFromJson({
        'code': 'pairing_required',
        'message': 'No paired token presented',
      }, httpStatus: 401);

      expect(err, isNotNull);
      expect(err!.code, 'pairing_required');
      expect(err.message, 'No paired token presented');
      expect(err.httpStatus, 401);
    });

    test('preserves a nested details map on the canonical shape', () {
      final err = ServerError.tryFromJson({
        'code': 'pairing_required',
        'message': 'No paired token presented',
        'details': {'deviceId': 'ascom:camera:foo'},
      });

      expect(err, isNotNull);
      expect(err!.details, {'deviceId': 'ascom:camera:foo'});
    });

    test('parses the unified {error, code, message} transition envelope to '
        'the same code/message, with the machine code winning', () {
      // The shape `jsonError` emits: `error` mirrors `message` for legacy
      // display clients while `code` carries the machine code.
      final err = ServerError.tryFromJson({
        'error': 'Region 42 not found',
        'code': 'region_not_found',
        'message': 'Region 42 not found',
      }, httpStatus: 404);

      expect(err, isNotNull);
      // The machine `code` must win over the legacy prose `error` field.
      expect(err!.code, 'region_not_found');
      expect(err.message, 'Region 42 not found');
      expect(err.httpStatus, 404);
    });

    test('parses the legacy prose-only {error} shape — treating error as the '
        'message and synthesizing a non-empty code from the status', () {
      // The bare prose `{error: ...}` shape, with no code field to read.
      final err = ServerError.tryFromJson({
        'error': 'region 7 not found',
      }, httpStatus: 404);

      expect(err, isNotNull);
      expect(err!.message, 'region 7 not found');
      // Synthesized, but still a real, non-empty, branchable machine code.
      expect(err.code, isNotEmpty);
      expect(err.code, 'not_found');
    });

    test('synthesizes status-specific codes for common legacy statuses', () {
      String codeFor(int status) =>
          ServerError.tryFromJson({'error': 'x'}, httpStatus: status)!.code;

      expect(codeFor(400), 'bad_request');
      expect(codeFor(401), 'unauthorized');
      expect(codeFor(403), 'forbidden');
      expect(codeFor(409), 'conflict');
      expect(codeFor(429), 'rate_limited');
      expect(codeFor(500), 'internal_error');
      expect(codeFor(503), 'service_unavailable');
    });

    test('falls back to a generic non-empty code when no status is available '
        '(e.g. a WebSocket error frame)', () {
      final err = ServerError.tryFromJson({'error': 'something broke'});

      expect(err, isNotNull);
      expect(err!.code, isNotEmpty);
      expect(err.code, 'error');
      expect(err.httpStatus, isNull);
    });

    test('keeps an explicit code even when the message comes from the legacy '
        'error field', () {
      final err = ServerError.tryFromJson({
        'error': 'device is busy',
        'code': 'device_busy',
      }, httpStatus: 409);

      expect(err, isNotNull);
      expect(err!.code, 'device_busy');
      expect(err.message, 'device is busy');
    });

    test('returns null when neither message nor error is present so the '
        'caller can fall through to a status-based parser', () {
      expect(ServerError.tryFromJson(const {}), isNull);
      expect(ServerError.tryFromJson({'code': 'orphan_code'}), isNull);
      expect(ServerError.tryFromJson({'unrelated': 'value'}), isNull);
    });

    test('treats empty-string message/error as absent (returns null)', () {
      expect(ServerError.tryFromJson({'message': '', 'error': ''}), isNull);
    });
  });
}

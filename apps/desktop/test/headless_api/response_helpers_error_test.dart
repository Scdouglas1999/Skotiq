// Tests for the unified [jsonError] envelope helper and that its output
// decodes via the single converged client parser [ServerError.tryFromJson].

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/response_helpers.dart';

void main() {
  group('jsonError', () {
    test('emits both the legacy prose `error` and the machine `code`, with '
        'message under the canonical key and the status preserved', () async {
      final response = jsonError(
        code: 'region_not_found',
        message: 'region 42 not found',
        statusCode: 404,
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect(response.headers['content-type'], 'application/json');

      final body = jsonDecode(await response.readAsString()) as Map;
      // Legacy display clients keep a human-readable string under `error`.
      expect(body['error'], 'region 42 not found');
      // New clients get a machine-readable code.
      expect(body['code'], 'region_not_found');
      // Canonical human message under `message`.
      expect(body['message'], 'region 42 not found');
    });

    test('defaults to HTTP 500 when no status is supplied', () async {
      final response = jsonError(code: 'boom', message: 'kaboom');
      expect(response.statusCode, HttpStatus.internalServerError);
    });

    test('spreads details inline but never lets them clobber the canonical '
        'error/code/message keys', () async {
      final response = jsonError(
        code: 'cutout_failed',
        message: 'cutout failed',
        statusCode: 500,
        details: {
          'regionId': 7,
          // A malicious/sloppy detail key must not override the machine code
          // or the human message.
          'code': 'attacker_supplied',
          'error': 'attacker_supplied',
        },
      );

      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['regionId'], 7);
      expect(body['code'], 'cutout_failed');
      expect(body['error'], 'cutout failed');
      expect(body['message'], 'cutout failed');
    });

    test('its body decodes via the single converged parser with a non-empty '
        'machine code', () async {
      final response = jsonError(
        code: 'rate_limited',
        message: 'too many requests',
        statusCode: 429,
      );
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      final parsed = ServerError.tryFromJson(body, httpStatus: 429);
      expect(parsed, isNotNull);
      expect(parsed!.code, 'rate_limited');
      expect(parsed.code, isNotEmpty);
      expect(parsed.message, 'too many requests');
      expect(parsed.httpStatus, 429);
    });
  });
}

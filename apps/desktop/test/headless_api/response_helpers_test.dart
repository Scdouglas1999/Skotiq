import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/response_helpers.dart';

void main() {
  group('headless response helpers', () {
    test('jsonOk encodes JSON and applies content type', () async {
      final response = jsonOk({'ready': true});

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], jsonContentType);
      expect(jsonDecode(await response.readAsString()), {'ready': true});
    });

    test('jsonOk maps non-finite numbers to null', () async {
      final response = jsonOk({
        'finite': 1.5,
        'infinite': double.infinity,
        'notANumber': double.nan,
      });

      expect(jsonDecode(await response.readAsString()), {
        'finite': 1.5,
        'infinite': null,
        'notANumber': null,
      });
    });

    test('error helpers preserve caller headers', () async {
      final response = jsonRateLimited(
        {'error': 'rate_limited'},
        headers: const {'x-request-id': 'request-1'},
      );

      expect(response.statusCode, 429);
      expect(response.headers['content-type'], jsonContentType);
      expect(response.headers['x-request-id'], 'request-1');
      expect(jsonDecode(await response.readAsString()), {
        'error': 'rate_limited',
      });
    });

    test('jsonNotImplemented encodes 501 JSON', () async {
      final response = jsonNotImplemented({'error': 'unsupported'});

      expect(response.statusCode, 501);
      expect(response.headers['content-type'], jsonContentType);
      expect(jsonDecode(await response.readAsString()), {
        'error': 'unsupported',
      });
    });

    test('attachmentResponse applies safe disposition and length', () async {
      final response = attachmentResponse(
        'body',
        fileName: '../unsafe report.json',
        contentType: jsonContentType,
        contentLength: 4,
      );

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], jsonContentType);
      expect(response.headers['content-length'], '4');
      expect(
        response.headers['content-disposition'],
        'attachment; filename="unsafe_report.json"',
      );
      expect(await response.readAsString(), 'body');
    });

    test('contentResponse applies content type and length', () async {
      final response = contentResponse(
        [1, 2, 3],
        contentType: 'application/octet-stream',
        contentLength: 3,
      );

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'application/octet-stream');
      expect(response.headers['content-length'], '3');
      expect(
        await response.read().fold<int>(0, (sum, chunk) => sum + chunk.length),
        3,
      );
    });

    test('streamResponse preserves streaming context', () {
      final response = streamResponse(
        const Stream<List<int>>.empty(),
        contentType: 'text/event-stream; charset=utf-8',
        contentLength: 12,
        headers: const {'cache-control': 'no-cache'},
        context: const {'shelf.io.buffer_output': false},
      );

      expect(response.statusCode, 200);
      expect(
        response.headers['content-type'],
        'text/event-stream; charset=utf-8',
      );
      expect(response.headers['cache-control'], 'no-cache');
      expect(response.headers['content-length'], '12');
      expect(response.context['shelf.io.buffer_output'], false);
    });

    test('noContentResponse returns 204 without a body', () async {
      final response = noContentResponse();

      expect(response.statusCode, 204);
      expect(await response.readAsString(), isEmpty);
    });

    test('attachment filenames strip unsafe path and control characters', () {
      expect(
        attachmentDisposition('../bad/name \u0000".zip'),
        'attachment; filename="name___.zip"',
      );
    });
  });
}

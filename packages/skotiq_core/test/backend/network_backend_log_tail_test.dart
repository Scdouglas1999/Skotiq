// Log tail: Tests for NetworkBackend.fetchRecentServerLogs +
// clearServerLogs against the FakeNetworkClient (`MockClient`).
//
// Why: the SSE tail loop opens a real `dart:io` HttpClient (not
// `package:http`), so it can't be exercised through the existing
// FakeNetworkClient. The two HTTP-only methods CAN, and they're the
// surface the log tab calls on every screen build, so they get pinned
// down here. The SSE path is covered separately by an in-process
// HttpServer test (see network_backend_log_tail_sse_test.dart).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/services/logging_service.dart';

import '../fakes/fakes.dart';

/// Case-insensitive header lookup. Both the `package:http` request layer
/// and the dart:io HttpClient normalise header keys to lowercase, but the
/// production code calls `Map.set('Authorization', ...)` — so a literal
/// `headers['Authorization']` lookup misses the lowercase form. Mirror
/// the helper in `network_backend_test.dart`.
String? _headerValue(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) {
      return entry.value;
    }
  }
  return null;
}

NetworkBackend _buildBackend(FakeNetworkClient fake) {
  return NetworkBackend(
    serverHost: '127.0.0.1',
    serverPort: 9999,
    webSocketPort: 9999,
    authToken: 'test-token',
    httpClient: fake,
    autoConnectWebSocket: false,
  );
}

void main() {
  group('NetworkBackend log tail HTTP surface', () {
    late FakeNetworkClient fake;
    late NetworkBackend backend;

    setUp(() {
      fake = FakeNetworkClient();
    });

    tearDown(() {
      backend.dispose();
    });

    test(
      'fetchRecentServerLogs decodes the /api/logs/recent envelope',
      () async {
        final now = DateTime.now().toUtc();
        final earlier = now.subtract(const Duration(seconds: 5));
        fake.setResponse(
          '/api/logs/recent',
          method: 'GET',
          body: jsonEncode({
            'entries': [
              {
                'timestamp': earlier.toIso8601String(),
                'severity': 'info',
                'source': 'TestSrc',
                'message': 'first entry',
              },
              {
                'timestamp': now.toIso8601String(),
                'severity': 'warning',
                'source': 'TestSrc',
                'message': 'second entry',
                'fields': {'k': 'v'},
              },
            ],
            'count': 2,
            'totalBuffered': 17,
          }),
        );
        backend = _buildBackend(fake);

        final entries = await backend.fetchRecentServerLogs(limit: 50);
        expect(entries, hasLength(2));
        expect(entries.first.message, 'first entry');
        expect(entries.first.level, LogLevel.info);
        expect(entries.last.level, LogLevel.warning);
        expect(entries.last.fields['k'], 'v');

        final req = fake.requestsFor('/api/logs/recent').single;
        expect(req.method, 'GET');
        expect(req.url.queryParameters['limit'], '50');
        expect(_headerValue(req.headers, 'Authorization'), 'Bearer test-token');
      },
    );

    test(
      'fetchRecentServerLogs passes severityMin + categoryFilter through',
      () async {
        fake.setResponse(
          '/api/logs/recent',
          method: 'GET',
          body: jsonEncode({'entries': [], 'count': 0, 'totalBuffered': 0}),
        );
        backend = _buildBackend(fake);

        await backend.fetchRecentServerLogs(
          limit: 25,
          severityMin: 'warning',
          categoryFilter: 'DeviceService',
        );
        final req = fake.requestsFor('/api/logs/recent').single;
        expect(req.url.queryParameters['minSeverity'], 'warning');
        expect(req.url.queryParameters['source'], 'DeviceService');
      },
    );

    test(
      'fetchRecentServerLogs surfaces malformed bodies as an error',
      () async {
        fake.setResponse(
          '/api/logs/recent',
          method: 'GET',
          // Server promised `entries:[...]`, returned a string — that is a
          // wire-protocol bug we want to surface loudly, not silently
          // smooth over.
          body: '{"entries": "not a list"}',
        );
        backend = _buildBackend(fake);

        expect(backend.fetchRecentServerLogs(), throwsA(isA<Object>()));
      },
    );

    test('fetchRecentServerLogs skips per-entry FormatExceptions', () async {
      final ts = DateTime.now().toUtc().toIso8601String();
      fake.setResponse(
        '/api/logs/recent',
        method: 'GET',
        body: jsonEncode({
          'entries': [
            {'timestamp': ts, 'severity': 'info', 'message': 'good'},
            {'severity': 'info', 'message': 'no timestamp'}, // malformed
            {'timestamp': ts, 'severity': 'info', 'message': 'also good'},
          ],
          'count': 3,
          'totalBuffered': 3,
        }),
      );
      backend = _buildBackend(fake);

      final entries = await backend.fetchRecentServerLogs();
      // The malformed middle entry is dropped; the good ones come through.
      expect(entries.map((e) => e.message), ['good', 'also good']);
    });

    test('listServerLogFiles decodes the /api/logs envelope', () async {
      fake.setResponse(
        '/api/logs',
        method: 'GET',
        body: jsonEncode({
          'files': [
            {
              'name': 'skotiq.log',
              'sizeBytes': 2048,
              'modifiedAt': '2026-07-20T04:00:00Z',
              'isCurrent': true,
            },
            {
              'name': 'skotiq.log.2026-07-19',
              'sizeBytes': 1024,
              'modifiedAt': 'not-a-date', // tolerated → null modifiedAt
              'isCurrent': false,
            },
          ],
          'totalBytes': 3072,
          'retentionDays': 0,
        }),
      );
      backend = _buildBackend(fake);

      final files = await backend.listServerLogFiles();
      expect(files, hasLength(2));
      expect(files.first.name, 'skotiq.log');
      expect(files.first.sizeBytes, 2048);
      expect(files.first.isCurrent, isTrue);
      expect(files.first.modifiedAt, isNotNull);
      expect(files.last.modifiedAt, isNull);
      expect(files.last.isCurrent, isFalse);

      final req = fake.requestsFor('/api/logs').single;
      expect(req.method, 'GET');
      expect(_headerValue(req.headers, 'Authorization'), 'Bearer test-token');
    });

    test('listServerLogFiles surfaces malformed bodies as an error', () async {
      fake.setResponse(
        '/api/logs',
        method: 'GET',
        body: '{"files": "not a list"}',
      );
      backend = _buildBackend(fake);

      expect(backend.listServerLogFiles(), throwsA(isA<Object>()));
    });

    test('clearServerLogs POSTs /api/logs/clear', () async {
      fake.setResponse(
        '/api/logs/clear',
        method: 'POST',
        body: jsonEncode({'deleted': 3, 'errors': <String>[]}),
      );
      backend = _buildBackend(fake);

      await backend.clearServerLogs();

      final req = fake.requestsFor('/api/logs/clear').single;
      expect(req.method, 'POST');
      expect(_headerValue(req.headers, 'Authorization'), 'Bearer test-token');
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/services/weather/transient_http_retry.dart';

void main() {
  final uri = Uri.parse('https://api.open-meteo.com/v1/forecast?x=1');
  Duration zeroBackoff(int attempt) => Duration.zero;

  test('returns immediately on 200 without retrying', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('ok', 200);
    });

    final response = await getWithTransientRetry(
      client,
      uri,
      backoff: zeroBackoff,
    );
    expect(response.statusCode, 200);
    expect(calls, 1);
  });

  test('retries a 502 and returns the eventual success', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return calls < 3
          ? http.Response('bad gateway', 502)
          : http.Response('ok', 200);
    });

    final response = await getWithTransientRetry(
      client,
      uri,
      backoff: zeroBackoff,
    );
    expect(response.statusCode, 200);
    expect(calls, 3);
  });

  test('returns the final 5xx instead of throwing so callers keep their '
      'status handling', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('nope', 502);
    });

    final response = await getWithTransientRetry(
      client,
      uri,
      backoff: zeroBackoff,
    );
    expect(response.statusCode, 502);
    expect(calls, 3);
  });

  test('does not retry a 4xx — client errors are not transient', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('not found', 404);
    });

    final response = await getWithTransientRetry(
      client,
      uri,
      backoff: zeroBackoff,
    );
    expect(response.statusCode, 404);
    expect(calls, 1);
  });

  test('retries dropped-TLS handshakes and succeeds', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      if (calls < 2) {
        throw const HandshakeException('unexpected eof while reading');
      }
      return http.Response('ok', 200);
    });

    final response = await getWithTransientRetry(
      client,
      uri,
      backoff: zeroBackoff,
    );
    expect(response.statusCode, 200);
    expect(calls, 2);
  });

  test(
    'forwards headers on each attempt (e.g. MET Norway User-Agent)',
    () async {
      final seen = <String?>[];
      final client = MockClient((request) async {
        seen.add(request.headers['user-agent']);
        // Fail the first attempt with a 502 so we can assert the header rides
        // along on the retry too.
        return seen.length < 2
            ? http.Response('bad gateway', 502)
            : http.Response('ok', 200);
      });

      final response = await getWithTransientRetry(
        client,
        uri,
        backoff: zeroBackoff,
        headers: const {'User-Agent': 'Skotiq/4.0'},
      );
      expect(response.statusCode, 200);
      expect(seen, ['Skotiq/4.0', 'Skotiq/4.0']);
    },
  );

  test('rethrows when every attempt fails at the network level', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      throw const SocketException('connection refused');
    });

    await expectLater(
      getWithTransientRetry(client, uri, backoff: zeroBackoff),
      throwsA(isA<SocketException>()),
    );
    expect(calls, 3);
  });
}

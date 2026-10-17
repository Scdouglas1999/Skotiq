import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('job polling never overlaps slow snapshot requests', () async {
    var calls = 0;
    var inFlight = 0;
    var maxInFlight = 0;
    final client = MockClient((request) async {
      expect(request.url.path, '/api/jobs/job-1');
      calls++;
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      if (calls > 1) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      inFlight--;
      return http.Response(
        jsonEncode({
          'jobId': 'job-1',
          'operation': 'plateSolve',
          'state': calls >= 3 ? 'succeeded' : 'running',
          if (calls >= 3) 'result': <String, Object?>{},
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final backend = NetworkBackend(
      serverHost: 'example.invalid',
      httpClient: client,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    final result = await backend.awaitJobCompletion(
      'job-1',
      pollInterval: const Duration(milliseconds: 5),
      timeout: const Duration(seconds: 1),
    );

    expect(result.state, 'succeeded');
    expect(calls, 3);
    expect(maxInFlight, 1);
  });
}

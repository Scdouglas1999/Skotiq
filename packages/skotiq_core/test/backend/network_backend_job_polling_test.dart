import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/src/backend/skotiq_exception.dart'
    show IoException;

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

  // A linked client's plate solve that found nothing is a result with a
  // reason, on a host that ends the job `failed` and on one from before that
  // ended it `succeeded` with `success: false`.
  NetworkBackend plateSolveBackend(Map<String, Object?> finishedJob) {
    final client = MockClient((request) async {
      final body = request.url.path == '/api/plate-solve'
          ? {'jobId': 'job-9', 'status': 'queued', 'operation': 'plate-solve'}
          : {'jobId': 'job-9', 'operation': 'plate-solve', ...finishedJob};
      return http.Response(
        jsonEncode(body),
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
    return backend;
  }

  const unsolved = <String, Object?>{
    'success': false,
    'ra': 0,
    'dec': 0,
    'pixelScale': 0,
    'rotation': 0,
    'fieldWidth': 0,
    'fieldHeight': 0,
    'solveTimeSecs': 12.5,
    'error': 'Not enough stars detected',
  };

  test('a failed plate-solve job is an unsolved result with the solver '
      'reason', () async {
    final backend = plateSolveBackend({
      'state': 'failed',
      'error': {
        'code': 'plate_solve_failed',
        'message': 'Not enough stars detected',
        'details': unsolved,
      },
    });

    final result = await backend.plateSolve(imagePath: '/data/frame.fits');

    expect(result.success, isFalse);
    expect(result.error, 'Not enough stars detected');
    expect(result.solveTimeSecs, 12.5);
  });

  test('an older host that ends an unsolved job succeeded reads the '
      'same', () async {
    final backend = plateSolveBackend({'state': 'succeeded', 'result': unsolved});

    final result = await backend.plateSolve(imagePath: '/data/frame.fits');

    expect(result.success, isFalse);
    expect(result.error, 'Not enough stars detected');
  });

  test('a plate-solve job that broke is still an error', () async {
    final backend = plateSolveBackend({
      'state': 'failed',
      'error': {'code': 'job_failed', 'message': 'solver crashed'},
    });

    await expectLater(
      backend.plateSolve(imagePath: '/data/frame.fits'),
      throwsA(isA<IoException>()),
    );
  });
}

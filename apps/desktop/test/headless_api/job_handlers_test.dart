import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/job_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

Future<void> _pumpUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('pumpUntil predicate did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  group('JobHandlers', () {
    late JobManager manager;
    late JobHandlers handlers;

    setUp(() {
      manager = JobManager(emitEvent: (_) {});
      handlers = JobHandlers(jobManager: manager);
    });

    tearDown(() async {
      await manager.dispose();
    });

    test('GET /api/jobs/{jobId} returns the snapshot', () async {
      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) async => {'ok': true},
      );
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );

      final response = await translateHandlerErrors(
        handlers.handleGetJob(
          Request('GET', Uri.parse('http://localhost/api/jobs/${job.jobId}')),
          job.jobId,
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['jobId'], job.jobId);
      expect(body['state'], 'succeeded');
      expect(body['result'], {'ok': true});
    });

    test('GET /api/jobs/{jobId} 404 on unknown id', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetJob(
          Request('GET', Uri.parse('http://localhost/api/jobs/unknown')),
          'unknown',
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'job_not_found');
    });

    test('GET /api/jobs lists jobs and supports state filter', () async {
      final completer = Completer<Map<String, Object?>>();
      final running = manager.start(
        operation: 'op.a',
        work: (sink, cancellation) => completer.future,
      );
      manager.start(
        operation: 'op.b',
        work: (sink, cancellation) async => {'ok': true},
      );
      await _pumpUntil(
        () => manager.list(state: JobState.succeeded).isNotEmpty,
      );
      await _pumpUntil(() => manager.list(state: JobState.running).isNotEmpty);

      final response = await translateHandlerErrors(
        handlers.handleListJobs(
          Request('GET', Uri.parse('http://localhost/api/jobs?state=running')),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['total'], 1);
      final jobs = (body['jobs'] as List).cast<Map>();
      expect(jobs.single['jobId'], running.jobId);

      completer.complete({'late': true});
      await _pumpUntil(
        () => manager.get(running.jobId)?.state == JobState.succeeded,
      );
    });

    test('GET /api/jobs rejects invalid state with 400', () async {
      final response = await translateHandlerErrors(
        handlers.handleListJobs(
          Request('GET', Uri.parse('http://localhost/api/jobs?state=invalid')),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'invalid_state');
    });

    test(
      'POST /api/jobs/{id}/cancel succeeds then GET shows cancelled',
      () async {
        final job = manager.start(
          operation: 'test.op',
          work: (sink, cancellation) async {
            await cancellation.whenCancelled;
            throw const JobCancelledException('test');
          },
        );
        await _pumpUntil(
          () => manager.get(job.jobId)?.state == JobState.running,
        );

        final cancelResp = await translateHandlerErrors(
          handlers.handleCancelJob(
            Request(
              'POST',
              Uri.parse('http://localhost/api/jobs/${job.jobId}/cancel'),
            ),
            job.jobId,
          ),
        );
        expect(cancelResp.statusCode, HttpStatus.ok);
        await _pumpUntil(
          () => manager.get(job.jobId)?.state == JobState.cancelled,
        );

        final getResp = await translateHandlerErrors(
          handlers.handleGetJob(
            Request('GET', Uri.parse('http://localhost/api/jobs/${job.jobId}')),
            job.jobId,
          ),
        );
        final body = jsonDecode(await getResp.readAsString()) as Map;
        expect(body['state'], 'cancelled');
      },
    );

    test(
      'POST /api/jobs/{id}/cancel returns 409 when already terminated',
      () async {
        final job = manager.start(
          operation: 'test.op',
          work: (sink, cancellation) async => {'ok': true},
        );
        await _pumpUntil(
          () => manager.get(job.jobId)?.state == JobState.succeeded,
        );

        final response = await translateHandlerErrors(
          handlers.handleCancelJob(
            Request(
              'POST',
              Uri.parse('http://localhost/api/jobs/${job.jobId}/cancel'),
            ),
            job.jobId,
          ),
        );
        expect(response.statusCode, HttpStatus.conflict);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'job_terminal');
      },
    );

    test('POST /api/jobs/{id}/cancel returns 404 for unknown id', () async {
      final response = await translateHandlerErrors(
        handlers.handleCancelJob(
          Request(
            'POST',
            Uri.parse('http://localhost/api/jobs/missing/cancel'),
          ),
          'missing',
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('DELETE /api/jobs/{id} purges a terminated job', () async {
      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) async => {'ok': true},
      );
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );

      final response = await translateHandlerErrors(
        handlers.handlePurgeJob(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/jobs/${job.jobId}'),
          ),
          job.jobId,
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(manager.get(job.jobId), isNull);
    });

    test('DELETE /api/jobs/{id} 409 when the job is still running', () async {
      final completer = Completer<Map<String, Object?>>();
      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) => completer.future,
      );
      await _pumpUntil(() => manager.get(job.jobId)?.state == JobState.running);

      final response = await translateHandlerErrors(
        handlers.handlePurgeJob(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/jobs/${job.jobId}'),
          ),
          job.jobId,
        ),
      );
      expect(response.statusCode, HttpStatus.conflict);

      completer.complete({'late': true});
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );
    });
  });
}

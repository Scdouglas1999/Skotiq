import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/framing_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('FramingHandlers', () {
    late ProviderContainer container;
    late FramingHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = FramingHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test(
      'slew to target malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSlewToTarget(
            Request(
              'POST',
              Uri.parse('http://localhost/api/framing/slew-to-target'),
              body: jsonEncode({}),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test(
      'center on target malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCenterOnTarget(
            Request(
              'POST',
              Uri.parse('http://localhost/api/framing/center-on-target'),
              body: '{',
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test(
      'center on target rejects out-of-range coordinates and settings',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCenterOnTarget(
            Request(
              'POST',
              Uri.parse('http://localhost/api/framing/center-on-target'),
              body: jsonEncode({
                'ra': 25,
                'dec': 45,
                'maxIterations': 0,
                'exposureTime': -1,
              }),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['field'], 'ra');
        expect(body['error'], contains('<= 24'));
      },
    );

    test('save framing malformed payload returns JSON error', () async {
      final response = await translateHandlerErrors(
        handlers.handleSaveFraming(
          Request(
            'POST',
            Uri.parse('http://localhost/api/framing/save'),
            body: jsonEncode({'ra': 1.0}),
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test('save framing rejects impossible coordinates and rotation', () async {
      for (final payload in const [
        {'name': 'Bad RA', 'ra': 99, 'dec': 0, 'positionAngle': 0},
        {'name': 'Bad Dec', 'ra': 1, 'dec': 100, 'positionAngle': 0},
        {'name': 'Bad PA', 'ra': 1, 'dec': 0, 'positionAngle': 720},
      ]) {
        final response = await translateHandlerErrors(
          handlers.handleSaveFraming(
            Request(
              'POST',
              Uri.parse('http://localhost/api/framing/save'),
              body: jsonEncode(payload),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest, reason: '$payload');
      }
    });

    test('rotate to malformed payload returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleRotateTo(
          Request(
            'POST',
            Uri.parse('http://localhost/api/framing/rotate-to'),
            body: jsonEncode({}),
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });
  });

  group('center-on-target job', () {
    Future<Job> runCenteringJob(CenteringResult outcome) async {
      final jobs = JobManager(emitEvent: (_) {});
      addTearDown(jobs.dispose);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((ref) {
            final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
            ref.onDispose(db.close);
            return db;
          }),
          centeringServiceProvider.overrideWith(
            (ref) => _CenteringEndingWith(ref, outcome),
          ),
        ],
      );
      addTearDown(container.dispose);
      final handlers = FramingHandlers(container, jobManager: jobs);

      final response = await handlers.handleCenterOnTarget(
        Request(
          'POST',
          Uri.parse('http://localhost/api/framing/center-on-target'),
          body: jsonEncode({'ra': 22.14, 'dec': 45.0}),
        ),
      );
      final jobId =
          (jsonDecode(await response.readAsString()) as Map)['jobId'] as String;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!jobs.get(jobId)!.state.isTerminal) {
        if (DateTime.now().isAfter(deadline)) fail('the job never ended');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return jobs.get(jobId)!;
    }

    test('a centering that gives up ends the job failed, with its attempts',
        () async {
      final job = await runCenteringJob(
        CenteringResult(
          success: false,
          iterations: 5,
          errorMessage: 'Plate solve failed after 5 attempts: No solution '
              'found for this frame.',
          iterationHistory: [
            for (var n = 1; n <= 5; n++)
              CenteringIteration(
                iterationNumber: n,
                plateSolveSuccess: false,
                errorMessage: 'No solution found for this frame.',
                timestamp: DateTime.utc(2026, 11, 11),
              ),
          ],
        ),
      );

      expect(job.state, JobState.failed);
      expect(job.result, isNull);
      expect(job.error!['code'], 'centering_failed');
      expect(
        job.error!['message'],
        'Plate solve failed after 5 attempts: No solution found for this '
        'frame.',
      );
      final details = job.error!['details'] as Map;
      expect(details['success'], isFalse);
      expect(details['iterations'], 5);
      expect(details['iterationHistory'], hasLength(5));
    });

    test('a centering that converges ends the job succeeded', () async {
      final job = await runCenteringJob(
        const CenteringResult(
          success: true,
          iterations: 2,
          finalOffsetArcsec: 4.2,
          iterationHistory: [],
        ),
      );

      expect(job.state, JobState.succeeded);
      expect(job.result!['success'], isTrue);
      expect(job.result!['finalOffsetArcsec'], 4.2);
    });
  });
}

class _CenteringEndingWith extends CenteringService {
  _CenteringEndingWith(super.ref, this.outcome);

  final CenteringResult outcome;

  @override
  Future<CenteringResult> centerOnTarget({
    required double targetRa,
    required double targetDec,
    required PlateSolverConfig solverConfig,
    CenteringConfig config = const CenteringConfig(),
    void Function(CenteringStatus)? onStatusUpdate,
  }) async =>
      outcome;
}

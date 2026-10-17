import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/depthlock/depthlock_models.dart';
import 'package:skotiq_core/src/models/errors/server_error.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

const _geometry = {
  'width': 4144,
  'height': 2822,
  'crval1': 83.82,
  'crval2': -5.39,
  'crpix1': 2072.0,
  'crpix2': 1411.0,
  'cd1_1': -0.0002,
  'cd1_2': 0.0,
  'cd2_1': 0.0,
  'cd2_2': 0.0002,
};

const _rectangle = {
  'raDeg': 83.82,
  'decDeg': -5.39,
  'widthArcsec': 600.0,
  'heightArcsec': 400.0,
  'rotationDeg': 0.0,
};

const _measurement = {
  'region': _rectangle,
  'background': _rectangle,
  'scaleArcsec': 6.0,
  'threshold': 12.0,
  'minCoverage': 0.95,
  'systematicFloorAdu': 0.4,
  'systematicFloorSource': 'flat master residual',
};

const _definition = {
  'label': 'M42 core',
  'projectId': 'project-1',
  'targetId': 'm42',
  'profileId': 'profile-1',
  'filterName': 'Ha',
  'filterIndex': 2,
  'referencePath': '/data/m42/ref.fits',
  'reference': _geometry,
  'acquisition': {
    'instrument': 'ASI2600MM',
    'filter': 'Ha',
    'exposureSecs': 300.0,
    'gain': 100,
    'offset': 50,
    'binX': 1,
    'binY': 1,
    'ccdTempC': -10.0,
  },
  'temperatureToleranceC': 1.0,
  'darkPath': '/data/masters/dark.fits',
  'flatPath': '/data/masters/flat.fits',
  'measurement': _measurement,
  'enabled': true,
  'automaticCompletion': true,
};

const _goal = {
  'id': 'm42-ha',
  'revision': 3,
  'definition': _definition,
  'selectedAtMs': 1757000000000,
  'evidenceFrames': 18,
  'evidenceRevision': 3,
  'analysisCurrent': true,
  'report': {
    'state': 'confirmationPending',
    'score': 13.4,
    'conservativeScore': 12.1,
    'uncertaintyAdu': 0.9,
    'coverage': 0.98,
    'evidenceFrames': 18,
    'confirmationFrames': 2,
    'reason': 'holding above threshold for a second look',
    'forecast': {
      'framesToThreshold': 0,
      'framesToConfirm': 3,
      'reachable': true,
      'ceilingScore': 24.5,
      'perFrameNoiseAdu': 1.8,
      'recentFrameNoiseAdu': 2.4,
      'bestFrameNoiseAdu': 1.6,
    },
  },
  'candidateFrames': 16,
  'lastIssue': null,
  'archivedRevisions': 2,
  'estimatorVersion': 1,
};

Map<String, dynamic> _bodyOf(RecordedRequest request) =>
    jsonDecode(request.body!) as Map<String, dynamic>;

void main() {
  group('NetworkBackend DepthLock contract', () {
    test('reads status, the goal list and one goal', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/depthlock/status',
          body: jsonEncode({
            'status': {
              'available': true,
              'goals': 1,
              'queueCapacity': 16,
              'queued': 0,
              'processed': 42,
              'dropped': 1,
              'evidenceAdded': 18,
              'evidenceRejected': 3,
              'lastFrameMs': 820,
              'maxFrameMs': 1400,
            },
          }),
        )
        ..setResponse(
          '/api/depthlock/goals',
          body: jsonEncode({
            'goals': [_goal],
          }),
        )
        ..setResponse(
          '/api/depthlock/goals/m42-ha',
          body: jsonEncode({'goal': _goal}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final status = await backend.depthLockStatus();
      expect(status.available, isTrue);
      expect(status.dropped, 1);
      expect(status.maxFrameMs, 1400);

      final goals = await backend.listDepthLockGoals();
      expect(goals.single.id, 'm42-ha');
      expect(goals.single.state, DepthLockState.confirmationPending);
      expect(goals.single.definition.measurement.threshold, 12);

      final goal = await backend.getDepthLockGoal('m42-ha');
      expect(goal.revision, 3);
      expect(goal.report!.conservativeScore, 12.1);
      // The forecast rides on the report, so a remote client can say how many
      // more exposures the goal wants without asking a second question.
      final forecast = goal.report!.forecast!;
      expect(forecast.framesToThreshold, 0);
      expect(forecast.framesToConfirm, 3);
      expect(forecast.framesRemaining, 3);
      expect(forecast.reachable, isTrue);
      expect(forecast.ceilingScore, 24.5);
      expect(forecast.bestFrameNoiseAdu, 1.6);
      expect(
        fake.requests.map((r) => '${r.method} ${r.path}'),
        containsAll(const <String>[
          'GET /api/depthlock/status',
          'GET /api/depthlock/goals',
          'GET /api/depthlock/goals/m42-ha',
        ]),
      );
    });

    test('mutations send the definition and the expected revision', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/depthlock/goals',
          method: 'POST',
          body: jsonEncode({'goal': _goal}),
        )
        ..setResponse(
          '/api/depthlock/goals/m42-ha',
          method: 'PUT',
          body: jsonEncode({'goal': _goal}),
        )
        ..setResponse(
          '/api/depthlock/goals/m42-ha/preferences',
          method: 'POST',
          body: jsonEncode({'goal': _goal}),
        )
        ..setResponse('/api/depthlock/goals/m42-ha', method: 'DELETE')
        ..setResponse(
          '/api/depthlock/goals/m42-ha/replay',
          method: 'POST',
          body: jsonEncode({'goal': _goal}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      final definition = DepthLockGoalDefinition.fromJson(
        Map<String, dynamic>.from(_definition),
      );

      await backend.createDepthLockGoal(definition, goalId: 'm42-ha');
      expect(_bodyOf(fake.requests.last), {
        'goalId': 'm42-ha',
        'definition': _definition,
      });

      await backend.reviseDepthLockGoal(
        goalId: 'm42-ha',
        expectedRevision: 3,
        definition: definition,
      );
      expect(fake.requests.last.method, 'PUT');
      expect(_bodyOf(fake.requests.last)['expectedRevision'], 3);

      await backend.setDepthLockGoalPreferences(
        goalId: 'm42-ha',
        expectedRevision: 3,
        enabled: true,
        automaticCompletion: false,
      );
      expect(_bodyOf(fake.requests.last), {
        'expectedRevision': 3,
        'enabled': true,
        'automaticCompletion': false,
      });

      await backend.removeDepthLockGoal(goalId: 'm42-ha', expectedRevision: 3);
      // The revision rides in the query string: a DELETE carries no body, and
      // dropping the guard would let a delete race an edit it never saw.
      expect(fake.requests.last.method, 'DELETE');
      expect(fake.requests.last.url.queryParameters['expectedRevision'], '3');

      final replayed = await backend.replayDepthLockGoal('m42-ha');
      expect(replayed.id, 'm42-ha');
      expect(fake.requests.last.path, '/api/depthlock/goals/m42-ha/replay');
    });

    test('a created goal may leave its id to the host', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/depthlock/goals',
          method: 'POST',
          body: jsonEncode({'goal': _goal}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await backend.createDepthLockGoal(
        DepthLockGoalDefinition.fromJson(
          Map<String, dynamic>.from(_definition),
        ),
      );

      // No `goalId` key at all rather than an explicit null: the host reads a
      // missing id as "generate one".
      expect(_bodyOf(fake.requests.single).containsKey('goalId'), isFalse);
    });

    test('ingest, inspection and the geometry helpers decode', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/depthlock/goals/m42-ha/ingest',
          method: 'POST',
          body: jsonEncode({
            'outcome': {
              'outcome': 'preSelection',
              'state': null,
              'reason': 'acquired before the goal was selected',
            },
          }),
        )
        ..setResponse(
          '/api/depthlock/reference/inspect',
          method: 'POST',
          body: jsonEncode({
            'reference': {
              'width': 4144,
              'height': 2822,
              'pixelType': 'u16',
              'monochrome': true,
              'geometry': _geometry,
              'geometryIssue': null,
              'pixelScaleArcsec': 0.72,
              'acquisition': null,
              'acquisitionIssue': 'no FILTER card',
            },
          }),
        )
        ..setResponse(
          '/api/depthlock/reference/sky-rectangle',
          method: 'POST',
          body: jsonEncode({'rectangle': _rectangle}),
        )
        ..setResponse(
          '/api/depthlock/measurement/check',
          method: 'POST',
          body: jsonEncode({'cells': 2400}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final outcome = await backend.ingestDepthLockFrame(
        goalId: 'm42-ha',
        path: '/data/m42/light_0042.fits',
      );
      expect(outcome.outcome, 'preSelection');
      expect(outcome.state, isNull);
      expect(_bodyOf(fake.requests.last), {
        'path': '/data/m42/light_0042.fits',
      });

      final reference = await backend.inspectDepthLockReference('/ref.fits');
      expect(reference.geometry, isNotNull);
      expect(reference.acquisition, isNull);
      expect(reference.acquisitionIssue, 'no FILTER card');

      final rectangle = await backend.depthLockSkyRectangle(
        reference: reference.geometry!,
        x0: 10,
        y0: 20,
        x1: 110,
        y1: 140,
      );
      expect(rectangle.widthArcsec, 600);
      expect(_bodyOf(fake.requests.last)['x1'], 110);

      expect(
        await backend.checkDepthLockMeasurement(
          DepthLockMeasurement.fromJson(
            Map<String, dynamic>.from(_measurement),
          ),
        ),
        2400,
      );
    });

    test(
      'a report with no forecast yet decodes as absent, not as zeros',
      () async {
        final unforecast = Map<String, dynamic>.from(_goal);
        unforecast['report'] = <String, dynamic>{
          ...(_goal['report']! as Map).cast<String, dynamic>(),
        }..remove('forecast');
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/depthlock/goals/m42-ha',
            body: jsonEncode({'goal': unforecast}),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final goal = await backend.getDepthLockGoal('m42-ha');
        // "We cannot project yet" and "no frames to go" are different answers.
        expect(goal.report!.forecast, isNull);
        expect(goal.report!.state, DepthLockState.confirmationPending);
      },
    );

    test('the curve keeps the measured/projected split and the cap', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/depthlock/goals/m42-ha/curve',
          body: jsonEncode({
            'points': [
              {
                'frames': 6,
                'score': 7.2,
                'conservativeScore': 6.4,
                'projected': false,
              },
              {
                'frames': 20,
                'score': 13.0,
                'conservativeScore': 12.1,
                'projected': true,
              },
            ],
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final points = await backend.depthLockGoalCurve('m42-ha', maxPoints: 24);

      expect(points, hasLength(2));
      expect(points.first.frames, 6);
      expect(points.first.projected, isFalse);
      expect(points.last.conservativeScore, 12.1);
      expect(points.last.projected, isTrue);
      expect(fake.requests.single.method, 'GET');
      expect(fake.requests.single.url.queryParameters['maxPoints'], '24');
    });

    test(
      'a floor suggestion posts the paths and decodes the measurement',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/depthlock/measurement/suggest-floor',
            method: 'POST',
            body: jsonEncode({
              'suggestion': {
                'floorAdu': 0.42,
                'darkNoiseAdu': 0.31,
                'flatRelativeNoise': 0.0018,
                'skyAdu': 1240.0,
                'aperturePixels': 69.4,
                'source': 'measured from the reference light and its masters',
              },
            }),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final suggestion = await backend.suggestDepthLockFloor(
          referencePath: '/data/m42/ref.fits',
          darkPath: '/data/masters/dark.fits',
          flatPath: '/data/masters/flat.fits',
          scaleArcsec: 6,
          pixelScaleArcsec: 0.72,
        );

        expect(suggestion.floorAdu, 0.42);
        expect(suggestion.skyAdu, 1240);
        expect(suggestion.aperturePixels, 69.4);
        expect(_bodyOf(fake.requests.single), {
          'referencePath': '/data/m42/ref.fits',
          'darkPath': '/data/masters/dark.fits',
          'flatPath': '/data/masters/flat.fits',
          'scaleArcsec': 6.0,
          'pixelScaleArcsec': 0.72,
        });
      },
    );

    test('an unknown pixel scale is omitted, not sent as null', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/depthlock/measurement/suggest-floor',
          method: 'POST',
          body: jsonEncode({
            'suggestion': {
              'floorAdu': 0.42,
              'darkNoiseAdu': 0.31,
              'flatRelativeNoise': 0.0018,
              'skyAdu': 1240.0,
              'aperturePixels': 69.4,
              'source': 'measured from the reference light and its masters',
            },
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await backend.suggestDepthLockFloor(
        referencePath: '/data/m42/ref.fits',
        darkPath: '/data/masters/dark.fits',
        flatPath: '/data/masters/flat.fits',
        scaleArcsec: 6,
      );

      // Absent means "read the scale from the reference's TAN header", which
      // is what a local call does; an explicit null would be a value.
      expect(
        _bodyOf(fake.requests.single).containsKey('pixelScaleArcsec'),
        isFalse,
      );
    });

    test('an unreadable reference keeps its native reason', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/depthlock/measurement/suggest-floor',
          method: 'POST',
          status: 400,
          body: jsonEncode({
            'error': 'depthlock_invalid_request',
            'code': 'depthlock_invalid_request',
            'message':
                '/data/m42/unsolved.fits carries no undistorted TAN solution',
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(
        backend.suggestDepthLockFloor(
          referencePath: '/data/m42/unsolved.fits',
          darkPath: '/data/masters/dark.fits',
          flatPath: '/data/masters/flat.fits',
          scaleArcsec: 6,
        ),
        throwsA(
          isA<ServerError>()
              .having((e) => e.httpStatus, 'httpStatus', 400)
              .having(
                (e) => e.message,
                'message',
                '/data/m42/unsolved.fits carries no undistorted TAN solution',
              ),
        ),
      );
    });

    test(
      'a missing envelope key throws rather than reading as empty',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse('/api/depthlock/status', body: '{}')
          ..setResponse('/api/depthlock/goals', body: '{}')
          ..setResponse('/api/depthlock/goals/m42-ha', body: '{}')
          ..setResponse('/api/depthlock/goals/m42-ha/curve', body: '{}')
          ..setResponse(
            '/api/depthlock/measurement/suggest-floor',
            method: 'POST',
            body: '{}',
          )
          ..setResponse(
            '/api/depthlock/measurement/check',
            method: 'POST',
            body: '{"cells":"lots"}',
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        // "The host has no goals" and "the host answered something else" are
        // different facts; defaulting would show the operator the wrong one.
        await expectLater(backend.depthLockStatus(), throwsA(isA<Exception>()));
        await expectLater(
          backend.listDepthLockGoals(),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          backend.getDepthLockGoal('m42-ha'),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          backend.checkDepthLockMeasurement(
            DepthLockMeasurement.fromJson(
              Map<String, dynamic>.from(_measurement),
            ),
          ),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          backend.depthLockGoalCurve('m42-ha'),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          backend.suggestDepthLockFloor(
            referencePath: '/data/m42/ref.fits',
            darkPath: '/data/masters/dark.fits',
            flatPath: '/data/masters/flat.fits',
            scaleArcsec: 6,
          ),
          throwsA(isA<Exception>()),
        );
      },
    );

    test(
      'a stale revision and a missing goal keep their native reason',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/depthlock/goals/m42-ha',
            method: 'PUT',
            status: 409,
            body: jsonEncode({
              'error': 'depthlock_stale_revision',
              'code': 'depthlock_stale_revision',
              'message': 'stale revision for DepthLock goal m42-ha',
            }),
          )
          ..setResponse(
            '/api/depthlock/goals/gone',
            status: 404,
            body: jsonEncode({
              'error': 'depthlock_goal_not_found',
              'code': 'depthlock_goal_not_found',
              'message': 'DepthLock goal gone does not exist',
            }),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        await expectLater(
          backend.reviseDepthLockGoal(
            goalId: 'm42-ha',
            expectedRevision: 1,
            definition: DepthLockGoalDefinition.fromJson(
              Map<String, dynamic>.from(_definition),
            ),
          ),
          throwsA(
            isA<ServerError>()
                .having((e) => e.code, 'code', 'depthlock_stale_revision')
                .having((e) => e.httpStatus, 'httpStatus', 409)
                .having(
                  (e) => e.message,
                  'message',
                  'stale revision for DepthLock goal m42-ha',
                ),
          ),
        );

        await expectLater(
          backend.getDepthLockGoal('gone'),
          throwsA(
            isA<ServerError>()
                .having((e) => e.code, 'code', 'depthlock_goal_not_found')
                .having((e) => e.httpStatus, 'httpStatus', 404)
                .having(
                  (e) => e.message,
                  'message',
                  'DepthLock goal gone does not exist',
                ),
          ),
        );
      },
    );
  });
}

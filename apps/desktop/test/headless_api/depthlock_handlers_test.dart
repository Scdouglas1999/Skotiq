import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/handlers/depthlock_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/system_handlers.dart'
    show availableHeadlessEndpoints;
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Minimal but complete goal definition. Every field the wire shape requires
/// is present, because a definition missing one is a different test.
DepthLockGoalDefinition definition({
  String label = 'M42 core',
  String filterName = 'Ha',
  double threshold = 12,
  bool enabled = true,
  bool automaticCompletion = true,
}) => DepthLockGoalDefinition(
  label: label,
  projectId: 'project-1',
  targetId: 'm42',
  profileId: 'profile-1',
  filterName: filterName,
  filterIndex: 2,
  referencePath: '/data/m42/ref.fits',
  reference: const ReferenceGeometry(
    width: 4144,
    height: 2822,
    crval1: 83.82,
    crval2: -5.39,
    crpix1: 2072,
    crpix2: 1411,
    cd1_1: -0.0002,
    cd1_2: 0,
    cd2_1: 0,
    cd2_2: 0.0002,
  ),
  acquisition: AcquisitionSettings(
    instrument: 'ASI2600MM',
    filter: filterName,
    exposureSecs: 300,
    gain: 100,
    offset: 50,
    binX: 1,
    binY: 1,
    ccdTempC: -10,
  ),
  temperatureToleranceC: 1,
  darkPath: '/data/masters/dark.fits',
  flatPath: '/data/masters/flat.fits',
  measurement: DepthLockMeasurement(
    region: const SkyRectangle(
      raDeg: 83.82,
      decDeg: -5.39,
      widthArcsec: 600,
      heightArcsec: 400,
      rotationDeg: 0,
    ),
    background: const SkyRectangle(
      raDeg: 83.9,
      decDeg: -5.5,
      widthArcsec: 600,
      heightArcsec: 400,
      rotationDeg: 0,
    ),
    scaleArcsec: 6,
    threshold: threshold,
    minCoverage: 0.95,
    systematicFloorAdu: 0.4,
    systematicFloorSource: 'flat master residual',
  ),
  enabled: enabled,
  automaticCompletion: automaticCompletion,
);

/// In-memory stand-in for the native goal store.
///
/// Extends [DisconnectedBackend] so every method this feature does not touch
/// keeps failing closed, and raises the same
/// `SkotiqError.operationFailed(<reason>)` with the same sentences the
/// Rust store raises — the handler classifies on those sentences, so a fake
/// that invented friendlier ones would test nothing.
class _FakeDepthLockBackend extends DisconnectedBackend {
  final Map<String, DepthLockGoal> goals = {};
  final List<String> ingested = [];
  var _generated = 0;

  Never _missing(String goalId) => throw bridge.SkotiqError.operationFailed(
    'DepthLock goal $goalId does not exist',
  );

  DepthLockGoal _require(String goalId, int expectedRevision) {
    final goal = goals[goalId];
    if (goal == null) _missing(goalId);
    if (goal.revision != expectedRevision) {
      throw bridge.SkotiqError.operationFailed(
        'stale revision for DepthLock goal $goalId',
      );
    }
    return goal;
  }

  DepthLockGoal _record(
    String id,
    int revision,
    DepthLockGoalDefinition definition,
  ) => DepthLockGoal(
    id: id,
    revision: revision,
    definition: definition,
    selectedAtMs: 1757000000000,
    evidenceFrames: 0,
    evidenceRevision: revision,
    analysisCurrent: true,
    candidateFrames: 0,
    archivedRevisions: revision - 1,
    estimatorVersion: 1,
  );

  @override
  Future<DepthLockStatus> depthLockStatus() async => DepthLockStatus(
    available: true,
    goals: goals.length,
    queueCapacity: 16,
    queued: 0,
    processed: 4,
    dropped: 0,
    evidenceAdded: 4,
    evidenceRejected: 1,
    lastFrameMs: 820,
    maxFrameMs: 1400,
  );

  @override
  Future<List<DepthLockGoal>> listDepthLockGoals() async =>
      goals.values.toList(growable: false);

  @override
  Future<DepthLockGoal> getDepthLockGoal(String goalId) async =>
      goals[goalId] ?? _missing(goalId);

  @override
  Future<DepthLockGoal> createDepthLockGoal(
    DepthLockGoalDefinition definition, {
    String? goalId,
  }) async {
    if (definition.automaticCompletion && !definition.enabled) {
      throw bridge.SkotiqError.operationFailed(
        'automaticCompletion requires enabled',
      );
    }
    final id = goalId ?? 'goal-${++_generated}';
    final goal = _record(id, 1, definition);
    goals[id] = goal;
    return goal;
  }

  @override
  Future<DepthLockGoal> reviseDepthLockGoal({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  }) async {
    final previous = _require(goalId, expectedRevision);
    final goal = _record(goalId, previous.revision + 1, definition);
    goals[goalId] = goal;
    return goal;
  }

  @override
  Future<DepthLockGoal> setDepthLockGoalPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) async {
    final previous = _require(goalId, expectedRevision);
    // Preferences never change the revision: the evidence they govern stays
    // attributed to the revision that gathered it.
    final goal = _record(
      goalId,
      previous.revision,
      previous.definition.copyWith(
        enabled: enabled,
        automaticCompletion: automaticCompletion,
      ),
    );
    goals[goalId] = goal;
    return goal;
  }

  @override
  Future<void> removeDepthLockGoal({
    required String goalId,
    required int expectedRevision,
  }) async {
    _require(goalId, expectedRevision);
    goals.remove(goalId);
  }

  @override
  Future<DepthLockIngestOutcome> ingestDepthLockFrame({
    required String goalId,
    required String path,
  }) async {
    if (!goals.containsKey(goalId)) _missing(goalId);
    ingested.add(path);
    return const DepthLockIngestOutcome(
      outcome: 'added',
      state: DepthLockState.collecting,
      reason: 'evidence accepted',
    );
  }

  @override
  Future<DepthLockGoal> replayDepthLockGoal(String goalId) async =>
      goals[goalId] ?? _missing(goalId);

  /// The cap the last curve request actually reached the store with.
  int? curveMaxPoints;

  @override
  Future<List<DepthLockCurvePoint>> depthLockGoalCurve(
    String goalId, {
    int maxPoints = 60,
  }) async {
    if (!goals.containsKey(goalId)) _missing(goalId);
    curveMaxPoints = maxPoints;
    return const [
      DepthLockCurvePoint(
        frames: 6,
        score: 7.2,
        conservativeScore: 6.4,
        projected: false,
      ),
      DepthLockCurvePoint(
        frames: 12,
        score: 10.1,
        conservativeScore: 9.2,
        projected: false,
      ),
      DepthLockCurvePoint(
        frames: 20,
        score: 13.0,
        conservativeScore: 12.1,
        projected: true,
      ),
    ];
  }

  @override
  Future<int> checkDepthLockMeasurement(
    DepthLockMeasurement measurement,
  ) async {
    if (measurement.scaleArcsec <= 0) {
      throw bridge.SkotiqError.operationFailed('scaleArcsec must be positive');
    }
    return 2400;
  }

  /// Records what the last floor suggestion was asked for; a reference with
  /// no TAN header and no supplied scale refuses the way the native estimator
  /// does.
  ({
    String referencePath,
    String darkPath,
    String flatPath,
    double scaleArcsec,
    double? pixelScaleArcsec,
  })?
  floorRequest;

  @override
  Future<DepthLockFloorSuggestion> suggestDepthLockFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  }) async {
    floorRequest = (
      referencePath: referencePath,
      darkPath: darkPath,
      flatPath: flatPath,
      scaleArcsec: scaleArcsec,
      pixelScaleArcsec: pixelScaleArcsec,
    );
    if (referencePath.endsWith('unsolved.fits') && pixelScaleArcsec == null) {
      throw bridge.SkotiqError.operationFailed(
        '$referencePath carries no undistorted TAN solution',
      );
    }
    return const DepthLockFloorSuggestion(
      floorAdu: 0.42,
      darkNoiseAdu: 0.31,
      flatRelativeNoise: 0.0018,
      skyAdu: 1240,
      aperturePixels: 69.4,
      source: 'measured from the reference light and its masters',
    );
  }

  @override
  Future<DepthLockReferenceInfo> inspectDepthLockReference(String path) async =>
      DepthLockReferenceInfo(
        width: 4144,
        height: 2822,
        pixelType: 'u16',
        monochrome: true,
        geometry: definition().reference,
        pixelScaleArcsec: 0.72,
        acquisition: definition().acquisition,
      );

  @override
  Future<SkyRectangle> depthLockSkyRectangle({
    required ReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async => const SkyRectangle(
    raDeg: 83.82,
    decDeg: -5.39,
    widthArcsec: 600,
    heightArcsec: 400,
    rotationDeg: 0,
  );
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDepthLockBackend backend;
  late ProviderContainer container;
  late DepthLockHandlers handlers;

  setUp(() {
    backend = _FakeDepthLockBackend();
    container = createHeadlessTestContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    handlers = DepthLockHandlers(container);
  });

  Request post(String path, Object body) => Request(
    'POST',
    Uri.parse('http://localhost$path'),
    headers: const {'content-type': 'application/json'},
    body: jsonEncode(body),
  );

  Future<Map<String, dynamic>> bodyOf(Response response) async =>
      jsonDecode(await response.readAsString()) as Map<String, dynamic>;

  Future<DepthLockGoal> seed({String id = 'm42-ha'}) =>
      backend.createDepthLockGoal(definition(), goalId: id);

  group('goal round-trips', () {
    test('a created goal reads back with the same definition', () async {
      final created = await translateHandlerErrors(
        handlers.handleCreateGoal(
          post('/api/depthlock/goals', {
            'goalId': 'm42-ha',
            'definition': definition().toJson(),
          }),
        ),
      );
      expect(created.statusCode, HttpStatus.ok);
      final createdGoal = (await bodyOf(created))['goal'] as Map;
      expect(createdGoal['id'], 'm42-ha');
      expect(createdGoal['revision'], 1);

      final read = await translateHandlerErrors(
        handlers.handleGetGoal(
          Request(
            'GET',
            Uri.parse('http://localhost/api/depthlock/goals/m42-ha'),
          ),
          'm42-ha',
        ),
      );
      expect(read.statusCode, HttpStatus.ok);
      // The models ARE the wire shape, so the round trip has to be exact —
      // anything less means a field is being dropped on one of the two hops.
      expect((await bodyOf(read))['goal'], createdGoal);
    });

    test('an omitted goalId has the store generate one', () async {
      final response = await translateHandlerErrors(
        handlers.handleCreateGoal(
          post('/api/depthlock/goals', {'definition': definition().toJson()}),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(((await bodyOf(response))['goal'] as Map)['id'], 'goal-1');
    });

    test('listing returns every stored goal', () async {
      await seed(id: 'm42-ha');
      await seed(id: 'm42-oiii');

      final response = await translateHandlerErrors(
        handlers.handleListGoals(
          Request('GET', Uri.parse('http://localhost/api/depthlock/goals')),
        ),
      );

      final goals = (await bodyOf(response))['goals'] as List;
      expect(
        goals.map((goal) => (goal as Map)['id']),
        containsAll(<String>['m42-ha', 'm42-oiii']),
      );
    });

    test('a revision advances the goal and keeps the new definition', () async {
      await seed();

      final response = await translateHandlerErrors(
        handlers.handleReviseGoal(
          Request(
            'PUT',
            Uri.parse('http://localhost/api/depthlock/goals/m42-ha'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'expectedRevision': 1,
              'definition': definition(threshold: 20).toJson(),
            }),
          ),
          'm42-ha',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final goal = (await bodyOf(response))['goal'] as Map;
      expect(goal['revision'], 2);
      expect(
        ((goal['definition'] as Map)['measurement'] as Map)['threshold'],
        20,
      );
    });

    test('preferences change without moving the revision', () async {
      await seed();

      final response = await translateHandlerErrors(
        handlers.handleSetPreferences(
          post('/api/depthlock/goals/m42-ha/preferences', {
            'expectedRevision': 1,
            'enabled': true,
            'automaticCompletion': false,
          }),
          'm42-ha',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final goal = (await bodyOf(response))['goal'] as Map;
      expect(goal['revision'], 1);
      expect((goal['definition'] as Map)['automaticCompletion'], isFalse);
    });

    test('a removal reports the goal is gone and it is', () async {
      await seed();

      final response = await translateHandlerErrors(
        handlers.handleRemoveGoal(
          Request(
            'DELETE',
            Uri.parse(
              'http://localhost/api/depthlock/goals/m42-ha?expectedRevision=1',
            ),
          ),
          'm42-ha',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(await bodyOf(response), containsPair('removed', true));
      expect(backend.goals, isEmpty);
    });

    test('ingest hands the host path straight to the store', () async {
      await seed();

      final response = await translateHandlerErrors(
        handlers.handleIngestFrame(
          post('/api/depthlock/goals/m42-ha/ingest', {
            'path': '/data/m42/light_0042.fits',
          }),
          'm42-ha',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final outcome = (await bodyOf(response))['outcome'] as Map;
      expect(outcome['outcome'], 'added');
      expect(outcome['state'], 'collecting');
      expect(backend.ingested, ['/data/m42/light_0042.fits']);
    });

    test('the status surface reports the queue', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetStatus(
          Request('GET', Uri.parse('http://localhost/api/depthlock/status')),
        ),
      );

      final status = (await bodyOf(response))['status'] as Map;
      expect(status['available'], isTrue);
      expect(status['queueCapacity'], 16);
      expect(status['evidenceRejected'], 1);
    });

    test('the curve separates measured points from projected ones', () async {
      await seed();

      final response = await translateHandlerErrors(
        handlers.handleGoalCurve(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/depthlock/goals/m42-ha/curve?maxPoints=24',
            ),
          ),
          'm42-ha',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final points = (await bodyOf(response))['points'] as List;
      expect(points, hasLength(3));
      expect((points.first as Map)['frames'], 6);
      expect((points.first as Map)['projected'], isFalse);
      expect((points.last as Map)['projected'], isTrue);
      expect(backend.curveMaxPoints, 24);
    });

    test('an absent or unusable maxPoints falls back to 60', () async {
      await seed();

      Future<void> curveWith(String query) async {
        final response = await translateHandlerErrors(
          handlers.handleGoalCurve(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/depthlock/goals/m42-ha/curve$query',
              ),
            ),
            'm42-ha',
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
      }

      // A display-only read with no side effects: an unusable cap takes the
      // default rather than refusing to draw the chart at all.
      for (final query in const [
        '',
        '?maxPoints=lots',
        '?maxPoints=1',
        '?maxPoints=100000',
        '?maxPoints=-4',
      ]) {
        backend.curveMaxPoints = null;
        await curveWith(query);
        expect(backend.curveMaxPoints, 60, reason: 'for "$query"');
      }
    });

    test('a floor suggestion measures rather than guesses', () async {
      final response = await translateHandlerErrors(
        handlers.handleSuggestFloor(
          post('/api/depthlock/measurement/suggest-floor', {
            'referencePath': '/data/m42/ref.fits',
            'darkPath': '/data/masters/dark.fits',
            'flatPath': '/data/masters/flat.fits',
            'scaleArcsec': 6.0,
            'pixelScaleArcsec': 0.72,
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final suggestion = (await bodyOf(response))['suggestion'] as Map;
      expect(suggestion['floorAdu'], 0.42);
      expect(suggestion['aperturePixels'], 69.4);
      expect(
        suggestion['source'],
        'measured from the reference light and its masters',
      );
      expect(backend.floorRequest!.pixelScaleArcsec, 0.72);
    });

    test('an omitted pixel scale is passed through as absent', () async {
      // Absent means "read it from the reference's TAN header"; sending 0
      // would ask for an aperture of no pixels instead.
      await translateHandlerErrors(
        handlers.handleSuggestFloor(
          post('/api/depthlock/measurement/suggest-floor', {
            'referencePath': '/data/m42/ref.fits',
            'darkPath': '/data/masters/dark.fits',
            'flatPath': '/data/masters/flat.fits',
            'scaleArcsec': 6.0,
          }),
        ),
      );

      expect(backend.floorRequest!.pixelScaleArcsec, isNull);
    });

    test('a measurement check answers with the aperture count', () async {
      final response = await translateHandlerErrors(
        handlers.handleCheckMeasurement(
          post('/api/depthlock/measurement/check', {
            'measurement': definition().measurement.toJson(),
          }),
        ),
      );

      expect(await bodyOf(response), containsPair('cells', 2400));
    });
  });

  group('refusals name what happened', () {
    test('an unknown goal is a 404 carrying the native reason', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetGoal(
          Request(
            'GET',
            Uri.parse('http://localhost/api/depthlock/goals/nope'),
          ),
          'nope',
        ),
      );

      expect(response.statusCode, HttpStatus.notFound);
      final body = await bodyOf(response);
      expect(body['error'], 'depthlock_goal_not_found');
      expect(body['code'], 'depthlock_goal_not_found');
      // Verbatim: every surface above renders the store's own sentence.
      expect(body['message'], 'DepthLock goal nope does not exist');
    });

    test('a curve for a goal that does not exist is a 404', () async {
      final response = await translateHandlerErrors(
        handlers.handleGoalCurve(
          Request(
            'GET',
            Uri.parse('http://localhost/api/depthlock/goals/nope/curve'),
          ),
          'nope',
        ),
      );

      expect(response.statusCode, HttpStatus.notFound);
      final body = await bodyOf(response);
      expect(body['code'], 'depthlock_goal_not_found');
      expect(body['message'], 'DepthLock goal nope does not exist');
    });

    test('a stale revision is a 409, not a silent overwrite', () async {
      await seed();

      final response = await translateHandlerErrors(
        handlers.handleReviseGoal(
          Request(
            'PUT',
            Uri.parse('http://localhost/api/depthlock/goals/m42-ha'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'expectedRevision': 7,
              'definition': definition().toJson(),
            }),
          ),
          'm42-ha',
        ),
      );

      expect(response.statusCode, HttpStatus.conflict);
      final body = await bodyOf(response);
      expect(body['error'], 'depthlock_stale_revision');
      expect(body['message'], 'stale revision for DepthLock goal m42-ha');
      // The losing edit changed nothing.
      expect(backend.goals['m42-ha']!.revision, 1);
    });

    test('a definition the store refuses is a 400, not a 500', () async {
      final response = await translateHandlerErrors(
        handlers.handleCreateGoal(
          post('/api/depthlock/goals', {
            'definition': definition(
              enabled: false,
              automaticCompletion: true,
            ).toJson(),
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = await bodyOf(response);
      expect(body['error'], 'depthlock_invalid_request');
      expect(body['message'], 'automaticCompletion requires enabled');
    });

    test('a malformed definition names the field, not a Dart type', () async {
      final response = await translateHandlerErrors(
        handlers.handleCreateGoal(
          post('/api/depthlock/goals', {
            'definition': {'label': 'half a goal'},
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(await bodyOf(response), containsPair('field', 'definition'));
    });

    test(
      'a reference with no solution refuses with the native reason',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSuggestFloor(
            post('/api/depthlock/measurement/suggest-floor', {
              'referencePath': '/data/m42/unsolved.fits',
              'darkPath': '/data/masters/dark.fits',
              'flatPath': '/data/masters/flat.fits',
              'scaleArcsec': 6.0,
            }),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = await bodyOf(response);
        expect(body['code'], 'depthlock_invalid_request');
        expect(
          body['message'],
          '/data/m42/unsolved.fits carries no undistorted TAN solution',
        );
      },
    );

    test(
      'a floor suggestion without an aperture scale names the field',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSuggestFloor(
            post('/api/depthlock/measurement/suggest-floor', {
              'referencePath': '/data/m42/ref.fits',
              'darkPath': '/data/masters/dark.fits',
              'flatPath': '/data/masters/flat.fits',
            }),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(await bodyOf(response), containsPair('field', 'scaleArcsec'));
      },
    );

    test('a delete without a revision is refused before it deletes', () async {
      await seed();

      final response = await translateHandlerErrors(
        handlers.handleRemoveGoal(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/depthlock/goals/m42-ha'),
          ),
          'm42-ha',
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(await bodyOf(response), containsPair('field', 'expectedRevision'));
      expect(backend.goals, contains('m42-ha'));
    });
  });

  group('route metadata', () {
    test('a view token reads goals but cannot edit one', () {
      for (final read in const [
        '/api/depthlock/goals',
        '/api/depthlock/goals/<goalId>/curve',
      ]) {
        expect(
          HeadlessAuthPolicy.allows(
            actual: HeadlessTokenScope.view,
            method: 'GET',
            path: read,
          ),
          isTrue,
          reason: 'GET $read is a read and must not require control',
        );
      }
      for (final probe in const [
        ('POST', '/api/depthlock/goals'),
        ('PUT', '/api/depthlock/goals/<goalId>'),
        ('DELETE', '/api/depthlock/goals/<goalId>'),
        ('POST', '/api/depthlock/goals/<goalId>/preferences'),
        ('POST', '/api/depthlock/goals/<goalId>/ingest'),
        ('POST', '/api/depthlock/goals/<goalId>/replay'),
        ('POST', '/api/depthlock/measurement/suggest-floor'),
      ]) {
        expect(
          HeadlessAuthPolicy.allows(
            actual: HeadlessTokenScope.view,
            method: probe.$1,
            path: probe.$2,
          ),
          isFalse,
          reason: '${probe.$1} ${probe.$2} must require control',
        );
        expect(
          HeadlessAuthPolicy.allows(
            actual: HeadlessTokenScope.control,
            method: probe.$1,
            path: probe.$2,
          ),
          isTrue,
          reason: '${probe.$1} ${probe.$2} must not require admin',
        );
      }
    });

    test('/api/info advertises the whole DepthLock surface', () {
      expect(
        availableHeadlessEndpoints(),
        containsAll(const <String>[
          'GET /api/depthlock/status',
          'GET /api/depthlock/goals',
          'POST /api/depthlock/goals',
          'GET /api/depthlock/goals/<goalId>',
          'GET /api/depthlock/goals/<goalId>/curve',
          'PUT /api/depthlock/goals/<goalId>',
          'DELETE /api/depthlock/goals/<goalId>',
          'POST /api/depthlock/goals/<goalId>/preferences',
          'POST /api/depthlock/goals/<goalId>/ingest',
          'POST /api/depthlock/goals/<goalId>/replay',
          'POST /api/depthlock/reference/inspect',
          'POST /api/depthlock/reference/sky-rectangle',
          'POST /api/depthlock/measurement/check',
          'POST /api/depthlock/measurement/suggest-floor',
        ]),
      );
    });
  });
}

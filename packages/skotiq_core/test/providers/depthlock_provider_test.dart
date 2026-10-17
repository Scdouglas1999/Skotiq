import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/roles/depthlock_backend.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/depthlock/depthlock_models.dart';
import 'package:skotiq_core/src/models/errors/skotiq_error.dart';
import 'package:skotiq_core/src/providers/depthlock_provider.dart';

/// A [DepthLockBackend] that records what it was asked and answers from a
/// script, so the tests can assert on the exact arguments the provider sends
/// and on what it does with a refusal.
class _FakeDepthLockBackend implements DepthLockBackend {
  _FakeDepthLockBackend({List<DepthLockGoal>? goals})
    : goals = goals ?? <DepthLockGoal>[];

  List<DepthLockGoal> goals;

  int listCalls = 0;
  final List<String> calls = <String>[];

  DepthLockGoalDefinition? createdDefinition;
  String? createdGoalId;
  ({String goalId, int revision, DepthLockGoalDefinition definition})? revised;
  ({String goalId, int revision, bool enabled, bool automatic})? preferences;
  ({String goalId, int revision})? removed;
  String? replayed;
  ({String goalId, String path})? ingested;

  /// Raised by the next mutation instead of answering.
  Object? nextError;

  Object? _takeError() {
    final error = nextError;
    nextError = null;
    return error;
  }

  @override
  Future<List<DepthLockGoal>> listDepthLockGoals() async {
    listCalls++;
    return List<DepthLockGoal>.unmodifiable(goals);
  }

  @override
  Future<DepthLockGoal> getDepthLockGoal(String goalId) async =>
      goals.firstWhere((goal) => goal.id == goalId);

  @override
  Future<DepthLockGoal> createDepthLockGoal(
    DepthLockGoalDefinition definition, {
    String? goalId,
  }) async {
    calls.add('create');
    final error = _takeError();
    if (error != null) throw error;
    createdDefinition = definition;
    createdGoalId = goalId;
    final goal = _goal(id: goalId ?? 'generated', definition: definition);
    goals = <DepthLockGoal>[...goals, goal];
    return goal;
  }

  @override
  Future<DepthLockGoal> reviseDepthLockGoal({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  }) async {
    calls.add('revise');
    final error = _takeError();
    if (error != null) throw error;
    revised = (
      goalId: goalId,
      revision: expectedRevision,
      definition: definition,
    );
    final goal = _goal(
      id: goalId,
      definition: definition,
      revision: expectedRevision + 1,
    );
    goals = <DepthLockGoal>[
      for (final existing in goals)
        if (existing.id == goalId) goal else existing,
    ];
    return goal;
  }

  @override
  Future<DepthLockGoal> setDepthLockGoalPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) async {
    calls.add('preferences');
    final error = _takeError();
    if (error != null) throw error;
    preferences = (
      goalId: goalId,
      revision: expectedRevision,
      enabled: enabled,
      automatic: automaticCompletion,
    );
    final previous = goals.firstWhere((goal) => goal.id == goalId);
    final goal = _goal(
      id: goalId,
      revision: previous.revision,
      definition: previous.definition.copyWith(
        enabled: enabled,
        automaticCompletion: automaticCompletion,
      ),
    );
    goals = <DepthLockGoal>[
      for (final existing in goals)
        if (existing.id == goalId) goal else existing,
    ];
    return goal;
  }

  @override
  Future<void> removeDepthLockGoal({
    required String goalId,
    required int expectedRevision,
  }) async {
    calls.add('remove');
    final error = _takeError();
    if (error != null) throw error;
    removed = (goalId: goalId, revision: expectedRevision);
    goals = goals.where((goal) => goal.id != goalId).toList();
  }

  @override
  Future<DepthLockGoal> replayDepthLockGoal(String goalId) async {
    calls.add('replay');
    final error = _takeError();
    if (error != null) throw error;
    replayed = goalId;
    return goals.firstWhere((goal) => goal.id == goalId);
  }

  @override
  Future<DepthLockIngestOutcome> ingestDepthLockFrame({
    required String goalId,
    required String path,
  }) async {
    calls.add('ingest');
    final error = _takeError();
    if (error != null) throw error;
    ingested = (goalId: goalId, path: path);
    return const DepthLockIngestOutcome(
      outcome: 'preSelection',
      reason: 'Acquired before this goal revision was selected',
    );
  }

  @override
  Future<DepthLockStatus> depthLockStatus() async => const DepthLockStatus(
    available: true,
    goals: 1,
    queueCapacity: 32,
    queued: 0,
    processed: 4,
    dropped: 0,
    evidenceAdded: 4,
    evidenceRejected: 1,
    lastFrameMs: 12,
    maxFrameMs: 40,
  );

  @override
  Future<DepthLockReferenceInfo> inspectDepthLockReference(String path) async =>
      throw UnimplementedError();

  @override
  Future<SkyRectangle> depthLockSkyRectangle({
    required ReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async => throw UnimplementedError();

  @override
  Future<int> checkDepthLockMeasurement(
    DepthLockMeasurement measurement,
  ) async => throw UnimplementedError();

  @override
  Future<DepthLockFloorSuggestion> suggestDepthLockFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  }) async => throw UnimplementedError();

  int curveCalls = 0;
  List<DepthLockCurvePoint> curve = const <DepthLockCurvePoint>[
    DepthLockCurvePoint(
      frames: 32,
      score: 3.0,
      conservativeScore: 2.1,
      projected: false,
    ),
  ];

  @override
  Future<List<DepthLockCurvePoint>> depthLockGoalCurve(
    String goalId, {
    int maxPoints = 60,
  }) async {
    curveCalls++;
    return curve;
  }
}

const SkyRectangle _region = SkyRectangle(
  raDeg: 202.4696,
  decDeg: 47.1952,
  widthArcsec: 120,
  heightArcsec: 120,
  rotationDeg: 0,
);

const SkyRectangle _background = SkyRectangle(
  raDeg: 202.5196,
  decDeg: 47.2152,
  widthArcsec: 120,
  heightArcsec: 120,
  rotationDeg: 0,
);

const ReferenceGeometry _geometry = ReferenceGeometry(
  width: 4144,
  height: 2822,
  crval1: 202.4696,
  crval2: 47.1952,
  crpix1: 2072.5,
  crpix2: 1411.5,
  cd1_1: -0.000289,
  cd1_2: 0,
  cd2_1: 0,
  cd2_2: 0.000289,
);

const AcquisitionSettings _acquisition = AcquisitionSettings(
  instrument: 'ZWO ASI2600MM Pro',
  filter: 'L',
  exposureSecs: 300,
  binX: 1,
  binY: 1,
  gain: 100,
  offset: 50,
  ccdTempC: -10,
);

DepthLockGoalDefinition _definition({
  String label = 'Tidal tail',
  String filterName = 'L',
  bool enabled = true,
  bool automaticCompletion = false,
}) => DepthLockGoalDefinition(
  label: label,
  projectId: 'project-1',
  targetId: 'target-1',
  profileId: 'profile-1',
  filterName: filterName,
  filterIndex: 0,
  referencePath: '/data/M51/L_0001.fits',
  reference: _geometry,
  acquisition: _acquisition,
  temperatureToleranceC: 1.0,
  darkPath: '/data/masters/dark.fits',
  flatPath: '/data/masters/flat.fits',
  measurement: const DepthLockMeasurement(
    region: _region,
    background: _background,
    scaleArcsec: 6,
    threshold: 5,
    minCoverage: 0.95,
    systematicFloorAdu: 0.5,
    systematicFloorSource: 'Skotiq default',
  ),
  enabled: enabled,
  automaticCompletion: automaticCompletion,
);

DepthLockGoal _goal({
  String id = 'goal-1',
  int revision = 1,
  DepthLockGoalDefinition? definition,
  DepthLockReport? report,
  String? lastIssue,
}) => DepthLockGoal(
  id: id,
  revision: revision,
  definition: definition ?? _definition(),
  selectedAtMs: 1757000000000,
  evidenceFrames: report?.evidenceFrames ?? 0,
  evidenceRevision: 1,
  analysisCurrent: true,
  report: report,
  candidateFrames: 0,
  lastIssue: lastIssue,
  archivedRevisions: 0,
  estimatorVersion: 1,
);

ProviderContainer _container(
  _FakeDepthLockBackend backend, {
  Stream<SkotiqEvent>? events,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      depthLockBackendProvider.overrideWithValue(backend),
      depthLockEventStreamProvider.overrideWithValue(
        events ?? const Stream<SkotiqEvent>.empty(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

SkotiqEvent _event(String eventType) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.imaging,
  eventType: eventType,
  data: const <String, dynamic>{},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads the goal list from the backend', () async {
    final backend = _FakeDepthLockBackend(goals: <DepthLockGoal>[_goal()]);
    final container = _container(backend);

    final goals = await container.read(depthLockGoalsProvider.future);

    expect(goals, hasLength(1));
    expect(goals.single.id, 'goal-1');
    expect(backend.listCalls, 1);
  });

  test('create sends the definition and re-reads the list', () async {
    final backend = _FakeDepthLockBackend();
    final container = _container(backend);
    await container.read(depthLockGoalsProvider.future);

    final definition = _definition(label: 'Faint shell');
    await container
        .read(depthLockGoalsProvider.notifier)
        .createGoal(definition, goalId: 'goal-7');

    expect(backend.createdGoalId, 'goal-7');
    expect(backend.createdDefinition?.label, 'Faint shell');
    expect(backend.listCalls, 2);
    expect(container.read(depthLockGoalsProvider).value, hasLength(1));
  });

  test('revise carries the expected revision through unchanged', () async {
    final backend = _FakeDepthLockBackend(
      goals: <DepthLockGoal>[_goal(revision: 4)],
    );
    final container = _container(backend);
    await container.read(depthLockGoalsProvider.future);

    final goal = await container
        .read(depthLockGoalsProvider.notifier)
        .reviseGoal(
          goalId: 'goal-1',
          expectedRevision: 4,
          definition: _definition(label: 'Wider region'),
        );

    expect(backend.revised?.revision, 4);
    expect(backend.revised?.definition.label, 'Wider region');
    expect(goal.revision, 5);
  });

  test('preferences keep the revision and reach the backend', () async {
    final backend = _FakeDepthLockBackend(
      goals: <DepthLockGoal>[_goal(revision: 2)],
    );
    final container = _container(backend);
    await container.read(depthLockGoalsProvider.future);

    await container
        .read(depthLockGoalsProvider.notifier)
        .setPreferences(
          goalId: 'goal-1',
          expectedRevision: 2,
          enabled: true,
          automaticCompletion: true,
        );

    expect(backend.preferences?.revision, 2);
    expect(backend.preferences?.automatic, isTrue);
    final goals = container.read(depthLockGoalsProvider).value!;
    expect(goals.single.definition.automaticCompletion, isTrue);
    expect(goals.single.revision, 2);
  });

  test('remove and replay address the goal by id and revision', () async {
    final backend = _FakeDepthLockBackend(
      goals: <DepthLockGoal>[_goal(revision: 3)],
    );
    final container = _container(backend);
    await container.read(depthLockGoalsProvider.future);
    final notifier = container.read(depthLockGoalsProvider.notifier);

    await notifier.replayGoal('goal-1');
    expect(backend.replayed, 'goal-1');

    await notifier.removeGoal(goalId: 'goal-1', expectedRevision: 3);
    expect(backend.removed, (goalId: 'goal-1', revision: 3));
    expect(container.read(depthLockGoalsProvider).value, isEmpty);
  });

  test('ingest returns the outcome rather than raising it', () async {
    final backend = _FakeDepthLockBackend(goals: <DepthLockGoal>[_goal()]);
    final container = _container(backend);
    await container.read(depthLockGoalsProvider.future);

    final outcome = await container
        .read(depthLockGoalsProvider.notifier)
        .ingestFrame(goalId: 'goal-1', path: '/data/M51/L_0042.fits');

    expect(outcome.outcome, 'preSelection');
    expect(outcome.reason, contains('before this goal revision'));
    expect(backend.ingested?.path, '/data/M51/L_0042.fits');
  });

  test(
    'a backend refusal reaches the caller with its message intact',
    () async {
      final backend = _FakeDepthLockBackend();
      backend.nextError = const SkotiqError(
        category: BackendErrorCategory.validation,
        message: 'Background rectangle overlaps the signal rectangle',
      );
      final container = _container(backend);
      await container.read(depthLockGoalsProvider.future);

      await expectLater(
        container
            .read(depthLockGoalsProvider.notifier)
            .createGoal(_definition()),
        throwsA(
          isA<SkotiqError>().having(
            (error) => error.message,
            'message',
            'Background rectangle overlaps the signal rectangle',
          ),
        ),
      );
      // The failed create left the list alone: nothing was re-read, and the
      // panel keeps showing what the host actually holds.
      expect(backend.listCalls, 1);
    },
  );

  test('a DepthLock event refreshes the list', () async {
    final backend = _FakeDepthLockBackend(goals: <DepthLockGoal>[_goal()]);
    final events = StreamController<SkotiqEvent>.broadcast();
    addTearDown(events.close);
    final container = _container(backend, events: events.stream);
    await container.read(depthLockGoalsProvider.future);
    expect(backend.listCalls, 1);

    backend.goals = <DepthLockGoal>[
      _goal(),
      _goal(
        id: 'goal-2',
        definition: _definition(label: 'Second region'),
      ),
    ];
    events.add(_event('DepthLockGoalUpdated'));
    await pumpEventQueue();

    expect(backend.listCalls, 2);
    expect(container.read(depthLockGoalsProvider).value, hasLength(2));
  });

  test('an unrelated event does not refresh the list', () async {
    final backend = _FakeDepthLockBackend(goals: <DepthLockGoal>[_goal()]);
    final events = StreamController<SkotiqEvent>.broadcast();
    addTearDown(events.close);
    final container = _container(backend, events: events.stream);
    await container.read(depthLockGoalsProvider.future);

    events.add(_event('FrameAccepted'));
    await pumpEventQueue();

    expect(backend.listCalls, 1);
  });

  test('the DepthLock event predicate accepts both mapper spellings', () {
    expect(isDepthLockEvent(_event('DepthLockGoalUpdated')), isTrue);
    expect(isDepthLockEvent(_event('depthLock')), isTrue);
    expect(isDepthLockEvent(_event('SequencerFrameAccepted')), isFalse);
  });

  test('goals are selectable by filter and by target', () async {
    final backend = _FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        _goal(definition: _definition(filterName: 'L')),
        _goal(
          id: 'goal-2',
          definition: _definition(filterName: 'Ha'),
        ),
      ],
    );
    final container = _container(backend);
    await container.read(depthLockGoalsProvider.future);

    expect(container.read(depthLockGoalsForFilterProvider('ha')), hasLength(1));
    expect(
      container.read(depthLockGoalsForFilterProvider('ha')).single.id,
      'goal-2',
    );
    expect(
      container.read(depthLockGoalsForTargetProvider('target-1')),
      hasLength(2),
    );
    expect(container.read(depthLockGoalsForTargetProvider('nobody')), isEmpty);
  });

  test('the curve is read from the backend', () async {
    final backend = _FakeDepthLockBackend(goals: <DepthLockGoal>[_goal()]);
    final container = _container(backend);

    final points = await container.read(
      depthLockGoalCurveProvider('goal-1').future,
    );

    expect(points, hasLength(1));
    expect(points.single.frames, 32);
    expect(backend.curveCalls, 1);
  });

  test('a DepthLock event makes the curve stale too', () async {
    final backend = _FakeDepthLockBackend(goals: <DepthLockGoal>[_goal()]);
    final events = StreamController<SkotiqEvent>.broadcast();
    addTearDown(events.close);
    final container = _container(backend, events: events.stream);
    await container.read(depthLockGoalsProvider.future);
    await container.read(depthLockGoalCurveProvider('goal-1').future);
    expect(backend.curveCalls, 1);

    // The curve is derived from the same evidence, so a goal update has to
    // move it as well — otherwise the chart keeps yesterday's projection.
    backend.curve = const <DepthLockCurvePoint>[
      DepthLockCurvePoint(
        frames: 48,
        score: 4.0,
        conservativeScore: 3.2,
        projected: false,
      ),
    ];
    events.add(_event('DepthLockGoalUpdated'));
    await pumpEventQueue();

    final points = await container.read(
      depthLockGoalCurveProvider('goal-1').future,
    );
    expect(backend.curveCalls, 2);
    expect(points.single.frames, 48);
  });

  test('status comes from the backend', () async {
    final backend = _FakeDepthLockBackend();
    final container = _container(backend);

    final status = await container.read(depthLockStatusProvider.future);

    expect(status.available, isTrue);
    expect(status.evidenceRejected, 1);
  });
}

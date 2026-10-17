// MockBackend for skotiq_app widget tests.
//
// Why mocktail's `Mock` rather than a hand-rolled implements stub:
// `SkotiqBackend` is ~700 LoC of abstract method declarations. Restating
// every one of them just to throw `UnimplementedError` would (a) double the
// maintenance cost every time the interface grows and (b) be functionally
// indistinguishable from the noSuchMethod-based default mocktail gives us.
// Tests stub the specific methods they care about via `when(() => ...)` and
// rely on the default null/empty returns for the rest. Test authors who need
// loud failures on unmocked calls can wrap MockBackend in their own
// strict-mode subclass — the harness should not impose that policy.
//
// Why NOT delegate to `FakeNativeBridge` (the sibling agent's work):
// `FakeNativeBridge` lives at the FFI boundary one layer below `FfiBackend`.
// A test that wants to exercise the `SkotiqBackend` contract directly
// (e.g. `dashboardScreen` reading `backend.discoverDevices(...)`) needs a
// fake at the backend layer, not the bridge layer. An
// `FfiBackend(bridge: FakeNativeBridge(...))` construction is
// also available as a higher-fidelity alternative, but the cheap
// MockBackend remains useful for tests that only need a couple of stubs.

import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A mocktail-based [SkotiqBackend] stand-in for widget tests.
///
/// Returns null/empty/zero for any method that wasn't explicitly stubbed.
/// Use [stubDefaults] (or [mockBackend]) to wire up the streams `eventStream`
/// and `polarAlignmentEvents` — those are read by the framework code path
/// before the widget tree even renders, so leaving them un-stubbed throws.
///
/// Tests that need to drive backend events post-pump use [emitEvent] /
/// [emitPolarAlignmentEvent]. Those forward to internal broadcast controllers
/// that the harness wires into the mocked stream getters; widgets listening
/// to `backend.eventStream` will see whatever the test pushes here.
class MockBackend extends Mock implements SkotiqBackend {
  // Why nullable + late-bound: the controllers are owned by [mockBackend]
  // (the factory), not the constructor — mocktail's `Mock` requires a
  // zero-arg constructor and adding a constructor argument here would
  // require every existing test that does `class MyMock extends MockBackend`
  // to forward it. The factory assigns these immediately after
  // construction; calls to [emitEvent] before that point throw a clear
  // StateError instead of producing silent no-ops.
  StreamController<SkotiqEvent>? _eventController;
  StreamController<Map<String, dynamic>>? _polarAlignController;

  /// Push a [SkotiqEvent] onto the mocked `eventStream`.
  ///
  /// Throws [StateError] if the backend was constructed directly rather than
  /// via [mockBackend] — without the factory's wiring there is no controller
  /// to push to and silently no-op'ing would hide bugs.
  void emitEvent(SkotiqEvent event) {
    final c = _eventController;
    if (c == null) {
      throw StateError(
        'MockBackend.emitEvent called before the event controller was wired. '
        'Construct via mockBackend() instead of `MockBackend()` directly.',
      );
    }
    c.add(event);
  }

  /// Push a polar-alignment data frame onto `polarAlignmentEvents`.
  ///
  /// Same wiring contract as [emitEvent]; see that doc comment.
  void emitPolarAlignmentEvent(Map<String, dynamic> event) {
    final c = _polarAlignController;
    if (c == null) {
      throw StateError(
        'MockBackend.emitPolarAlignmentEvent called before the controller '
        'was wired. Construct via mockBackend() instead of `MockBackend()` '
        'directly.',
      );
    }
    c.add(event);
  }
}

/// Build a [MockBackend] with the minimum stubs every widget test needs:
///
/// - `eventStream` -> broadcast stream backed by an internal controller that
///   [MockBackend.emitEvent] forwards to.
/// - `polarAlignmentEvents` -> broadcast stream backed by an internal
///   controller that [MockBackend.emitPolarAlignmentEvent] forwards to.
/// - `dispose` -> closes both controllers (called when the harness tears
///   down).
///
/// Tests that need richer behaviour can chain additional `when(...)` calls
/// on the returned mock:
///
/// ```dart
/// final backend = mockBackend();
/// when(() => backend.getConnectedDevices()).thenAnswer(
///   (_) async => [DeviceInfo(id: 'cam-1', ...)],
/// );
/// // Later, drive an event onto the stream:
/// backend.emitEvent(SkotiqEvent(
///   timestamp: 0,
///   severity: EventSeverity.error,
///   category: EventCategory.equipment,
///   eventType: 'camera_fault',
///   data: const {'message': 'shutter stuck'},
/// ));
/// ```
MockBackend mockBackend() {
  final backend = MockBackend();
  // Why broadcast: the production backends expose broadcast streams and
  // several widgets subscribe more than once (e.g. a controller + a status
  // chip). A single-subscription stream would throw on the second listen.
  final eventController = StreamController<SkotiqEvent>.broadcast();
  final polarAlignController =
      StreamController<Map<String, dynamic>>.broadcast();
  // Why assign-then-stub: tests call backend.emitEvent(...) directly via
  // the instance, and stream listeners read the same controllers' .stream
  // through the mocked getters. Keeping both pointed at the same controller
  // is what makes the round-trip work.
  backend._eventController = eventController;
  backend._polarAlignController = polarAlignController;

  when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
  when(() => backend.polarAlignmentEvents)
      .thenAnswer((_) => polarAlignController.stream);
  // PluginNodeAvailabilityRule reads this getter on every live-validation
  // pass; an unstubbed mocktail bool getter returns null and type-errors the
  // whole validation run (which broke every sequencer-screen widget test).
  // `true` matches the local FFI backend the harness stands in for.
  when(() => backend.dispatchPluginNodesLocally).thenReturn(true);
  // The sequencer toolbar's SIMULATION badge reads this on every build. An
  // unstubbed mocktail method returns null, which type-errors the read into
  // an error state the badge then treats as "no claim" — the badge would be
  // right by accident. `false` is what the harness backend actually drives:
  // it installs no simulated device ops.
  when(() => backend.sequencerIsSimulationMode())
      .thenAnswer((_) async => false);
  // dispose() returns void; mocktail won't auto-stub void getters/setters but
  // void methods are fine. Still, set up explicitly so `verify(() => ...)`
  // works for tests that want to assert disposal.
  when(() => backend.dispose()).thenAnswer((_) {
    eventController.close();
    polarAlignController.close();
  });

  return backend;
}

/// An in-memory DepthLock goal store for a [MockBackend].
///
/// Widget and provider tests need goals that behave like the native store —
/// a create assigns revision 1, a revise advances it, a stale expected
/// revision is refused — without standing up the FFI. The refusals use the
/// same sentences `depthlock_service/store.rs` raises, so a test that asserts
/// on an error message is asserting on the real text.
class InMemoryDepthLockGoals {
  InMemoryDepthLockGoals([Iterable<DepthLockGoal> seed = const []]) {
    for (final goal in seed) {
      goals[goal.id] = goal;
    }
  }

  final Map<String, DepthLockGoal> goals = {};
  final List<String> ingestedPaths = [];
  int _generated = 0;

  Never _missing(String goalId) =>
      throw StateError('DepthLock goal $goalId does not exist');

  DepthLockGoal _require(String goalId, int expectedRevision) {
    final goal = goals[goalId];
    if (goal == null) _missing(goalId);
    if (goal.revision != expectedRevision) {
      throw StateError('stale revision for DepthLock goal $goalId');
    }
    return goal;
  }

  DepthLockGoal create(DepthLockGoalDefinition definition, {String? goalId}) {
    final id = goalId ?? 'goal-${++_generated}';
    final goal = depthLockGoalFixture(id: id, definition: definition);
    goals[id] = goal;
    return goal;
  }

  DepthLockGoal revise({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  }) {
    final previous = _require(goalId, expectedRevision);
    // A revision archives the old one and starts the evidence over, which is
    // what makes a stale expected revision worth refusing.
    final goal = depthLockGoalFixture(
      id: goalId,
      revision: previous.revision + 1,
      definition: definition,
    );
    goals[goalId] = goal;
    return goal;
  }

  DepthLockGoal setPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) {
    final previous = _require(goalId, expectedRevision);
    // Preferences leave the revision alone: the evidence they govern stays
    // attributed to the revision that gathered it.
    final goal = depthLockGoalFixture(
      id: goalId,
      revision: previous.revision,
      definition: previous.definition.copyWith(
        enabled: enabled,
        automaticCompletion: automaticCompletion,
      ),
      report: previous.report,
      evidenceFrames: previous.evidenceFrames,
    );
    goals[goalId] = goal;
    return goal;
  }

  void remove({required String goalId, required int expectedRevision}) {
    _require(goalId, expectedRevision);
    goals.remove(goalId);
  }

  DepthLockGoal read(String goalId) => goals[goalId] ?? _missing(goalId);
}

/// A goal with every required field filled in. Tests override only what the
/// case is about.
DepthLockGoal depthLockGoalFixture({
  String id = 'goal-1',
  int revision = 1,
  DepthLockGoalDefinition? definition,
  DepthLockReport? report,
  int evidenceFrames = 0,
}) =>
    DepthLockGoal(
      id: id,
      revision: revision,
      definition: definition ?? depthLockDefinitionFixture(),
      selectedAtMs: 1757000000000,
      evidenceFrames: evidenceFrames,
      evidenceRevision: revision,
      analysisCurrent: true,
      report: report,
      candidateFrames: 0,
      archivedRevisions: revision - 1,
      estimatorVersion: 1,
    );

/// A complete goal definition; [filterName] and [threshold] are the two a
/// test usually cares about.
DepthLockGoalDefinition depthLockDefinitionFixture({
  String label = 'Depth goal',
  String filterName = 'Ha',
  double threshold = 12,
  bool enabled = true,
  bool automaticCompletion = true,
}) =>
    DepthLockGoalDefinition(
      label: label,
      projectId: 'project-1',
      targetId: 'target-1',
      profileId: 'profile-1',
      filterName: filterName,
      filterIndex: 0,
      referencePath: '/data/reference.fits',
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
        instrument: 'Test Camera',
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

/// Wire [backend]'s DepthLock role onto an in-memory store and return it, so
/// a test can seed goals and then assert on what the UI did to them.
InMemoryDepthLockGoals stubDepthLockGoals(
  MockBackend backend, {
  Iterable<DepthLockGoal> seed = const [],
}) {
  registerFallbackValue(depthLockDefinitionFixture());
  registerFallbackValue(depthLockDefinitionFixture().measurement);
  registerFallbackValue(depthLockDefinitionFixture().reference);
  final store = InMemoryDepthLockGoals(seed);

  when(() => backend.depthLockStatus()).thenAnswer(
    (_) async => DepthLockStatus(
      available: true,
      goals: store.goals.length,
      queueCapacity: 16,
      queued: 0,
      processed: 0,
      dropped: 0,
      evidenceAdded: 0,
      evidenceRejected: 0,
      lastFrameMs: 0,
      maxFrameMs: 0,
    ),
  );
  when(
    () => backend.listDepthLockGoals(),
  ).thenAnswer((_) async => store.goals.values.toList(growable: false));
  when(() => backend.getDepthLockGoal(any())).thenAnswer(
    (invocation) async =>
        store.read(invocation.positionalArguments.first as String),
  );
  when(
    () => backend.createDepthLockGoal(any(), goalId: any(named: 'goalId')),
  ).thenAnswer(
    (invocation) async => store.create(
      invocation.positionalArguments.first as DepthLockGoalDefinition,
      goalId: invocation.namedArguments[#goalId] as String?,
    ),
  );
  when(
    () => backend.reviseDepthLockGoal(
      goalId: any(named: 'goalId'),
      expectedRevision: any(named: 'expectedRevision'),
      definition: any(named: 'definition'),
    ),
  ).thenAnswer(
    (invocation) async => store.revise(
      goalId: invocation.namedArguments[#goalId] as String,
      expectedRevision: invocation.namedArguments[#expectedRevision] as int,
      definition:
          invocation.namedArguments[#definition] as DepthLockGoalDefinition,
    ),
  );
  when(
    () => backend.setDepthLockGoalPreferences(
      goalId: any(named: 'goalId'),
      expectedRevision: any(named: 'expectedRevision'),
      enabled: any(named: 'enabled'),
      automaticCompletion: any(named: 'automaticCompletion'),
    ),
  ).thenAnswer(
    (invocation) async => store.setPreferences(
      goalId: invocation.namedArguments[#goalId] as String,
      expectedRevision: invocation.namedArguments[#expectedRevision] as int,
      enabled: invocation.namedArguments[#enabled] as bool,
      automaticCompletion:
          invocation.namedArguments[#automaticCompletion] as bool,
    ),
  );
  when(
    () => backend.removeDepthLockGoal(
      goalId: any(named: 'goalId'),
      expectedRevision: any(named: 'expectedRevision'),
    ),
  ).thenAnswer(
    (invocation) async => store.remove(
      goalId: invocation.namedArguments[#goalId] as String,
      expectedRevision: invocation.namedArguments[#expectedRevision] as int,
    ),
  );
  when(
    () => backend.ingestDepthLockFrame(
      goalId: any(named: 'goalId'),
      path: any(named: 'path'),
    ),
  ).thenAnswer((invocation) async {
    store.read(invocation.namedArguments[#goalId] as String);
    store.ingestedPaths.add(invocation.namedArguments[#path] as String);
    return const DepthLockIngestOutcome(
      outcome: 'added',
      state: DepthLockState.collecting,
      reason: 'evidence accepted',
    );
  });
  when(() => backend.replayDepthLockGoal(any())).thenAnswer(
    (invocation) async =>
        store.read(invocation.positionalArguments.first as String),
  );
  when(() => backend.inspectDepthLockReference(any())).thenAnswer(
    (_) async => DepthLockReferenceInfo(
      width: 4144,
      height: 2822,
      pixelType: 'u16',
      monochrome: true,
      geometry: depthLockDefinitionFixture().reference,
      pixelScaleArcsec: 0.72,
      acquisition: depthLockDefinitionFixture().acquisition,
    ),
  );
  when(
    () => backend.depthLockSkyRectangle(
      reference: any(named: 'reference'),
      x0: any(named: 'x0'),
      y0: any(named: 'y0'),
      x1: any(named: 'x1'),
      y1: any(named: 'y1'),
    ),
  ).thenAnswer(
    (_) async => depthLockDefinitionFixture().measurement.region,
  );
  when(() => backend.checkDepthLockMeasurement(any()))
      .thenAnswer((_) async => 2400);
  when(
    () => backend.suggestDepthLockFloor(
      referencePath: any(named: 'referencePath'),
      darkPath: any(named: 'darkPath'),
      flatPath: any(named: 'flatPath'),
      scaleArcsec: any(named: 'scaleArcsec'),
      pixelScaleArcsec: any(named: 'pixelScaleArcsec'),
    ),
  ).thenAnswer((_) async => depthLockFloorSuggestionFixture());
  when(
    () => backend.depthLockGoalCurve(any(), maxPoints: any(named: 'maxPoints')),
  ).thenAnswer(
    (invocation) async => depthLockCurveFixture(
        store.read(invocation.positionalArguments.first as String)),
  );

  return store;
}

/// A short curve for [goal]: a few measured points climbing toward the
/// threshold, then a few projected ones crossing it. Enough shape for a chart
/// to render something honest without pretending to be the real estimator.
List<DepthLockCurvePoint> depthLockCurveFixture(DepthLockGoal goal) {
  final threshold = goal.definition.measurement.threshold;
  return <DepthLockCurvePoint>[
    for (var frames = 4; frames <= 12; frames += 4)
      DepthLockCurvePoint(
        frames: frames,
        score: threshold * 0.6 * (frames / 12),
        conservativeScore: threshold * 0.5 * (frames / 12),
        projected: false,
      ),
    for (var frames = 16; frames <= 24; frames += 4)
      DepthLockCurvePoint(
        frames: frames,
        score: threshold * (frames / 20),
        conservativeScore: threshold * 0.9 * (frames / 20),
        projected: true,
      ),
  ];
}

/// A measured systematic floor, as the native estimator reports one.
DepthLockFloorSuggestion depthLockFloorSuggestionFixture({
  double floorAdu = 0.42,
}) =>
    DepthLockFloorSuggestion(
      floorAdu: floorAdu,
      darkNoiseAdu: 0.31,
      flatRelativeNoise: 0.0018,
      skyAdu: 1240,
      aperturePixels: 69.4,
      source: 'measured from the reference light and its masters',
    );

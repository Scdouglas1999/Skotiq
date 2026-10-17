import 'dart:async';
import 'dart:typed_data';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart';
import 'package:skotiq_core/src/models/depthlock/depthlock_models.dart';

/// Mock implementation of SkotiqBackend for testing
class MockBackend extends Mock implements SkotiqBackend {}

/// Test fixtures and helper data for common test scenarios
class TestFixtures {
  // Every device id passes `isValidDeviceIdFormat` so the
  // connect-precondition format check accepts these in unit tests. Using
  // the `simulator:` prefix keeps the fixtures recognisable as test data
  // while still matching one of the known driver-prefix conventions.

  /// Default camera device ID
  static const String cameraId = 'simulator:test-camera-1';

  /// Default mount device ID
  static const String mountId = 'simulator:test-mount-1';

  /// Default focuser device ID
  static const String focuserId = 'simulator:test-focuser-1';

  /// Default filter wheel device ID
  static const String filterWheelId = 'simulator:test-filterwheel-1';

  /// Default dome device ID
  static const String domeId = 'simulator:test-dome-1';

  /// Default weather device ID
  static const String weatherId = 'simulator:test-weather-1';

  /// Default safety monitor device ID
  static const String safetyMonitorId = 'simulator:test-safety-1';

  /// Default switch device ID
  static const String switchId = 'simulator:test-switch-1';

  /// Sample image statistics
  static const ImageStats sampleImageStats = ImageStats(
    mean: 1500.0,
    median: 1450.0,
    stdDev: 250.0,
    min: 100.0,
    max: 65535.0,
    mad: 200.0,
    snr: 6.0,
    starCount: 125,
    hfr: 2.5,
    fwhm: 3.2,
  );

  /// Sample exposure settings
  static const ExposureSettings sampleExposureSettings = ExposureSettings(
    exposureTime: 120.0,
    gain: 100,
    offset: 50,
    binningX: 1,
    binningY: 1,
    frameType: FrameType.light,
  );

  /// Sample equipment profile
  static EquipmentProfile sampleProfile() {
    return EquipmentProfile(
      id: 'test-profile-1',
      name: 'Test Equipment Profile',
      cameraId: cameraId,
      mountId: mountId,
      focuserId: focuserId,
      filterWheelId: filterWheelId,
      rotatorId: null,
      domeId: null,
      weatherId: null,
      coverCalibratorId: null,
      isActive: true,
      updatedAt: DateTime(2024, 1, 1),
    );
  }

  /// Sample 16-bit grayscale image data (100x100 pixels)
  static Uint16List sampleImageData() {
    final data = Uint16List(100 * 100);
    // Create a simple gradient pattern
    for (int y = 0; y < 100; y++) {
      for (int x = 0; x < 100; x++) {
        final index = y * 100 + x;
        // Create a gradient from 1000 to 2000 ADU
        data[index] = 1000 + ((x + y) * 5);
      }
    }
    return data;
  }

  /// Sample filter names
  static const List<String> sampleFilterNames = [
    'Luminance',
    'Red',
    'Green',
    'Blue',
    'Ha',
    'OIII',
    'SII',
  ];

  /// Creates a mock backend with default successful responses
  static MockBackend createMockBackendWithDefaults() {
    final backend = MockBackend();

    // Setup default successful connection responses
    when(() => backend.connectDevice(any(), any())).thenAnswer((_) async {});
    when(() => backend.disconnectDevice(any(), any())).thenAnswer((_) async {});

    // Setup default event stream (empty stream)
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());

    return backend;
  }

  /// Creates a mock backend that simulates connection failures
  static MockBackend createMockBackendWithConnectionFailure() {
    final backend = MockBackend();

    // All connection attempts fail
    when(
      () => backend.connectDevice(any(), any()),
    ).thenThrow(Exception('Failed to connect to device'));

    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());

    return backend;
  }

  /// Creates a mock backend that simulates timeout errors
  static MockBackend createMockBackendWithTimeout() {
    final backend = MockBackend();

    // All operations timeout
    when(
      () => backend.connectDevice(any(), any()),
    ).thenThrow(Exception('Connection timeout'));

    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());

    return backend;
  }
}

/// Register mocktail fallback values for testing
void registerMocktailFallbackValues() {
  registerFallbackValue(FrameType.light);
  registerFallbackValue(DeviceType.camera);
  registerFallbackValue(DriverType.simulator);
  registerFallbackValue(
    const ExposureSettings(
      exposureTime: 1.0,
      gain: 0,
      offset: 0,
      binningX: 1,
      binningY: 1,
      frameType: FrameType.light,
    ),
  );
  registerFallbackValue(
    const DeviceInfo(
      id: 'fallback',
      name: 'Fallback',
      deviceType: DeviceType.camera,
      driverType: DriverType.simulator,
      description: '',
      driverVersion: '1.0',
    ),
  );
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
}) => DepthLockGoal(
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
}) => DepthLockGoalDefinition(
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
  ).thenAnswer((_) async => depthLockDefinitionFixture().measurement.region);
  when(
    () => backend.checkDepthLockMeasurement(any()),
  ).thenAnswer((_) async => 2400);
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
      store.read(invocation.positionalArguments.first as String),
    ),
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
}) => DepthLockFloorSuggestion(
  floorAdu: floorAdu,
  darkNoiseAdu: 0.31,
  flatRelativeNoise: 0.0018,
  skyAdu: 1240,
  aperturePixels: 69.4,
  source: 'measured from the reference light and its masters',
);

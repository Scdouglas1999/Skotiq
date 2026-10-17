import 'package:skotiq_core/skotiq_core.dart';

/// A scripted [DepthLockBackend] for the DepthLock widget tests.
///
/// The app's shared mock backend is owned by the backend plumbing, so the UI
/// tests bring their own: they only need the DepthLock role, and they need to
/// assert on the exact arguments each control sends.
class FakeDepthLockBackend implements DepthLockBackend {
  FakeDepthLockBackend({List<DepthLockGoal>? goals})
      : goals = goals ?? <DepthLockGoal>[];

  List<DepthLockGoal> goals;

  /// Answer for `checkDepthLockMeasurement`; when [checkError] is set it is
  /// thrown instead.
  int checkApertures = 256;
  Object? checkError;

  /// Raised by the next create/revise instead of answering.
  Object? mutationError;

  /// Answer for `suggestDepthLockFloor`; when [floorError] is set it is
  /// thrown instead.
  DepthLockFloorSuggestion floorSuggestion = const DepthLockFloorSuggestion(
    floorAdu: 0.42,
    darkNoiseAdu: 1.8,
    flatRelativeNoise: 0.0032,
    skyAdu: 640,
    aperturePixels: 9.6,
    source: 'Derived from master dark and flat at 10.0 arcsec apertures',
  );
  Object? floorError;
  double? lastFloorScaleArcsec;

  /// Answer for `inspectDepthLockReference`; when [referenceError] is set it
  /// is thrown instead.
  DepthLockReferenceInfo? referenceInfo;
  Object? referenceError;
  final List<String> inspectedPaths = <String>[];

  /// Answer for `depthLockGoalCurve`; when [curveError] is set it is thrown.
  List<DepthLockCurvePoint> curve = const <DepthLockCurvePoint>[];
  Object? curveError;
  int curveCalls = 0;

  DepthLockGoalDefinition? createdDefinition;
  DepthLockMeasurement? lastChecked;
  ({String goalId, int revision, DepthLockGoalDefinition definition})? revised;
  ({String goalId, int revision, bool enabled, bool automatic})? preferences;
  ({String goalId, int revision})? removed;
  String? replayed;
  final List<String> ingestedPaths = <String>[];

  @override
  Future<List<DepthLockGoal>> listDepthLockGoals() async =>
      List<DepthLockGoal>.unmodifiable(goals);

  @override
  Future<DepthLockGoal> getDepthLockGoal(String goalId) async =>
      goals.firstWhere((goal) => goal.id == goalId);

  @override
  Future<int> checkDepthLockMeasurement(
    DepthLockMeasurement measurement,
  ) async {
    lastChecked = measurement;
    final error = checkError;
    if (error != null) throw error;
    return checkApertures;
  }

  @override
  Future<DepthLockGoal> createDepthLockGoal(
    DepthLockGoalDefinition definition, {
    String? goalId,
  }) async {
    final error = mutationError;
    if (error != null) throw error;
    createdDefinition = definition;
    final goal = depthLockGoalFixture(
      id: goalId ?? 'created',
      definition: definition,
    );
    goals = <DepthLockGoal>[...goals, goal];
    return goal;
  }

  @override
  Future<DepthLockGoal> reviseDepthLockGoal({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  }) async {
    final error = mutationError;
    if (error != null) throw error;
    revised = (
      goalId: goalId,
      revision: expectedRevision,
      definition: definition,
    );
    return depthLockGoalFixture(
      id: goalId,
      revision: expectedRevision + 1,
      definition: definition,
    );
  }

  @override
  Future<DepthLockGoal> setDepthLockGoalPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) async {
    preferences = (
      goalId: goalId,
      revision: expectedRevision,
      enabled: enabled,
      automatic: automaticCompletion,
    );
    final previous = goals.firstWhere((goal) => goal.id == goalId);
    final goal = depthLockGoalFixture(
      id: goalId,
      revision: previous.revision,
      report: previous.report,
      lastIssue: previous.lastIssue,
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
    removed = (goalId: goalId, revision: expectedRevision);
    goals = goals.where((goal) => goal.id != goalId).toList();
  }

  @override
  Future<DepthLockGoal> replayDepthLockGoal(String goalId) async {
    replayed = goalId;
    return goals.firstWhere((goal) => goal.id == goalId);
  }

  @override
  Future<DepthLockIngestOutcome> ingestDepthLockFrame({
    required String goalId,
    required String path,
  }) async {
    ingestedPaths.add(path);
    return const DepthLockIngestOutcome(outcome: 'added');
  }

  @override
  Future<List<DepthLockCurvePoint>> depthLockGoalCurve(
    String goalId, {
    int maxPoints = 60,
  }) async {
    curveCalls++;
    final error = curveError;
    if (error != null) throw error;
    return curve;
  }

  @override
  Future<DepthLockFloorSuggestion> suggestDepthLockFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  }) async {
    lastFloorScaleArcsec = scaleArcsec;
    final error = floorError;
    if (error != null) throw error;
    return floorSuggestion;
  }

  @override
  Future<DepthLockStatus> depthLockStatus() async => const DepthLockStatus(
        available: true,
        goals: 0,
        queueCapacity: 32,
        queued: 0,
        processed: 0,
        dropped: 0,
        evidenceAdded: 0,
        evidenceRejected: 0,
        lastFrameMs: 0,
        maxFrameMs: 0,
      );

  @override
  Future<DepthLockReferenceInfo> inspectDepthLockReference(String path) async {
    inspectedPaths.add(path);
    final error = referenceError;
    if (error != null) throw error;
    final info = referenceInfo;
    if (info == null) throw UnimplementedError();
    return info;
  }

  @override
  Future<SkyRectangle> depthLockSkyRectangle({
    required ReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async =>
      throw UnimplementedError();
}

const SkyRectangle depthLockRegionFixture = SkyRectangle(
  raDeg: 202.4696,
  decDeg: 47.1952,
  widthArcsec: 120,
  heightArcsec: 120,
  rotationDeg: 0,
);

const SkyRectangle depthLockBackgroundFixture = SkyRectangle(
  raDeg: 202.5196,
  decDeg: 47.2152,
  widthArcsec: 120,
  heightArcsec: 120,
  rotationDeg: 0,
);

const ReferenceGeometry depthLockGeometryFixture = ReferenceGeometry(
  width: 4144,
  height: 2822,
  crval1: 202.4696,
  crval2: 47.1952,
  crpix1: 2073.0,
  crpix2: 1412.0,
  cd1_1: 0.000289,
  cd1_2: 0,
  cd2_1: 0,
  cd2_2: -0.000289,
);

const AcquisitionSettings depthLockAcquisitionFixture = AcquisitionSettings(
  instrument: 'ZWO ASI2600MM Pro',
  filter: 'L',
  exposureSecs: 300,
  binX: 1,
  binY: 1,
  gain: 100,
  offset: 50,
  ccdTempC: -10,
);

DepthLockGoalDefinition depthLockDefinitionFixture({
  String label = 'Tidal tail',
  String filterName = 'L',
  double scaleArcsec = 7.5,
  double threshold = 5,
  bool enabled = true,
  bool automaticCompletion = false,
}) =>
    DepthLockGoalDefinition(
      label: label,
      projectId: 'project-1',
      targetId: 'target-1',
      profileId: 'profile-1',
      filterName: filterName,
      filterIndex: 0,
      referencePath: '/data/M51/L_0001.fits',
      reference: depthLockGeometryFixture,
      acquisition: depthLockAcquisitionFixture,
      temperatureToleranceC: 1,
      darkPath: '/data/masters/dark.fits',
      flatPath: '/data/masters/flat.fits',
      measurement: DepthLockMeasurement(
        region: depthLockRegionFixture,
        background: depthLockBackgroundFixture,
        scaleArcsec: scaleArcsec,
        threshold: threshold,
        minCoverage: 0.9,
        systematicFloorAdu: 0.5,
        systematicFloorSource: 'Master residuals, 2026-09-01',
      ),
      enabled: enabled,
      automaticCompletion: automaticCompletion,
    );

DepthLockForecast depthLockForecastFixture({
  int framesToThreshold = 18,
  int framesToConfirm = 16,
  bool reachable = true,
  double ceilingScore = 4.1,
  double perFrameNoiseAdu = 2.4,
  double recentFrameNoiseAdu = 2.4,
  double bestFrameNoiseAdu = 2.4,
}) =>
    DepthLockForecast(
      framesToThreshold: framesToThreshold,
      framesToConfirm: framesToConfirm,
      reachable: reachable,
      ceilingScore: ceilingScore,
      perFrameNoiseAdu: perFrameNoiseAdu,
      recentFrameNoiseAdu: recentFrameNoiseAdu,
      bestFrameNoiseAdu: bestFrameNoiseAdu,
    );

DepthLockReport depthLockReportFixture({
  DepthLockState state = DepthLockState.collecting,
  double? score = 4.2,
  double? conservativeScore = 3.6,
  double? uncertaintyAdu = 0.31,
  double coverage = 0.9375,
  int evidenceFrames = 48,
  int confirmationFrames = 0,
  String reason = 'Measuring.',
  DepthLockForecast? forecast,
}) =>
    DepthLockReport(
      state: state,
      score: score,
      conservativeScore: conservativeScore,
      uncertaintyAdu: uncertaintyAdu,
      coverage: coverage,
      evidenceFrames: evidenceFrames,
      confirmationFrames: confirmationFrames,
      reason: reason,
      forecast: forecast,
    );

DepthLockGoal depthLockGoalFixture({
  String id = 'goal-1',
  int revision = 3,
  DepthLockGoalDefinition? definition,
  DepthLockReport? report,
  String? lastIssue,
  bool analysisCurrent = true,
  int candidateFrames = 0,
}) =>
    DepthLockGoal(
      id: id,
      revision: revision,
      definition: definition ?? depthLockDefinitionFixture(),
      // Local time on purpose: the panel renders the selection stamp in the
      // operator's own clock, so a UTC fixture would assert a different string on
      // every machine.
      selectedAtMs: DateTime(2026, 9, 1, 21, 40).millisecondsSinceEpoch,
      evidenceFrames: report?.evidenceFrames ?? 0,
      evidenceRevision: revision,
      analysisCurrent: analysisCurrent,
      report: report,
      candidateFrames: candidateFrames,
      lastIssue: lastIssue,
      archivedRevisions: 0,
      estimatorVersion: 1,
    );

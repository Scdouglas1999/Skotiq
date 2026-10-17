import '../../models/depthlock/depthlock_models.dart';

/// DepthLock: persistent per-filter depth goals around a marked sky region.
///
/// Every mutation carries the caller's expected revision and fails when the
/// goal has moved on, so two clients editing one goal cannot silently
/// overwrite each other. The native side owns measurement and the verdict
/// the sequencer consumes; this role only defines, inspects and replays.
abstract class DepthLockBackend {
  /// Analysis-queue health and whether the goal store is available.
  Future<DepthLockStatus> depthLockStatus();

  Future<List<DepthLockGoal>> listDepthLockGoals();

  Future<DepthLockGoal> getDepthLockGoal(String goalId);

  /// Create a goal. Its selection timestamp is now: only exposures started
  /// after this call become evidence, so the image the region was drawn on
  /// stays discovery data. [goalId] may be omitted to have one generated.
  Future<DepthLockGoal> createDepthLockGoal(
    DepthLockGoalDefinition definition, {
    String? goalId,
  });

  /// Replace a goal's definition. This is a new revision: the earlier one
  /// is archived and evidence starts over.
  Future<DepthLockGoal> reviseDepthLockGoal({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  });

  /// Turn ingestion and automatic completion on or off without disturbing
  /// the revision or its evidence.
  Future<DepthLockGoal> setDepthLockGoalPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  });

  Future<void> removeDepthLockGoal({
    required String goalId,
    required int expectedRevision,
  });

  /// Describe a candidate reference frame (geometry from its header when it
  /// carries an undistorted TAN solution, plus its acquisition settings).
  Future<DepthLockReferenceInfo> inspectDepthLockReference(String path);

  /// Convert a rectangle drawn on the reference image (0-based pixel
  /// corners, any order) into the sky rectangle a goal stores.
  Future<SkyRectangle> depthLockSkyRectangle({
    required ReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  });

  /// Validate a measurement definition without creating anything. Returns
  /// the number of apertures the region yields; throws with the native
  /// refusal reason otherwise.
  Future<int> checkDepthLockMeasurement(DepthLockMeasurement measurement);

  /// Offer one saved light to one goal and wait for the outcome. Archival
  /// frames acquired before the goal's selection are reported as
  /// `preSelection`, never counted.
  Future<DepthLockIngestOutcome> ingestDepthLockFrame({
    required String goalId,
    required String path,
  });

  /// Re-evaluate a goal over the evidence it already holds.
  Future<DepthLockGoal> replayDepthLockGoal(String goalId);

  /// The goal's score after each prefix of its evidence (about [maxPoints]
  /// measured points), followed by the noise model's projection to the
  /// forecast crossing. Display only; nothing here changes a verdict.
  Future<List<DepthLockCurvePoint>> depthLockGoalCurve(
    String goalId, {
    int maxPoints = 60,
  });

  /// Derive the systematic error floor from the reference light and the
  /// two masters at [scaleArcsec]. [pixelScaleArcsec] is the reference's
  /// native scale when the caller resolved the geometry from its own
  /// records; omitted, it is read from the file's TAN header.
  Future<DepthLockFloorSuggestion> suggestDepthLockFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  });
}

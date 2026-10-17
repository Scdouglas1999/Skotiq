// Fail-closed profile, settings, image, polar-alignment, and heartbeat
// overrides.
part of '../disconnected_backend.dart';

mixin _DisconnectedBackendProfileAndImage on Object
    implements SkotiqBackend {
  Never _throwNotConnected();

  @override
  Future<List<EquipmentProfile>> getProfiles() async {
    _throwNotConnected();
  }

  @override
  Future<void> saveProfile(EquipmentProfile profile) async {
    _throwNotConnected();
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    _throwNotConnected();
  }

  @override
  Future<void> loadProfile(String profileId) async {
    _throwNotConnected();
  }

  @override
  Future<EquipmentProfile?> getActiveProfile() async {
    _throwNotConnected();
  }

  @override
  Future<models.AppSettings> getSettings() async {
    _throwNotConnected();
  }

  @override
  Future<void> updateSettings(models.AppSettings settings) async {
    _throwNotConnected();
  }

  @override
  Future<models.ObserverLocation?> getLocation() async {
    _throwNotConnected();
  }

  @override
  Future<void> setLocation(models.ObserverLocation? location) async {
    _throwNotConnected();
  }

  @override
  Future<List<StarCrop>> getStarCropsFromLastImage(
    String deviceId, {
    int maxCrops = 5,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<PlateSolverDetection> detectPlateSolvers() async {
    _throwNotConnected();
  }

  @override
  Future<PlateSolverInfo> verifyPlateSolver(String executablePath) async {
    _throwNotConnected();
  }

  @override
  Future<PlateSolverPreference> getPlateSolverConfig() async {
    _throwNotConnected();
  }

  @override
  Future<void> setPlateSolverConfig(PlateSolverPreference pref) async {
    _throwNotConnected();
  }

  @override
  Future<void> calibrateImageFile({
    required String lightPath,
    String? darkPath,
    String? flatPath,
    String? biasPath,
    required String outputPath,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<FitsReadResult> readFitsFile({required String filePath}) async {
    _throwNotConnected();
  }

  @override
  Uint8List autoStretchImage({
    required int width,
    required int height,
    required List<int> data,
  }) {
    _throwNotConnected();
  }

  @override
  Future<void> renderFinishingPreview({
    required String inputFits,
    required String outputPng,
  }) async {
    _throwNotConnected();
  }

  // Polar alignment

  final _polarAlignController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents =>
      _polarAlignController.stream;

  @override
  Future<void> startPolarAlignment({
    required double exposureTime,
    required double stepSize,
    required int binning,
    required bool isNorth,
    required bool manualRotation,
    required bool rotateEast,
    int? gain,
    int? offset,
    double? solveTimeout,
    bool? startFromCurrent,
    double? autoCompleteThreshold,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> stopPolarAlignment() async {
    _throwNotConnected();
  }

  @override
  Future<void> startAllSkyPolarAlignment({
    required double exposureTime,
    required double solveTimeout,
    required int binning,
    required bool isNorth,
    required double acceptanceThresholdArcsec,
    required double iterationCadenceSecs,
    int? gain,
    int? offset,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<List<CapturedImage>> getSessionImages(int sessionId) async {
    _throwNotConnected();
  }

  @override
  Future<Uint8List> getImageThumbnail(int imageId) async {
    _throwNotConnected();
  }

  @override
  Future<void> downloadImage(
    int imageId,
    String localPath, {
    void Function(double)? onProgress,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<List<int>> getLastRawImageData(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> clearDeviceImage(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<void> startDeviceHeartbeat({
    required DeviceType deviceType,
    required String deviceId,
    required int intervalMs,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> stopDeviceHeartbeat(String deviceId) async {
    _throwNotConnected();
  }

  @override
  Future<(int, bool)> getDeviceHealth(String deviceId) async {
    _throwNotConnected();
  }

  // DepthLock. The goal store lives on the host beside the frames it
  // measures, so there is nothing to read or edit while disconnected.

  @override
  Future<DepthLockStatus> depthLockStatus() async {
    _throwNotConnected();
  }

  @override
  Future<List<DepthLockGoal>> listDepthLockGoals() async {
    _throwNotConnected();
  }

  @override
  Future<DepthLockGoal> getDepthLockGoal(String goalId) async {
    _throwNotConnected();
  }

  @override
  Future<DepthLockGoal> createDepthLockGoal(
    DepthLockGoalDefinition definition, {
    String? goalId,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<DepthLockGoal> reviseDepthLockGoal({
    required String goalId,
    required int expectedRevision,
    required DepthLockGoalDefinition definition,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<DepthLockGoal> setDepthLockGoalPreferences({
    required String goalId,
    required int expectedRevision,
    required bool enabled,
    required bool automaticCompletion,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<void> removeDepthLockGoal({
    required String goalId,
    required int expectedRevision,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<DepthLockReferenceInfo> inspectDepthLockReference(String path) async {
    _throwNotConnected();
  }

  @override
  Future<SkyRectangle> depthLockSkyRectangle({
    required ReferenceGeometry reference,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<int> checkDepthLockMeasurement(
    DepthLockMeasurement measurement,
  ) async {
    _throwNotConnected();
  }

  @override
  Future<DepthLockIngestOutcome> ingestDepthLockFrame({
    required String goalId,
    required String path,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<DepthLockGoal> replayDepthLockGoal(String goalId) async {
    _throwNotConnected();
  }

  @override
  Future<List<DepthLockCurvePoint>> depthLockGoalCurve(
    String goalId, {
    int maxPoints = 60,
  }) async {
    _throwNotConnected();
  }

  @override
  Future<DepthLockFloorSuggestion> suggestDepthLockFloor({
    required String referencePath,
    required String darkPath,
    required String flatPath,
    required double scaleArcsec,
    double? pixelScaleArcsec,
  }) async {
    _throwNotConnected();
  }
}

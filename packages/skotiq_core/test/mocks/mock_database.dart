import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:skotiq_core/src/database/database.dart';

/// Creates an in-memory database for testing
///
/// This function creates a new SkotiqDatabase instance that stores
/// all data in memory. The database is isolated for each test and will
/// be automatically cleaned up when the test completes.
///
/// Usage in tests:
/// ```dart
/// late SkotiqDatabase db;
///
/// setUp(() {
///   db = createTestDatabase();
/// });
///
/// tearDown(() async {
///   await db.close();
/// });
/// ```
SkotiqDatabase createTestDatabase() {
  return SkotiqDatabase.forTesting(NativeDatabase.memory());
}

/// Helper class for database test fixtures
class DatabaseTestFixtures {
  /// Creates a sample equipment profile companion for insertion
  static EquipmentProfilesCompanion sampleProfileCompanion({
    String name = 'Test Profile',
    String? cameraId = 'test-camera',
    String? mountId = 'test-mount',
    bool isActive = true,
  }) {
    return EquipmentProfilesCompanion.insert(
      name: name,
      description: const Value('Test equipment profile'),
      cameraId: Value(cameraId),
      mountId: Value(mountId),
      focuserId: const Value(null),
      filterWheelId: const Value(null),
      guiderId: const Value(null),
      rotatorId: const Value(null),
      domeId: const Value(null),
      weatherId: const Value(null),
      coverCalibratorId: const Value(null),
      isActive: Value(isActive),
    );
  }

  /// Creates a sample target companion for insertion
  static TargetsCompanion sampleTargetCompanion({
    String name = 'M31',
    double ra = 10.6847,
    double dec = 41.2689,
    String? objectType = 'Galaxy',
  }) {
    return TargetsCompanion.insert(
      name: name,
      catalogId: const Value('NGC 224'),
      ra: ra,
      dec: dec,
      objectType: Value(objectType),
      magnitude: const Value(3.4),
      sizeArcmin: const Value(178.0),
      constellation: const Value('Andromeda'),
      positionAngle: const Value(null),
      minAltitude: const Value(30.0),
      priority: const Value(5),
    );
  }

  /// Creates a sample imaging session companion for insertion
  static ImagingSessionsCompanion sampleSessionCompanion({
    int? targetId,
    int? profileId,
    DateTime? startTime,
  }) {
    return ImagingSessionsCompanion.insert(
      name: const Value('Test Session'),
      targetId: Value(targetId),
      profileId: Value(profileId),
      startTime: startTime ?? DateTime.now(),
      endTime: const Value(null),
      totalExposures: const Value(0),
      successfulExposures: const Value(0),
      failedExposures: const Value(0),
      totalIntegrationSecs: const Value(0.0),
      avgTemperature: const Value(null),
      avgHumidity: const Value(null),
      avgSeeing: const Value(null),
      avgHfr: const Value(null),
      avgGuidingRms: const Value(null),
    );
  }

  /// Creates a sample captured image companion for insertion
  static CapturedImagesCompanion sampleImageCompanion({
    int? sessionId,
    int? targetId,
    String frameType = 'light',
    double exposureDuration = 120.0,
    String filePath = '/path/to/test.fits',
    String fileName = 'test.fits',
    DateTime? capturedAt,
  }) {
    return CapturedImagesCompanion.insert(
      filePath: filePath,
      fileName: fileName,
      fileFormat: const Value('fits'),
      fileSize: const Value(null),
      sessionId: Value(sessionId),
      targetId: Value(targetId),
      frameType: const Value('light'),
      exposureDuration: exposureDuration,
      capturedAt: capturedAt ?? DateTime.now(),
      gain: const Value(100),
      offset: const Value(50),
      binX: const Value(1),
      binY: const Value(1),
      filter: const Value('Luminance'),
      sensorTemp: const Value(-10.0),
      coolerPower: const Value(50.0),
      hfr: const Value(2.5),
      starCount: const Value(125),
    );
  }

  /// Creates a sample sequence companion for insertion
  static SequencesCompanion sampleSequenceCompanion({
    String name = 'Test Sequence',
    bool isTemplate = false,
  }) {
    return SequencesCompanion.insert(
      name: name,
      description: const Value('Test imaging sequence'),
      isTemplate: const Value(false),
      rootNodeId: const Value(null),
    );
  }

  /// Creates a sample sequence node companion for insertion
  static SequenceNodesCompanion sampleSequenceNodeCompanion({
    required int sequenceId,
    required String nodeId,
    String nodeType = 'instruction',
    String specificType = 'expose',
    String name = 'Test Node',
    String? parentNodeId,
    int orderIndex = 0,
  }) {
    return SequenceNodesCompanion.insert(
      sequenceId: sequenceId,
      nodeId: nodeId,
      nodeType: nodeType,
      specificType: specificType,
      name: name,
      parentNodeId: Value(parentNodeId),
      orderIndex: const Value(0),
      targetId: const Value(null),
      properties: const Value('{}'),
      recoveryConfig: const Value(null),
    );
  }

  /// Creates a sample app settings companion for insertion
  static AppSettingsCompanion sampleSettingCompanion({
    required String key,
    required String value,
  }) {
    return AppSettingsCompanion.insert(key: key, value: value);
  }
}

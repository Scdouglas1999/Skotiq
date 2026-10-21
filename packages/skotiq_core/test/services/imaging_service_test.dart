import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_exception.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/services/capture_preview_loader.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';
import 'package:skotiq_core/src/services/science/science_processing_service.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

/// No-op science processor for capture-pipeline tests.
///
/// captureImage() launches science processing as fire-and-forget background
/// work (`unawaited(...)`). In production the ProviderContainer lives for the
/// whole app, so that background task always reads a live container. In a unit
/// test the container is disposed in tearDown as soon as captureImage()
/// returns, while the real science pipeline is still running — its provider
/// reads then hit a disposed container and surface as "This test failed after
/// it had already completed". These tests assert capture behaviour, not
/// science processing, so we stub the processor to a no-op to keep them
/// hermetic. Science processing has its own dedicated test coverage.
class _NoOpScienceProcessingService extends ScienceProcessingService {
  _NoOpScienceProcessingService(super.ref);

  @override
  Future<void> processCapturedFrame({
    required String imagePath,
    String? deviceId,
    int? capturedImageId,
    int? sessionId,
  }) async {
    // Intentionally does nothing.
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// A host that lists one root, so remote scratch frames have a host path.
void _stubHostRoots(_MockNetworkBackend backend) {
  when(() => backend.browseRemoteDirectories()).thenAnswer(
    (_) async => const RemoteDirectoryListing(
      currentPath: null,
      parentPath: null,
      directories: [RemoteDirectoryEntry(name: 'Documents', path: '/rig/docs')],
    ),
  );
}

class _NoOpCapturePreviewPublisher extends CapturePreviewPublisher {
  @override
  void publish(dynamic ref, CapturedImageData preview, String deviceId) {}
}

/// TestBackendNotifier that injects a mock backend into the provider.
class TestBackendNotifier extends BackendNotifier {
  TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

/// Creates a sample CapturedImageResult for use in tests.
CapturedImageResult makeCapturedImageResult({
  int width = 100,
  int height = 100,
  double exposureTime = 5.0,
  String timestamp = '2025-01-15T22:30:00Z',
  double hfr = 2.5,
  int starCount = 80,
  double mean = 5000.0,
  double stdDev = 500.0,
  bool isColor = false,
}) {
  return CapturedImageResult(
    width: width,
    height: height,
    displayData: List<int>.filled(width * height * 4, 128),
    histogram: List<int>.filled(256, 100),
    stats: ImageStatsResult(
      min: 100.0,
      max: 65535.0,
      mean: mean,
      median: 4800.0,
      stdDev: stdDev,
      hfr: hfr,
      starCount: starCount,
    ),
    exposureTime: exposureTime,
    timestamp: timestamp,
    isColor: isColor,
  );
}

void main() {
  setUpAll(() {
    registerMocktailFallbackValues();
    registerFallbackValue(
      const FitsWriteHeader(
        exposureTime: 1.0,
        captureTimestamp: '2025-01-01T00:00:00Z',
        frameType: 'Light',
      ),
    );
  });

  group('ImagingService Quality Score Tests', () {
    // Re-implement _calculateQualityScore as a local function to test the algorithm
    double calculateQualityScore({
      required double? hfr,
      required int? starCount,
      required double mean,
      required double stdDev,
    }) {
      double score = 0.0;
      double weightSum = 0.0;

      // HFR component (40% weight)
      if (hfr != null && hfr > 0.0) {
        final hfrScore = hfr < 2.0
            ? 100.0
            : hfr < 3.0
            ? 100.0 - (hfr - 2.0) * 25.0
            : hfr < 5.0
            ? 75.0 - (hfr - 3.0) * 25.0
            : math.max(0.0, 25.0 - math.min(5.0, hfr - 5.0) * 5.0);
        score += hfrScore * 0.4;
        weightSum += 0.4;
      }

      // Star count component (30% weight)
      if (starCount != null) {
        final starScore = starCount >= 100
            ? 100.0
            : starCount >= 50
            ? 66.0 + (starCount - 50) / 50.0 * 34.0
            : starCount >= 20
            ? 33.0 + (starCount - 20) / 30.0 * 33.0
            : math.max(0.0, starCount / 20.0 * 33.0);
        score += starScore * 0.3;
        weightSum += 0.3;
      }

      // Background uniformity component (30% weight)
      if (mean > 0.0) {
        final cv = stdDev / mean;
        final uniformityScore = cv < 0.1
            ? 100.0
            : cv < 0.3
            ? 100.0 - (cv - 0.1) * 333.0
            : math.max(0.0, 33.0 - math.min(0.33, cv - 0.3) * 100.0);
        score += uniformityScore * 0.3;
        weightSum += 0.3;
      }

      if (weightSum <= 0.0) {
        return 0.0;
      }

      var normalizedScore = (score / weightSum).clamp(0.0, 100.0);

      if (hfr != null && hfr > 5.0) {
        final hfrExcess = math.min(15.0, hfr - 5.0);
        final penaltyFactor = 1.0 - (hfrExcess / 15.0) * 0.25;
        normalizedScore *= penaltyFactor;
      }

      return normalizedScore.clamp(0.0, 100.0);
    }

    test('Quality score for excellent image', () {
      final score = calculateQualityScore(
        hfr: 1.8,
        starCount: 150,
        mean: 5000.0,
        stdDev: 500.0, // CV = 0.1
      );
      expect(
        score,
        greaterThan(85.0),
        reason:
            'Excellent image (HFR=1.8, stars=150, CV=0.1) should score > 85',
      );
    });

    test('Quality score for good image', () {
      final score = calculateQualityScore(
        hfr: 2.5,
        starCount: 75,
        mean: 5000.0,
        stdDev: 800.0, // CV = 0.16
      );
      expect(score, greaterThan(70.0), reason: 'Good image should score > 70');
      expect(score, lessThan(85.0), reason: 'Good image should score < 85');
    });

    test('Quality score for poor image', () {
      final score = calculateQualityScore(
        hfr: 6.0,
        starCount: 15,
        mean: 5000.0,
        stdDev: 2000.0, // CV = 0.4
      );
      expect(
        score,
        lessThan(40.0),
        reason: 'Poor image (HFR=6.0, stars=15, CV=0.4) should score < 40',
      );
    });

    test('Quality score with no HFR/star data', () {
      final score = calculateQualityScore(
        hfr: null,
        starCount: null,
        mean: 5000.0,
        stdDev: 800.0,
      );
      expect(score, greaterThanOrEqualTo(0.0));
      expect(
        score,
        lessThanOrEqualTo(100.0),
        reason: 'Score should be in valid range even with no HFR/star data',
      );
    });

    test('Quality score with zero values', () {
      final score = calculateQualityScore(
        hfr: 0.0,
        starCount: 0,
        mean: 0.0,
        stdDev: 0.0,
      );
      expect(score, greaterThanOrEqualTo(0.0));
      expect(
        score,
        lessThanOrEqualTo(100.0),
        reason: 'Score should be valid even with zeros',
      );
    });

    test('Quality score with very high HFR', () {
      final score = calculateQualityScore(
        hfr: 20.0,
        starCount: 150,
        mean: 5000.0,
        stdDev: 500.0,
      );
      expect(
        score,
        lessThan(50.0),
        reason: 'Very high HFR should lower score significantly',
      );
    });

    test('Quality score for perfect image', () {
      final score = calculateQualityScore(
        hfr: 1.5,
        starCount: 200,
        mean: 10000.0,
        stdDev: 500.0, // CV = 0.05
      );
      expect(
        score,
        greaterThan(90.0),
        reason: 'Perfect image (HFR=1.5, stars=200, CV=0.05) should score > 90',
      );
    });

    test('Quality score HFR thresholds', () {
      // Test HFR boundaries
      final score1 = calculateQualityScore(
        hfr: 1.9,
        starCount: 100,
        mean: 5000.0,
        stdDev: 500.0,
      );
      final score2 = calculateQualityScore(
        hfr: 2.1,
        starCount: 100,
        mean: 5000.0,
        stdDev: 500.0,
      );
      expect(
        score1,
        greaterThan(score2),
        reason: 'HFR 1.9 should score higher than 2.1',
      );

      final score3 = calculateQualityScore(
        hfr: 2.9,
        starCount: 100,
        mean: 5000.0,
        stdDev: 500.0,
      );
      final score4 = calculateQualityScore(
        hfr: 3.1,
        starCount: 100,
        mean: 5000.0,
        stdDev: 500.0,
      );
      expect(
        score3,
        greaterThan(score4),
        reason: 'HFR 2.9 should score higher than 3.1',
      );
    });

    test('Quality score star count thresholds', () {
      // Test star count boundaries
      final score1 = calculateQualityScore(
        hfr: 2.5,
        starCount: 19,
        mean: 5000.0,
        stdDev: 500.0,
      );
      final score2 = calculateQualityScore(
        hfr: 2.5,
        starCount: 21,
        mean: 5000.0,
        stdDev: 500.0,
      );
      expect(
        score2,
        greaterThan(score1),
        reason: '21 stars should score higher than 19 stars',
      );

      final score3 = calculateQualityScore(
        hfr: 2.5,
        starCount: 49,
        mean: 5000.0,
        stdDev: 500.0,
      );
      final score4 = calculateQualityScore(
        hfr: 2.5,
        starCount: 51,
        mean: 5000.0,
        stdDev: 500.0,
      );
      expect(
        score4,
        greaterThan(score3),
        reason: '51 stars should score higher than 49 stars',
      );
    });

    test('Quality score uniformity component', () {
      // Test different CV values with same HFR and star count
      final score1 = calculateQualityScore(
        hfr: 2.5,
        starCount: 75,
        mean: 5000.0,
        stdDev: 400.0, // CV = 0.08 (excellent)
      );
      final score2 = calculateQualityScore(
        hfr: 2.5,
        starCount: 75,
        mean: 5000.0,
        stdDev: 1000.0, // CV = 0.2 (good)
      );
      final score3 = calculateQualityScore(
        hfr: 2.5,
        starCount: 75,
        mean: 5000.0,
        stdDev: 2000.0, // CV = 0.4 (poor)
      );
      expect(
        score1,
        greaterThan(score2),
        reason: 'Better uniformity (CV=0.08) should score higher',
      );
      expect(
        score2,
        greaterThan(score3),
        reason:
            'Good uniformity (CV=0.2) should score higher than poor (CV=0.4)',
      );
    });

    test('Quality score is in valid range', () {
      // Test various combinations to ensure score is always 0-100
      final testCases = [
        {'hfr': 1.0, 'stars': 200, 'mean': 10000.0, 'std': 300.0},
        {'hfr': 10.0, 'stars': 5, 'mean': 1000.0, 'std': 500.0},
        {'hfr': 3.5, 'stars': 75, 'mean': 5000.0, 'std': 750.0},
        {'hfr': null, 'stars': 100, 'mean': 5000.0, 'std': 500.0},
        {'hfr': 2.0, 'stars': null, 'mean': 5000.0, 'std': 500.0},
      ];

      for (final testCase in testCases) {
        final score = calculateQualityScore(
          hfr: testCase['hfr'] as double?,
          starCount: testCase['stars'] as int?,
          mean: testCase['mean'] as double,
          stdDev: testCase['std'] as double,
        );
        expect(score, greaterThanOrEqualTo(0.0));
        expect(
          score,
          lessThanOrEqualTo(100.0),
          reason: 'Score must be in 0-100 range for: $testCase',
        );
      }
    });
  });

  group('ImagingService Capture Pipeline', () {
    late ProviderContainer container;
    late MockBackend mockBackend;
    late TestBackendNotifier backendNotifier;
    late StreamController<SkotiqEvent> eventStreamController;

    setUp(() {
      mockBackend = MockBackend();
      eventStreamController = StreamController<SkotiqEvent>.broadcast();

      when(
        () => mockBackend.eventStream,
      ).thenAnswer((_) => eventStreamController.stream);
      when(
        () => mockBackend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      // Default: camera reports no readout modes, so the capture path skips
      // the explicit readout-mode set. Individual tests override this when
      // they need to assert readout-mode selection.
      when(
        () => mockBackend.getCameraCapabilities(any()),
      ).thenAnswer((_) async => null);
      when(
        () => mockBackend.cameraSetReadoutMode(any(), any()),
      ).thenAnswer((_) async {});

      container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => backendNotifier = TestBackendNotifier(ref, mockBackend),
          ),
          // Set camera as connected with a device ID
          cameraStateProvider.overrideWith((ref) {
            final notifier = CameraStateNotifier(ref);
            notifier.setConnecting('test-camera-1', 'Test Camera');
            notifier.setConnected();
            return notifier;
          }),
          // captureImage() fires science processing as background work that
          // outlives the test; stub it so it cannot read a disposed container.
          scienceProcessingServiceProvider.overrideWith(
            (ref) => _NoOpScienceProcessingService(ref),
          ),
          // Mount defaults (disconnected) are fine for most tests
        ],
      );
    });

    tearDown(() {
      eventStreamController.close();
      container.dispose();
    });

    test('captureImage throws when camera is not connected', () async {
      // Create a container with disconnected camera
      final disconnectedContainer = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, mockBackend),
          ),
          // Default CameraState is disconnected
        ],
      );
      addTearDown(disconnectedContainer.dispose);

      final service = disconnectedContainer.read(imagingServiceProvider);
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      expect(
        () => service.captureImage(settings: settings),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Camera not connected'),
          ),
        ),
      );
    });

    test(
      'backend switch retires capture before old-host exposure admission',
      () async {
        final capabilityResult = Completer<CameraCapabilities?>();
        when(
          () => mockBackend.getCameraCapabilities(any()),
        ).thenAnswer((_) => capabilityResult.future);

        final oldService = container.read(imagingServiceProvider);
        final capture = oldService.captureImage(
          settings: const ExposureSettings(
            exposureTime: 1,
            gain: 100,
            offset: 10,
          ),
        );
        await untilCalled(() => mockBackend.getCameraCapabilities(any()));

        final replacementBackend = MockBackend();
        backendNotifier.replaceBackend(replacementBackend);
        final replacementService = container.read(imagingServiceProvider);
        expect(replacementService, isNot(same(oldService)));

        capabilityResult.complete(null);
        expect(await capture, isNull);
        verifyNever(
          () => mockBackend.cameraStartExposure(
            deviceId: any(named: 'deviceId'),
            exposureTime: any(named: 'exposureTime'),
            frameType: any(named: 'frameType'),
            gain: any(named: 'gain'),
            offset: any(named: 'offset'),
            binX: any(named: 'binX'),
            binY: any(named: 'binY'),
          ),
        );
      },
    );

    test(
      'backend switch while loading remote profile prevents retired FITS save',
      () async {
        final remoteBackend = _MockNetworkBackend();
        final remoteEvents = StreamController<SkotiqEvent>.broadcast();
        addTearDown(remoteEvents.close);
        final activeProfile = Completer<EquipmentProfile?>();
        _stubHostRoots(remoteBackend);

        when(
          () => remoteBackend.eventStream,
        ).thenAnswer((_) => remoteEvents.stream);
        when(
          () => remoteBackend.getCameraCapabilities(any()),
        ).thenAnswer((_) async => null);
        when(
          () => remoteBackend.cameraStartExposure(
            deviceId: any(named: 'deviceId'),
            exposureTime: any(named: 'exposureTime'),
            frameType: any(named: 'frameType'),
            gain: any(named: 'gain'),
            offset: any(named: 'offset'),
            binX: any(named: 'binX'),
            binY: any(named: 'binY'),
          ),
        ).thenAnswer((_) async {
          remoteEvents.add(
            SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: EventSeverity.info,
              category: EventCategory.imaging,
              eventType: 'ExposureComplete',
              data: const {},
            ),
          );
        });
        when(
          () => remoteBackend.cameraGetLastImage(any()),
        ).thenAnswer((_) async => makeCapturedImageResult());
        when(
          remoteBackend.getActiveProfile,
        ).thenAnswer((_) => activeProfile.future);
        when(
          () => remoteBackend.cameraAbortExposure(any()),
        ).thenAnswer((_) async {});
        when(
          () => remoteBackend.saveFitsFromLastCapture(
            deviceId: any(named: 'deviceId'),
            filePath: any(named: 'filePath'),
            headerData: any(named: 'headerData'),
          ),
        ).thenAnswer((_) async {});

        late TestBackendNotifier remoteBackendNotifier;
        final remoteContainer = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => remoteBackendNotifier = TestBackendNotifier(
                ref,
                remoteBackend,
              ),
            ),
            cameraStateProvider.overrideWith((ref) {
              final notifier = CameraStateNotifier(ref);
              notifier.setConnecting('remote-camera', 'Remote Camera');
              notifier.setConnected();
              return notifier;
            }),
            capturePreviewPublisherProvider.overrideWithValue(
              _NoOpCapturePreviewPublisher(),
            ),
            scienceProcessingServiceProvider.overrideWith(
              (ref) => _NoOpScienceProcessingService(ref),
            ),
          ],
        );
        addTearDown(remoteContainer.dispose);

        final capture = remoteContainer
            .read(imagingServiceProvider)
            .captureImage(
              settings: const ExposureSettings(
                exposureTime: 1,
                gain: 100,
                offset: 10,
              ),
            );
        await untilCalled(remoteBackend.getActiveProfile);

        final replacementBackend = MockBackend();
        remoteBackendNotifier.replaceBackend(replacementBackend);
        activeProfile.complete(
          const EquipmentProfile(id: 'old', name: 'Old Host Profile'),
        );

        expect(await capture, isNull);
        verifyNever(
          () => remoteBackend.saveFitsFromLastCapture(
            deviceId: any(named: 'deviceId'),
            filePath: any(named: 'filePath'),
            headerData: any(named: 'headerData'),
          ),
        );
        verifyNever(
          () => replacementBackend.saveFitsFromLastCapture(
            deviceId: any(named: 'deviceId'),
            filePath: any(named: 'filePath'),
            headerData: any(named: 'headerData'),
          ),
        );
      },
    );

    test('remote FITS header uses the imaging host active profile', () async {
      final remoteBackend = _MockNetworkBackend();
      _stubHostRoots(remoteBackend);
      final remoteEvents = StreamController<SkotiqEvent>.broadcast();
      addTearDown(remoteEvents.close);

      when(
        () => remoteBackend.eventStream,
      ).thenAnswer((_) => remoteEvents.stream);
      when(
        () => remoteBackend.getCameraCapabilities(any()),
      ).thenAnswer((_) async => null);
      when(
        () => remoteBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        remoteEvents.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: const {},
          ),
        );
      });
      when(
        () => remoteBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());
      when(remoteBackend.getActiveProfile).thenAnswer(
        (_) async => const EquipmentProfile(
          id: 'host-profile',
          name: 'Remote Rig',
          telescopeName: 'Remote RC10',
          focalLength: 2000,
          aperture: 250,
        ),
      );
      when(
        () => remoteBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      final remoteContainer = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, remoteBackend),
          ),
          cameraStateProvider.overrideWith((ref) {
            final notifier = CameraStateNotifier(ref);
            notifier.setConnecting('remote-camera', 'Remote Camera');
            notifier.setConnected();
            return notifier;
          }),
          capturePreviewPublisherProvider.overrideWithValue(
            _NoOpCapturePreviewPublisher(),
          ),
          scienceProcessingServiceProvider.overrideWith(
            (ref) => _NoOpScienceProcessingService(ref),
          ),
        ],
      );
      addTearDown(remoteContainer.dispose);

      final result = await remoteContainer
          .read(imagingServiceProvider)
          .captureImage(
            settings: const ExposureSettings(
              exposureTime: 1,
              gain: 100,
              offset: 10,
            ),
          );

      expect(result, isNotNull);
      final header =
          verify(
                () => remoteBackend.saveFitsFromLastCapture(
                  deviceId: 'remote-camera',
                  filePath: any(named: 'filePath'),
                  headerData: captureAny(named: 'headerData'),
                ),
              ).captured.single
              as FitsWriteHeader;
      expect(header.telescope, 'Remote RC10');
      expect(header.focalLength, 2000);
      expect(header.aperture, 250);
    });

    test('a linked client writes scratch frames inside a host root', () async {
      final remoteBackend = _MockNetworkBackend();
      final remoteEvents = StreamController<SkotiqEvent>.broadcast();
      addTearDown(remoteEvents.close);

      when(
        () => remoteBackend.eventStream,
      ).thenAnswer((_) => remoteEvents.stream);
      when(
        () => remoteBackend.getCameraCapabilities(any()),
      ).thenAnswer((_) async => null);
      when(
        () => remoteBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        remoteEvents.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: const {},
          ),
        );
      });
      when(
        () => remoteBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());
      when(remoteBackend.getActiveProfile).thenAnswer((_) async => null);
      when(() => remoteBackend.browseRemoteDirectories()).thenAnswer(
        (_) async => const RemoteDirectoryListing(
          currentPath: null,
          parentPath: null,
          directories: [
            RemoteDirectoryEntry(
              name: 'Documents',
              path: r'C:\Users\scdou\Documents',
            ),
            RemoteDirectoryEntry(
              name: 'Image Output',
              path: r'C:\Users\scdou\Documents\NGC7380',
            ),
          ],
        ),
      );
      when(
        () => remoteBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      final remoteContainer = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, remoteBackend),
          ),
          cameraStateProvider.overrideWith((ref) {
            final notifier = CameraStateNotifier(ref);
            notifier.setConnecting('native:zwo:1', 'ZWO ASI1600MM-Cool');
            notifier.setConnected();
            return notifier;
          }),
          capturePreviewPublisherProvider.overrideWithValue(
            _NoOpCapturePreviewPublisher(),
          ),
          scienceProcessingServiceProvider.overrideWith(
            (ref) => _NoOpScienceProcessingService(ref),
          ),
        ],
      );
      addTearDown(remoteContainer.dispose);

      final result = await remoteContainer
          .read(imagingServiceProvider)
          .captureUtilityFrame(
            settings: const ExposureSettings(
              exposureTime: 2,
              gain: 139,
              offset: 21,
            ),
          );

      const hostPath =
          r'C:\Users\scdou\Documents\Skotiq\scratch\liveview_native_zwo_1.fits';
      expect(result?.filePath, hostPath);
      verify(
        () => remoteBackend.saveFitsFromLastCapture(
          deviceId: 'native:zwo:1',
          filePath: hostPath,
          headerData: any(named: 'headerData'),
        ),
      ).called(1);
    });

    test('hostScratchFilePath joins in the host path style', () {
      expect(
        hostScratchFilePath(const [
          RemoteDirectoryEntry(name: 'Home', path: '/home/rig'),
        ], 'a.fits'),
        '/home/rig/Skotiq/scratch/a.fits',
      );
      expect(hostScratchFilePath(const [], 'a.fits'), isNull);
    });

    test('captureImage throws when already capturing', () async {
      // Set up a long-running capture by never completing the exposure event
      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        // Never complete - simulates a long exposure
        await Future.delayed(const Duration(seconds: 60));
      });

      final service = container.read(imagingServiceProvider);
      const settings = ExposureSettings(
        exposureTime: 30.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      // Start first capture (don't await - it will hang)
      unawaited(
        service.captureImage(settings: settings).catchError((_) => null),
      );

      // Wait briefly so the first capture enters the capturing state
      await Future.delayed(const Duration(milliseconds: 50));

      // Second capture should throw
      expect(
        () => service.captureImage(settings: settings),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Already capturing'),
          ),
        ),
      );
    });

    test('captureImage calls backend with correct parameters', () async {
      const settings = ExposureSettings(
        exposureTime: 10.0,
        gain: 200,
        offset: 30,
        binningX: 2,
        binningY: 2,
        frameType: FrameType.dark,
        filter: 'Ha',
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        // Emit ExposureComplete event immediately
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });

      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult(exposureTime: 10.0));

      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      final service = container.read(imagingServiceProvider);
      await service.captureImage(settings: settings, targetName: 'M31');

      verify(
        () => mockBackend.cameraStartExposure(
          deviceId: 'test-camera-1',
          exposureTime: 10.0,
          frameType: FrameType.dark,
          gain: 200,
          offset: 30,
          binX: 2,
          binY: 2,
        ),
      ).called(1);
    });

    test(
      'a second camera on the shared stream cannot settle our exposure',
      () async {
        // On a dual-camera rig (main + guide) both cameras publish onto the
        // same imaging event stream. A completion tagged with another camera's
        // id used to satisfy this capture's wait, so the download ran mid
        // exposure and returned the previous frame.
        const settings = ExposureSettings(
          exposureTime: 5.0,
          gain: 100,
          offset: 50,
          binningX: 1,
          binningY: 1,
          frameType: FrameType.light,
        );

        final exposureStarted = Completer<void>();
        when(
          () => mockBackend.cameraStartExposure(
            deviceId: any(named: 'deviceId'),
            exposureTime: any(named: 'exposureTime'),
            frameType: any(named: 'frameType'),
            gain: any(named: 'gain'),
            offset: any(named: 'offset'),
            binX: any(named: 'binX'),
            binY: any(named: 'binY'),
          ),
        ).thenAnswer((_) async => exposureStarted.complete());

        when(
          () => mockBackend.cameraGetLastImage(any()),
        ).thenAnswer((_) async => makeCapturedImageResult(exposureTime: 5.0));
        when(
          () => mockBackend.saveFitsFromLastCapture(
            deviceId: any(named: 'deviceId'),
            filePath: any(named: 'filePath'),
            headerData: any(named: 'headerData'),
          ),
        ).thenAnswer((_) async {});

        SkotiqEvent completionFrom(String deviceId) => SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureComplete',
          data: {'deviceId': deviceId},
        );

        final service = container.read(imagingServiceProvider);
        final capture = service.captureImage(settings: settings);
        await exposureStarted.future;

        eventStreamController.add(completionFrom('guide-camera-2'));
        await pumpEventQueue();

        verifyNever(() => mockBackend.cameraGetLastImage(any()));

        eventStreamController.add(completionFrom('test-camera-1'));
        final result = await capture;

        expect(result, isNotNull);
        verify(() => mockBackend.cameraGetLastImage(any())).called(1);
      },
    );

    test('captureImage returns CapturedImageData on success', () async {
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });

      final expectedImage = makeCapturedImageResult(
        width: 1920,
        height: 1080,
        exposureTime: 5.0,
        hfr: 1.8,
        starCount: 120,
      );

      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => expectedImage);

      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      final service = container.read(imagingServiceProvider);
      final result = await service.captureImage(
        settings: settings,
        targetName: 'NGC 7000',
      );

      expect(result, isNotNull);
      expect(result!.width, 1920);
      expect(result.height, 1080);
      expect(result.stats.hfr, 1.8);
      expect(result.stats.starCount, 120);
      expect(result.targetName, 'NGC 7000');
      expect(result.settings, settings);
    });

    test('captureImage fails loudly when the FITS cannot be saved', () async {
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: const {},
          ),
        );
      });
      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());
      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenThrow(Exception('disk full'));

      final service = container.read(imagingServiceProvider);

      await expectLater(
        service.captureImage(settings: settings),
        throwsA(
          isA<ImagingException>()
              .having((e) => e.message, 'message', contains('disk full'))
              .having(
                (e) => e.userMessage,
                'userMessage',
                contains('could not be saved'),
              ),
        ),
      );
      // The diagnostic preview may remain visible, but it is not reported as
      // a successful, durable capture to callers.
      expect(container.read(currentImageProvider), isNotNull);
      expect(service.isCapturing, isFalse);
    });

    test(
      'loop capture stops after the first non-recoverable save error',
      () async {
        const settings = ExposureSettings(
          exposureTime: 1.0,
          gain: 100,
          offset: 50,
          binningX: 1,
          binningY: 1,
          frameType: FrameType.light,
        );
        var exposureStarts = 0;
        when(
          () => mockBackend.cameraStartExposure(
            deviceId: any(named: 'deviceId'),
            exposureTime: any(named: 'exposureTime'),
            frameType: any(named: 'frameType'),
            gain: any(named: 'gain'),
            offset: any(named: 'offset'),
            binX: any(named: 'binX'),
            binY: any(named: 'binY'),
          ),
        ).thenAnswer((_) async {
          exposureStarts++;
          eventStreamController.add(
            SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: EventSeverity.info,
              category: EventCategory.imaging,
              eventType: 'ExposureComplete',
              data: const {},
            ),
          );
        });
        when(
          () => mockBackend.cameraGetLastImage(any()),
        ).thenAnswer((_) async => makeCapturedImageResult());
        when(
          () => mockBackend.saveFitsFromLastCapture(
            deviceId: any(named: 'deviceId'),
            filePath: any(named: 'filePath'),
            headerData: any(named: 'headerData'),
          ),
        ).thenThrow(Exception('read-only output folder'));
        final errors = <String>[];

        await container
            .read(imagingServiceProvider)
            .startLoopCapture(
              settings: settings,
              maxFrames: 3,
              onError: errors.add,
            );

        expect(exposureStarts, 1);
        expect(errors, hasLength(1));
        expect(errors.single, contains('read-only output folder'));
      },
    );

    test('captureImage updates currentImageProvider on success', () async {
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });

      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());

      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      // Verify currentImageProvider is null initially
      expect(container.read(currentImageProvider), isNull);

      final service = container.read(imagingServiceProvider);
      await service.captureImage(settings: settings);

      // After capture, currentImageProvider should be populated
      final currentImage = container.read(currentImageProvider);
      expect(currentImage, isNotNull);
      expect(currentImage!.width, 100);
      expect(currentImage.height, 100);
    });

    test('captureImage returns null when exposure is cancelled', () async {
      const settings = ExposureSettings(
        exposureTime: 10.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        // Emit ExposureCancelled event
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureCancelled',
            data: {},
          ),
        );
      });

      final service = container.read(imagingServiceProvider);
      final result = await service.captureImage(settings: settings);

      expect(result, isNull);
    });

    test('captureImage throws when exposure fails', () async {
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.error,
            category: EventCategory.imaging,
            eventType: 'ExposureFailed',
            data: {'error': 'Sensor readout error'},
          ),
        );
      });

      final service = container.read(imagingServiceProvider);

      expect(
        () => service.captureImage(settings: settings),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Sensor readout error'),
          ),
        ),
      );
    });

    test('captureImage throws when cameraGetLastImage returns null', () async {
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });

      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => null);

      final service = container.read(imagingServiceProvider);

      expect(
        () => service.captureImage(settings: settings),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Failed to retrieve captured image'),
          ),
        ),
      );
    });

    test(
      'captureImage resets isCapturing state after successful capture',
      () async {
        const settings = ExposureSettings(
          exposureTime: 5.0,
          gain: 100,
          offset: 50,
          binningX: 1,
          binningY: 1,
          frameType: FrameType.light,
        );

        when(
          () => mockBackend.cameraStartExposure(
            deviceId: any(named: 'deviceId'),
            exposureTime: any(named: 'exposureTime'),
            frameType: any(named: 'frameType'),
            gain: any(named: 'gain'),
            offset: any(named: 'offset'),
            binX: any(named: 'binX'),
            binY: any(named: 'binY'),
          ),
        ).thenAnswer((_) async {
          eventStreamController.add(
            SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: EventSeverity.info,
              category: EventCategory.imaging,
              eventType: 'ExposureComplete',
              data: {},
            ),
          );
        });

        when(
          () => mockBackend.cameraGetLastImage(any()),
        ).thenAnswer((_) async => makeCapturedImageResult());

        when(
          () => mockBackend.saveFitsFromLastCapture(
            deviceId: any(named: 'deviceId'),
            filePath: any(named: 'filePath'),
            headerData: any(named: 'headerData'),
          ),
        ).thenAnswer((_) async {});

        final service = container.read(imagingServiceProvider);

        expect(service.isCapturing, isFalse);
        await service.captureImage(settings: settings);
        expect(service.isCapturing, isFalse);
      },
    );

    test('captureImage resets isCapturing state after failure', () async {
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.error,
            category: EventCategory.imaging,
            eventType: 'ExposureFailed',
            data: {'error': 'Camera disconnected'},
          ),
        );
      });

      final service = container.read(imagingServiceProvider);

      try {
        await service.captureImage(settings: settings);
      } catch (_) {
        // Expected
      }

      // After failure, isCapturing should be reset
      expect(service.isCapturing, isFalse);
    });

    test('captureImage handles color images', () async {
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });

      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult(isColor: true));

      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      final service = container.read(imagingServiceProvider);
      final result = await service.captureImage(settings: settings);

      expect(result, isNotNull);
      expect(result!.isColor, isTrue);
    });

    // The native bridge stamps frames with `chrono::Utc::now()`. When that
    // string reached Dart without a `Z`, `DateTime.parse` read it as local
    // time and the subsequent `.toUtc()` shifted DATE-OBS by the host's
    // timezone offset — the frame claimed an instant it was not taken at.
    test(
      'DATE-OBS is the UTC instant for an offset-less bridge timestamp',
      () async {
        const settings = ExposureSettings(
          exposureTime: 5.0,
          gain: 100,
          offset: 50,
          binningX: 1,
          binningY: 1,
          frameType: FrameType.light,
        );

        when(
          () => mockBackend.cameraStartExposure(
            deviceId: any(named: 'deviceId'),
            exposureTime: any(named: 'exposureTime'),
            frameType: any(named: 'frameType'),
            gain: any(named: 'gain'),
            offset: any(named: 'offset'),
            binX: any(named: 'binX'),
            binY: any(named: 'binY'),
          ),
        ).thenAnswer((_) async {
          eventStreamController.add(
            SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: EventSeverity.info,
              category: EventCategory.imaging,
              eventType: 'ExposureComplete',
              data: {},
            ),
          );
        });

        when(() => mockBackend.cameraGetLastImage(any())).thenAnswer(
          (_) async =>
              makeCapturedImageResult(timestamp: '2026-07-28T17:33:34'),
        );

        final headers = <FitsWriteHeader>[];
        when(
          () => mockBackend.saveFitsFromLastCapture(
            deviceId: any(named: 'deviceId'),
            filePath: any(named: 'filePath'),
            headerData: any(named: 'headerData'),
          ),
        ).thenAnswer((invocation) async {
          headers.add(
            invocation.namedArguments[#headerData] as FitsWriteHeader,
          );
        });

        final service = container.read(imagingServiceProvider);
        await service.captureImage(settings: settings);

        expect(headers, hasLength(1));
        // The bridge reports when the frame finished downloading; DATE-OBS is
        // the START of the observation, so it is that instant minus the 5 s
        // exposure. The timezone assertion is what this test exists for and is
        // unaffected: a mis-parsed offset would move this by hours, not by the
        // exposure time.
        expect(headers.single.captureTimestamp, '2026-07-28T17:33:29.000Z');
      },
    );

    test('DATE-OBS honours an explicit non-zero offset on the bridge '
        'timestamp', () async {
      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });

      when(() => mockBackend.cameraGetLastImage(any())).thenAnswer(
        (_) async =>
            makeCapturedImageResult(timestamp: '2026-07-29T02:33:34+09:00'),
      );

      final headers = <FitsWriteHeader>[];
      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((invocation) async {
        headers.add(invocation.namedArguments[#headerData] as FitsWriteHeader);
      });

      final service = container.read(imagingServiceProvider);
      await service.captureImage(settings: settings);

      expect(headers, hasLength(1));
      // As above: the offset-bearing bridge timestamp normalises to
      // 17:33:34Z, and DATE-OBS is that minus the 5 s exposure.
      expect(headers.single.captureTimestamp, '2026-07-28T17:33:29.000Z');
    });
  });

  // C6/C9: the capture path must honour ExposureSettings.readoutModeIndex
  // resolved against the camera's *actual* reported readout-mode count — not
  // collapse it to the legacy fastReadout ? 1 : 0 binary. These tests drive
  // the real captureImage() pipeline (not the model helper in isolation) and
  // assert the exact index handed to cameraSetReadoutMode.
  group('ImagingService readout-mode resolution', () {
    late ProviderContainer container;
    late MockBackend mockBackend;
    late StreamController<SkotiqEvent> eventStreamController;

    /// Stub a successful single-frame capture so captureImage() reaches the
    /// readout-mode set call and completes. [readoutModes] controls what the
    /// capability query reports.
    void stubCapture({required List<String> readoutModes}) {
      when(() => mockBackend.getCameraCapabilities(any())).thenAnswer(
        (_) async => CameraCapabilities(
          maxWidth: 1000,
          maxHeight: 1000,
          bitDepth: 16,
          readoutModes: readoutModes,
        ),
      );
      when(
        () => mockBackend.cameraSetReadoutMode(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });
      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());
      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});
    }

    setUp(() {
      mockBackend = MockBackend();
      eventStreamController = StreamController<SkotiqEvent>.broadcast();

      when(
        () => mockBackend.eventStream,
      ).thenAnswer((_) => eventStreamController.stream);
      when(
        () => mockBackend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());

      container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, mockBackend),
          ),
          cameraStateProvider.overrideWith((ref) {
            final notifier = CameraStateNotifier(ref);
            notifier.setConnecting('test-camera-1', 'Test Camera');
            notifier.setConnected();
            return notifier;
          }),
          // captureImage() fires science processing as background work that
          // outlives the test; stub it so it cannot read a disposed container.
          scienceProcessingServiceProvider.overrideWith(
            (ref) => _NoOpScienceProcessingService(ref),
          ),
        ],
      );
    });

    tearDown(() {
      eventStreamController.close();
      container.dispose();
    });

    test('explicit readoutModeIndex=2 on a 4-mode camera applies index 2 '
        '(not collapsed to 0/1)', () async {
      stubCapture(readoutModes: const ['Mode0', 'Mode1', 'Mode2', 'Mode3']);

      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        frameType: FrameType.light,
        // The user picked a middle mode. fastReadout is false because index 2
        // is not the last (3) entry, and the chosen index is what is sent.
        readoutModeIndex: 2,
        fastReadout: false,
      );

      await container
          .read(imagingServiceProvider)
          .captureImage(settings: settings);

      verify(
        () => mockBackend.cameraSetReadoutMode('test-camera-1', 2),
      ).called(1);
    });

    test(
      'explicit readoutModeIndex=1 on a 3-mode camera applies index 1',
      () async {
        stubCapture(readoutModes: const ['Slow', 'Medium', 'Fast']);

        const settings = ExposureSettings(
          exposureTime: 5.0,
          gain: 100,
          offset: 50,
          frameType: FrameType.light,
          readoutModeIndex: 1,
        );

        await container
            .read(imagingServiceProvider)
            .captureImage(settings: settings);

        verify(
          () => mockBackend.cameraSetReadoutMode('test-camera-1', 1),
        ).called(1);
      },
    );

    test(
      'legacy fastReadout=true maps to the LAST mode on a 3-mode camera',
      () async {
        stubCapture(readoutModes: const ['Slow', 'Medium', 'Fast']);

        const settings = ExposureSettings(
          exposureTime: 5.0,
          gain: 100,
          offset: 50,
          frameType: FrameType.light,
          // No explicit index: the legacy boolean is authoritative. Fast should
          // map to the last mode (index 2), NOT the hardcoded 1.
          fastReadout: true,
        );

        await container
            .read(imagingServiceProvider)
            .captureImage(settings: settings);

        verify(
          () => mockBackend.cameraSetReadoutMode('test-camera-1', 2),
        ).called(1);
      },
    );

    test('legacy fastReadout=false maps to the first mode', () async {
      stubCapture(readoutModes: const ['Slow', 'Medium', 'Fast']);

      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        frameType: FrameType.light,
        fastReadout: false,
      );

      await container
          .read(imagingServiceProvider)
          .captureImage(settings: settings);

      verify(
        () => mockBackend.cameraSetReadoutMode('test-camera-1', 0),
      ).called(1);
    });

    test(
      'a stale index past the mode list aborts instead of changing modes',
      () async {
        stubCapture(readoutModes: const ['Slow', 'Medium', 'Fast']);

        const settings = ExposureSettings(
          exposureTime: 5.0,
          gain: 100,
          offset: 50,
          frameType: FrameType.light,
          readoutModeIndex: 4,
        );

        await expectLater(
          container
              .read(imagingServiceProvider)
              .captureImage(settings: settings),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.userMessage,
              'userMessage',
              contains('no longer available'),
            ),
          ),
        );
        verifyNever(() => mockBackend.cameraSetReadoutMode(any(), any()));
        verifyNever(
          () => mockBackend.cameraStartExposure(
            deviceId: any(named: 'deviceId'),
            exposureTime: any(named: 'exposureTime'),
            frameType: any(named: 'frameType'),
            gain: any(named: 'gain'),
            offset: any(named: 'offset'),
            binX: any(named: 'binX'),
            binY: any(named: 'binY'),
          ),
        );
      },
    );

    test(
      'camera reporting no readout modes skips the explicit set entirely',
      () async {
        // Honest no-op: nothing to select against, so forcing index 0 would
        // override the driver's own default.
        stubCapture(readoutModes: const []);

        const settings = ExposureSettings(
          exposureTime: 5.0,
          gain: 100,
          offset: 50,
          frameType: FrameType.light,
          readoutModeIndex: 1,
        );

        await container
            .read(imagingServiceProvider)
            .captureImage(settings: settings);

        verifyNever(() => mockBackend.cameraSetReadoutMode(any(), any()));
      },
    );

    test('a failed capability query aborts before exposure', () async {
      when(
        () => mockBackend.getCameraCapabilities(any()),
      ).thenThrow(Exception('bridge crash'));
      when(
        () => mockBackend.cameraSetReadoutMode(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });
      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());
      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        frameType: FrameType.light,
        readoutModeIndex: 1,
      );

      await expectLater(
        container.read(imagingServiceProvider).captureImage(settings: settings),
        throwsA(isA<Exception>()),
      );

      verifyNever(() => mockBackend.cameraSetReadoutMode(any(), any()));
      verifyNever(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      );
    });

    test('a rejected readout-mode command aborts before exposure', () async {
      stubCapture(readoutModes: const ['Slow', 'Fast']);
      when(
        () => mockBackend.cameraSetReadoutMode('test-camera-1', 1),
      ).thenThrow(Exception('driver rejected mode'));

      const settings = ExposureSettings(
        exposureTime: 5.0,
        gain: 100,
        offset: 50,
        frameType: FrameType.light,
        readoutModeIndex: 1,
      );

      await expectLater(
        container.read(imagingServiceProvider).captureImage(settings: settings),
        throwsA(isA<Exception>()),
      );
      verifyNever(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      );
    });
  });

  group('ImagingService Cancel Exposure', () {
    late ProviderContainer container;
    late MockBackend mockBackend;
    late StreamController<SkotiqEvent> eventStreamController;

    setUp(() {
      mockBackend = MockBackend();
      eventStreamController = StreamController<SkotiqEvent>.broadcast();

      when(
        () => mockBackend.eventStream,
      ).thenAnswer((_) => eventStreamController.stream);
      when(
        () => mockBackend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => mockBackend.getCameraCapabilities(any()),
      ).thenAnswer((_) async => null);
      when(
        () => mockBackend.cameraSetReadoutMode(any(), any()),
      ).thenAnswer((_) async {});

      container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, mockBackend),
          ),
          cameraStateProvider.overrideWith((ref) {
            final notifier = CameraStateNotifier(ref);
            notifier.setConnecting('test-camera-1', 'Test Camera');
            notifier.setConnected();
            return notifier;
          }),
          // captureImage() fires science processing as background work that
          // outlives the test; stub it so it cannot read a disposed container.
          scienceProcessingServiceProvider.overrideWith(
            (ref) => _NoOpScienceProcessingService(ref),
          ),
        ],
      );
    });

    tearDown(() {
      eventStreamController.close();
      container.dispose();
    });

    test('cancelExposure sets cancel flag and aborts via backend', () async {
      const settings = ExposureSettings(
        exposureTime: 30.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      final startedCompleter = Completer<void>();
      final driverExposure = Completer<void>();

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        startedCompleter.complete();
        // Model a blocking camera driver: this call cannot return until the
        // backend receives Abort, so waiting on this Future before sending
        // Abort deadlocks.
        await driverExposure.future;
      });

      when(() => mockBackend.cameraAbortExposure(any())).thenAnswer((_) async {
        if (!driverExposure.isCompleted) driverExposure.complete();
      });

      final service = container.read(imagingServiceProvider);

      // Start capture, cancel before it completes
      final captureFuture = service.captureImage(settings: settings);
      await startedCompleter.future;

      // Cancel the exposure
      service.cancelExposure();

      final result = await captureFuture.timeout(const Duration(seconds: 1));
      expect(result, isNull, reason: 'Cancelled capture should return null');

      verify(() => mockBackend.cameraAbortExposure('test-camera-1')).called(1);
    });
  });

  group('ImagingService Loop Capture', () {
    late ProviderContainer container;
    late MockBackend mockBackend;
    late StreamController<SkotiqEvent> eventStreamController;

    setUp(() {
      mockBackend = MockBackend();
      eventStreamController = StreamController<SkotiqEvent>.broadcast();

      when(
        () => mockBackend.eventStream,
      ).thenAnswer((_) => eventStreamController.stream);
      when(
        () => mockBackend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => mockBackend.getCameraCapabilities(any()),
      ).thenAnswer((_) async => null);
      when(
        () => mockBackend.cameraSetReadoutMode(any(), any()),
      ).thenAnswer((_) async {});

      container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, mockBackend),
          ),
          cameraStateProvider.overrideWith((ref) {
            final notifier = CameraStateNotifier(ref);
            notifier.setConnecting('test-camera-1', 'Test Camera');
            notifier.setConnected();
            return notifier;
          }),
          // captureImage() fires science processing as background work that
          // outlives the test; stub it so it cannot read a disposed container.
          scienceProcessingServiceProvider.overrideWith(
            (ref) => _NoOpScienceProcessingService(ref),
          ),
        ],
      );
    });

    tearDown(() {
      eventStreamController.close();
      container.dispose();
    });

    test('startLoopCapture captures maxFrames then stops', () async {
      const settings = ExposureSettings(
        exposureTime: 1.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });

      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());

      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      final capturedImages = <CapturedImageData>[];
      final service = container.read(imagingServiceProvider);

      await service.startLoopCapture(
        settings: settings,
        maxFrames: 3,
        onImageCaptured: (image) => capturedImages.add(image),
      );

      expect(capturedImages.length, 3);
    });

    test('startLoopCapture calls onError and continues on failure', () async {
      const settings = ExposureSettings(
        exposureTime: 1.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      int callCount = 0;
      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 2) {
          // Second frame fails
          eventStreamController.add(
            SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: EventSeverity.error,
              category: EventCategory.imaging,
              eventType: 'ExposureFailed',
              data: {'error': 'Temporary sensor error'},
            ),
          );
        } else {
          // Other frames succeed
          eventStreamController.add(
            SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: EventSeverity.info,
              category: EventCategory.imaging,
              eventType: 'ExposureComplete',
              data: {},
            ),
          );
        }
      });

      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());

      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      final capturedImages = <CapturedImageData>[];
      final errors = <String>[];
      final service = container.read(imagingServiceProvider);

      await service.startLoopCapture(
        settings: settings,
        maxFrames: 3,
        onImageCaptured: (image) => capturedImages.add(image),
        onError: (error) => errors.add(error),
      );

      // 2 of 3 frames succeeded, 1 errored
      expect(capturedImages.length, 2);
      expect(errors.length, 1);
      expect(errors.first, contains('Temporary sensor error'));
    });

    test('startLoopCapture stops when cancelExposure is called', () async {
      const settings = ExposureSettings(
        exposureTime: 1.0,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      );

      when(
        () => mockBackend.cameraStartExposure(
          deviceId: any(named: 'deviceId'),
          exposureTime: any(named: 'exposureTime'),
          frameType: any(named: 'frameType'),
          gain: any(named: 'gain'),
          offset: any(named: 'offset'),
          binX: any(named: 'binX'),
          binY: any(named: 'binY'),
        ),
      ).thenAnswer((_) async {
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ExposureComplete',
            data: {},
          ),
        );
      });

      when(
        () => mockBackend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => makeCapturedImageResult());

      when(
        () => mockBackend.saveFitsFromLastCapture(
          deviceId: any(named: 'deviceId'),
          filePath: any(named: 'filePath'),
          headerData: any(named: 'headerData'),
        ),
      ).thenAnswer((_) async {});

      final capturedImages = <CapturedImageData>[];
      final service = container.read(imagingServiceProvider);

      // Start loop without maxFrames - cancel after first image
      final loopFuture = service.startLoopCapture(
        settings: settings,
        onImageCaptured: (image) {
          capturedImages.add(image);
          // Cancel after first successful capture
          service.cancelExposure();
        },
      );

      await loopFuture;

      // Should have captured at most 1 frame before cancellation took effect
      expect(capturedImages.length, 1);
    });
  });

  group('ExposureProgressNotifier', () {
    test('starts in idle state', () {
      final notifier = ExposureProgressNotifier();
      addTearDown(notifier.dispose);

      expect(notifier.state.elapsed, 0.0);
      expect(notifier.state.remaining, 0.0);
      expect(notifier.state.percent, 0.0);
      expect(notifier.state.isDownloading, isFalse);
    });

    test('startExposure sets initial progress state', () {
      final notifier = ExposureProgressNotifier();
      addTearDown(notifier.dispose);

      notifier.startExposure(120.0, 5, 10);

      expect(notifier.state.elapsed, 0.0);
      expect(notifier.state.remaining, 120.0);
      expect(notifier.state.percent, 0.0);
      expect(notifier.state.frameNumber, 5);
      expect(notifier.state.totalFrames, 10);
      expect(notifier.state.isDownloading, isFalse);
    });

    test('updateProgress updates elapsed and remaining', () {
      final notifier = ExposureProgressNotifier();
      addTearDown(notifier.dispose);

      notifier.startExposure(120.0, 1, null);
      notifier.updateProgress(60.0, 60.0, 50.0);

      expect(notifier.state.elapsed, 60.0);
      expect(notifier.state.remaining, 60.0);
      expect(notifier.state.percent, 50.0);
      expect(notifier.state.isDownloading, isFalse);
    });

    test('startDownload sets downloading flag', () {
      final notifier = ExposureProgressNotifier();
      addTearDown(notifier.dispose);

      notifier.startExposure(10.0, 1, null);
      notifier.updateProgress(10.0, 0.0, 100.0);
      notifier.startDownload();

      expect(notifier.state.isDownloading, isTrue);
      expect(notifier.state.percent, 100.0);
      expect(notifier.state.remaining, 0.0);
    });

    test('reset returns to idle state', () {
      final notifier = ExposureProgressNotifier();
      addTearDown(notifier.dispose);

      notifier.startExposure(120.0, 5, 10);
      notifier.updateProgress(60.0, 60.0, 50.0);
      notifier.reset();

      expect(notifier.state.elapsed, 0.0);
      expect(notifier.state.remaining, 0.0);
      expect(notifier.state.percent, 0.0);
      expect(notifier.state.frameNumber, 1);
      expect(notifier.state.totalFrames, isNull);
      expect(notifier.state.isDownloading, isFalse);
    });
  });

  group('ExposureProgress model', () {
    test('idle factory creates zero state', () {
      final idle = ExposureProgress.idle();

      expect(idle.elapsed, 0.0);
      expect(idle.remaining, 0.0);
      expect(idle.percent, 0.0);
      expect(idle.isDownloading, isFalse);
    });

    test('equality works correctly', () {
      const a = ExposureProgress(
        elapsed: 10.0,
        remaining: 50.0,
        percent: 16.7,
        frameNumber: 2,
        totalFrames: 10,
        isDownloading: false,
      );
      const b = ExposureProgress(
        elapsed: 10.0,
        remaining: 50.0,
        percent: 16.7,
        frameNumber: 2,
        totalFrames: 10,
        isDownloading: false,
      );
      const c = ExposureProgress(
        elapsed: 20.0,
        remaining: 40.0,
        percent: 33.3,
        frameNumber: 2,
        totalFrames: 10,
        isDownloading: false,
      );

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  // The "Calibrated" badge in the imaging screen binds to this
  // provider. It must be true if and only if the current image's saved
  // path actually carries the `_cal.fits` suffix that the calibration
  // service produces. Anything looser (e.g. matching `cal` anywhere in
  // the name) would lie about uncalibrated frames that happen to live in
  // a folder named "calibration".
  group('currentImageIsCalibratedProvider', () {
    CapturedImageData makeImageWithPath(String? filePath) {
      return CapturedImageData(
        width: 4,
        height: 4,
        displayData: Uint8List(4 * 4 * 4),
        histogram: List<int>.filled(256, 0),
        stats: const ImageStats(mean: 0, stdDev: 0),
        capturedAt: DateTime.utc(2026, 1, 1),
        settings: const ExposureSettings(exposureTime: 1.0, gain: 0, offset: 0),
        filePath: filePath,
      );
    }

    test('returns false when no current image is published', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      expect(container.read(currentImageIsCalibratedProvider), isFalse);
    });

    test('returns false when filePath is null or empty', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      container.read(currentImageProvider.notifier).state = makeImageWithPath(
        null,
      );
      expect(container.read(currentImageIsCalibratedProvider), isFalse);

      container.read(currentImageProvider.notifier).state = makeImageWithPath(
        '',
      );
      expect(container.read(currentImageIsCalibratedProvider), isFalse);
    });

    test('returns false for a raw .fits frame', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      container.read(currentImageProvider.notifier).state = makeImageWithPath(
        '/captures/2026-01-01/light_001.fits',
      );
      expect(container.read(currentImageIsCalibratedProvider), isFalse);
    });

    test('returns true for a `_cal.fits` suffixed frame', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      container.read(currentImageProvider.notifier).state = makeImageWithPath(
        '/captures/2026-01-01/light_001_cal.fits',
      );
      expect(container.read(currentImageIsCalibratedProvider), isTrue);
    });

    test('returns true for a `_cal.fit` suffix on Windows-style path', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      container.read(currentImageProvider.notifier).state = makeImageWithPath(
        r'C:\captures\2026-01-01\m31_002_cal.fit',
      );
      expect(container.read(currentImageIsCalibratedProvider), isTrue);
    });

    test('returns false for paths whose directory contains "cal" but file does '
        'not end in _cal.fits', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      // A "calibration" folder used to hold master darks/flats shouldn't
      // make a raw light frame inside it look calibrated.
      container.read(currentImageProvider.notifier).state = makeImageWithPath(
        '/library/calibration/master_dark.fits',
      );
      expect(container.read(currentImageIsCalibratedProvider), isFalse);
    });
  });

  // / naming-pattern expansion. The user's pattern is a
  // '/'-separated path whose last segment is the filename stem; earlier
  // segments become subdirectories under the configured base path. Date/time
  // substitutions use UTC so the on-disk folder matches the UTC timestamp
  // written into FITS DATE-OBS.
  group('ImagingService.buildImageFilePath', () {
    const settings = ExposureSettings(
      exposureTime: 120.0,
      gain: 100,
      offset: 50,
      binningX: 1,
      binningY: 1,
      filter: 'L',
      frameType: FrameType.light,
    );

    test('subdirectory-only pattern places filename last', () {
      // Pattern: subdirectory hierarchy + an implicit filename-stem segment.
      // `$TARGET/$FILTER/$DATE` has three segments; the last (`$DATE`) is the
      // filename stem and the first two are subdirectories.
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: DateTime.utc(2026, 5, 23, 12, 0, 0),
      );

      final fullPath = ImagingService.buildImageFilePath(
        pattern: r'$TARGET/$FILTER/$DATE',
        basePath: '/captures',
        extension: 'fits',
        substitutions: subs,
      );

      // Last segment is the filename stem; expect M31/L as subdirs and the
      // date as the filename.
      expect(fullPath, contains('M31'));
      expect(fullPath, contains('L'));
      expect(fullPath, endsWith('2026-05-23.fits'));
    });

    test('full pattern with filename segment honours the filename portion', () {
      // The user's pattern ends in `$TARGET_$FILTER_$FRAMENUM`, and the
      // trailing segment is the filename: what the user wrote is what is used,
      // not a hard-coded ${target}_${filter}_${frameNumber}.
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: DateTime.utc(2026, 5, 23, 12, 0, 0),
      );

      final fullPath = ImagingService.buildImageFilePath(
        pattern: r'$TARGET/$FILTER/$DATE/$TARGET_$FILTER_$FRAMENUM',
        basePath: '/captures',
        extension: 'fits',
        substitutions: subs,
      );

      expect(
        fullPath,
        endsWith('M31_L_0001.fits'),
        reason: 'Filename portion of pattern must be honoured',
      );
      expect(
        fullPath,
        contains('2026-05-23'),
        reason: 'Subdirectory hierarchy still applies',
      );
    });

    test('unknown variable in pattern throws with descriptive error', () {
      // Silent fallbacks hide bugs for months. A typo like
      // `$BANANA` must surface immediately rather than landing in the
      // filename as a literal "$BANANA" string.
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: DateTime.utc(2026, 5, 23, 12, 0, 0),
      );

      expect(
        () => ImagingService.buildImageFilePath(
          pattern: r'$TARGET/$BANANA/$FRAMENUM',
          basePath: '/captures',
          extension: 'fits',
          substitutions: subs,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains(r'$BANANA'),
              contains('Unknown naming-pattern variable'),
              // The error must enumerate the supported set so the user can
              // fix the typo without grepping the codebase.
              contains(r'$TARGET'),
            ),
          ),
        ),
      );
    });

    test('multiple unknown variables are all reported in one error', () {
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: DateTime.utc(2026, 5, 23, 12, 0, 0),
      );

      expect(
        () => ImagingService.buildImageFilePath(
          pattern: r'$FOO/$BAR/$BAZ',
          basePath: '/captures',
          extension: 'fits',
          substitutions: subs,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains(r'$FOO'), contains(r'$BAR'), contains(r'$BAZ')),
          ),
        ),
      );
    });

    test('pattern without "/" places file directly in base path', () {
      // No subdirectory separators ⇒ the whole pattern is the filename stem.
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 7,
        timestamp: DateTime.utc(2026, 5, 23, 12, 0, 0),
      );

      final fullPath = ImagingService.buildImageFilePath(
        pattern: r'$TARGET_$FILTER_$FRAMENUM',
        basePath: '/captures',
        extension: 'fits',
        substitutions: subs,
      );

      expect(fullPath, endsWith('M31_L_0007.fits'));
    });

    test('prefix-overlap variables disambiguate correctly', () {
      // A naive chained `replaceAll` handles `$EXPTIME` and `$EXPOSURE`
      // because neither is a strict prefix of the other; the regex-based pass
      // keeps that behaviour. Likewise `$FRAMENUM` and `$FRAMETYPE`.
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 3,
        timestamp: DateTime.utc(2026, 5, 23, 12, 0, 0),
      );

      final fullPath = ImagingService.buildImageFilePath(
        pattern: r'$FRAMETYPE/$EXPOSURE/$EXPTIME_$FRAMENUM',
        basePath: '/c',
        extension: 'fits',
        substitutions: subs,
      );

      // Both EXPOSURE and EXPTIME resolve to "120.0"; FRAMETYPE -> "light";
      // FRAMENUM -> "0003".
      expect(fullPath, contains('light'));
      expect(fullPath, contains('120.0'));
      expect(fullPath, endsWith('120.0_0003.fits'));
    });

    test('SEQ alias resolves to padded frame number', () {
      // Documented in settings_screen subtitle as `$SEQ`; legacy users have
      // this in their pattern (it ships as a default in
      // `database.dart` / `settings_provider.dart`).
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 12,
        timestamp: DateTime.utc(2026, 5, 23, 12, 0, 0),
      );

      final fullPath = ImagingService.buildImageFilePath(
        pattern: r'$TARGET_$FILTER_$DATE_$SEQ',
        basePath: '/c',
        extension: 'fits',
        substitutions: subs,
      );

      expect(fullPath, endsWith('M31_L_2026-05-23_0012.fits'));
    });

    test(
      'substitution values cannot inject directories or parent traversal',
      () {
        final subs = ImagingService.buildTimestampSubstitutions(
          exposureSettings: settings,
          targetName: '../M31\\Ha:unsafe',
          frameNumber: 1,
          timestamp: DateTime.utc(2026, 5, 23),
        );

        final fullPath = ImagingService.buildImageFilePath(
          pattern: r'$TARGET/$TARGET_$FRAMENUM',
          basePath: '/captures',
          extension: 'fits',
          substitutions: subs,
        );

        expect(path.isWithin('/captures', fullPath), isTrue);
        expect(fullPath, isNot(contains('..')));
        expect(fullPath, isNot(contains(r'\')));
        expect(fullPath, endsWith('M31_Ha_unsafe_0001.fits'));
      },
    );

    test('literal parent traversal in pattern is rejected', () {
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: DateTime.utc(2026, 5, 23),
      );

      expect(
        () => ImagingService.buildImageFilePath(
          pattern: r'../$TARGET',
          basePath: '/captures',
          extension: 'fits',
          substitutions: subs,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('lowercase and malformed variable syntax is rejected', () {
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: DateTime.utc(2026, 5, 23),
      );

      expect(
        () => ImagingService.buildImageFilePath(
          pattern: r'$target_$FRAMENUM',
          basePath: '/captures',
          extension: 'fits',
          substitutions: subs,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  // UTC-consistent naming. FITS DATE-OBS is UTC; the on-disk
  // folder name must match so a 19:00 PST capture lands in the same UTC
  // date as the FITS header timestamp embedded in the file.
  group('ImagingService.buildTimestampSubstitutions UTC convention', () {
    const settings = ExposureSettings(
      exposureTime: 60.0,
      gain: 100,
      offset: 50,
      binningX: 1,
      binningY: 1,
      filter: 'L',
      frameType: FrameType.light,
    );

    test('19:00 PST capture resolves \$DATE to next UTC day', () {
      // 19:00 PST == 03:00 UTC the next day. `$DATE` follows the UTC clock so
      // the folder matches the FITS DATE-OBS card; formatting the local
      // DateTime would put the frame one day behind its own header.
      final localTs = DateTime(2026, 1, 15, 19, 0, 0); // local-time ctor
      // Force the test to behave the same on any host TZ: construct an
      // explicit offset relative to UTC by using a known UTC moment and
      // re-deriving a local DateTime from it.
      final utcEquivalent = DateTime.utc(
        2026,
        1,
        16,
        3,
        0,
        0,
      ); // 19:00 PST → 03:00 UTC
      // Either ctor must give a UTC date of 2026-01-16 after `.toUtc()`.
      final subs1 = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: utcEquivalent,
      );
      expect(subs1[r'$DATE'], '2026-01-16');
      expect(subs1[r'$TIME'], '03-00-00');

      // And a local-time DateTime that resolves to the same instant must
      // produce the same UTC date (regardless of host TZ, because
      // `localTs.toUtc()` normalises). This guarantees the implementation
      // calls `.toUtc()` before formatting.
      final subs2 = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: localTs,
      );
      // We can't assert the exact value because the test host TZ is
      // unknown, but the formatted date MUST equal `localTs.toUtc()`'s
      // ISO date — proving the conversion path runs.
      final expectedDate = localTs.toUtc().toIso8601String().substring(0, 10);
      expect(subs2[r'$DATE'], expectedDate);
    });

    test('midnight-UTC capture resolves \$DATE to that UTC day', () {
      final ts = DateTime.utc(2026, 5, 23, 0, 0, 0);
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: ts,
      );
      expect(subs[r'$DATE'], '2026-05-23');
      expect(subs[r'$TIME'], '00-00-00');
      expect(subs[r'$DATETIME'], '2026-05-23_00-00-00');
      // $SESSION is documented as compact yyyymmdd in the Rust naming.rs;
      // we mirror that so cross-language users see consistent strings.
      expect(subs[r'$SESSION'], '20260523');
    });

    test('one-second-before-UTC-midnight is correctly classified', () {
      // 23:59:59 UTC on 2026-05-23 must NOT spill into 2026-05-24. This
      // verifies we are formatting from UTC, not adding any offset.
      final ts = DateTime.utc(2026, 5, 23, 23, 59, 59);
      final subs = ImagingService.buildTimestampSubstitutions(
        exposureSettings: settings,
        targetName: 'M31',
        frameNumber: 1,
        timestamp: ts,
      );
      expect(subs[r'$DATE'], '2026-05-23');
      expect(subs[r'$TIME'], '23-59-59');
    });
  });
}

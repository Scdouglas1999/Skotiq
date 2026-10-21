import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:mocktail/mocktail.dart' as mt;
import 'package:skotiq_core/skotiq_core.dart';

import 'centering_service_test.mocks.dart';
import '../harness/in_memory_database.dart';

/// Fake backend that lets each test control the `getMountStatus` behavior
/// for the post-slew settle poll loop. The centering service only touches
/// `getMountStatus` on this object during the polling path, so we leave the
/// other 130-odd `SkotiqBackend` methods as mocktail defaults.
class _PollBackend extends mt.Mock implements SkotiqBackend {
  @override
  Stream<SkotiqEvent> get eventStream => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  void dispose() {}
}

/// Helper: build a [MountStatus] with `slewing` controllable, everything
/// else benign. Used by the success-path polling stub.
MountStatus _settledMount({bool slewing = false}) {
  return MountStatus(
    connected: true,
    tracking: true,
    slewing: slewing,
    parked: false,
    atHome: false,
    sideOfPier: PierSide.unknown,
    rightAscension: 0.0,
    declination: 0.0,
    altitude: 0.0,
    azimuth: 0.0,
    siderealTime: 0.0,
    trackingRate: TrackingRate.sidereal,
    canPark: true,
    canSlew: true,
    canSync: true,
    canPulseGuide: true,
    canSetTrackingRate: true,
  );
}

CapturedImageData _centeringImage([String path = '/tmp/centering.fits']) {
  return CapturedImageData(
    width: 16,
    height: 16,
    displayData: Uint8List(16 * 16 * 4),
    histogram: List.filled(256, 0),
    stats: const ImageStats(mean: 100.0, stdDev: 10.0),
    capturedAt: DateTime.now(),
    settings: const ExposureSettings(exposureTime: 3.0, gain: 100, offset: 50),
    filePath: path,
  );
}

PlateSolveResult _solvedAt(double raDegrees, double decDegrees) {
  return PlateSolveResult(
    success: true,
    ra: raDegrees,
    dec: decDegrees,
    rotation: 0,
    pixelScale: 1,
    fieldWidth: 2,
    fieldHeight: 1.5,
    solveTimeSecs: 0,
    cd11: 0,
    cd12: 0,
    cd21: 0,
    cd22: 0,
    sipAOrder: 0,
    sipBOrder: 0,
    sipACoeffs: Float64List(0),
    sipBCoeffs: Float64List(0),
    sipApOrder: 0,
    sipBpOrder: 0,
    sipApCoeffs: Float64List(0),
    sipBpCoeffs: Float64List(0),
  );
}

/// Notifier override that pins the backend StateNotifierProvider to a
/// caller-supplied instance — same trick the meridian-flip E2E test uses.
class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

// Generate mocks for these classes
@GenerateMocks([ImagingService, PlateSolveService, DeviceService])
void main() {
  group('CenteringService', () {
    late ProviderContainer container;
    late MockImagingService mockImagingService;
    late MockPlateSolveService mockPlateSolveService;
    late MockDeviceService mockDeviceService;
    late _PollBackend pollBackend;
    late _TestBackendNotifier backendNotifier;

    setUp(() {
      mockImagingService = MockImagingService();
      mockPlateSolveService = MockPlateSolveService();
      mockDeviceService = MockDeviceService();
      pollBackend = _PollBackend();

      when(
        mockPlateSolveService.ensureSolverAvailable(),
      ).thenAnswer((_) async {});

      // Default: post-slew polling sees a settled mount on the first tick.
      // Tests that need to exercise the failure-escalation path override
      // this in their own `when(...)` clause before invoking centering.
      mt
          .when(() => pollBackend.getMountStatus(mt.any()))
          .thenAnswer((_) async => _settledMount());

      container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          imagingServiceProvider.overrideWithValue(mockImagingService),
          plateSolveServiceProvider.overrideWithValue(mockPlateSolveService),
          deviceServiceProvider.overrideWithValue(mockDeviceService),
          centeringSlewPollIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 1),
          ),
          backendProvider.overrideWith(
            (ref) => backendNotifier = _TestBackendNotifier(ref, pollBackend),
          ),
          // Override equipment states to simulate connected devices
          cameraStateProvider.overrideWith((ref) {
            final notifier = CameraStateNotifier(ref);
            notifier.setConnecting('test_camera', 'Test Camera');
            notifier.setConnected();
            return notifier;
          }),
          mountStateProvider.overrideWith((ref) {
            final notifier = MountStateNotifier(ref);
            notifier.setConnecting('test_mount');
            notifier.setConnected();
            notifier.updatePosition(
              10.0,
              45.0,
              30.0,
              180.0,
            ); // ra, dec, alt, az
            return notifier;
          }),
        ],
      );
    });

    tearDown(() {
      container.dispose();
    });

    group('centerOnTarget', () {
      test(
        'backend switch retires the run before a late solve can slew',
        () async {
          const solverConfig = PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: '/usr/bin/astap',
          );
          final solve = Completer<PlateSolveResult>();
          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((_) async => _centeringImage());
          when(
            mockPlateSolveService.solveWithFallback(
              imagePath: anyNamed('imagePath'),
              hintRaHours: anyNamed('hintRaHours'),
              hintDecDegrees: anyNamed('hintDecDegrees'),
              searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
              timeoutSeconds: anyNamed('timeoutSeconds'),
            ),
          ).thenAnswer((_) => solve.future);

          final oldService = container.read(centeringServiceProvider);
          final run = oldService.centerOnTarget(
            targetRa: 10,
            targetDec: 45,
            solverConfig: solverConfig,
            config: const CenteringConfig(maxIterations: 2, exposureTime: 1),
          );
          await untilCalled(
            mockPlateSolveService.solveWithFallback(
              imagePath: anyNamed('imagePath'),
              hintRaHours: anyNamed('hintRaHours'),
              hintDecDegrees: anyNamed('hintDecDegrees'),
              searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
              timeoutSeconds: anyNamed('timeoutSeconds'),
            ),
          );

          final replacementBackend = _PollBackend();
          backendNotifier.replaceBackend(replacementBackend);
          final replacementService = container.read(centeringServiceProvider);
          expect(replacementService, isNot(same(oldService)));

          solve.complete(_solvedAt(11 * 15, 40));
          final result = await run;

          expect(result.success, isFalse);
          expect(result.errorMessage, contains('Aborted'));
          verifyNever(mockDeviceService.slewMountToCoordinates(any, any));
        },
      );

      test('succeeds on first iteration when within tolerance', () async {
        // Arrange
        const targetRa = 10.0; // hours
        const targetDec = 45.0; // degrees
        const toleranceArcsec = 30.0;

        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        const config = CenteringConfig(
          maxIterations: 5,
          toleranceArcsec: toleranceArcsec,
          exposureTime: 3.0,
        );

        final capturedImage = CapturedImageData(
          width: 1920,
          height: 1080,
          displayData: Uint8List(1920 * 1080 * 4),
          histogram: List.filled(256, 0),
          stats: const ImageStats(mean: 100.0, stdDev: 10.0),
          capturedAt: DateTime.now(),
          settings: const ExposureSettings(
            exposureTime: 3.0,
            gain: 100,
            offset: 50,
          ),
          filePath: '/tmp/test_image.fits',
        );

        // Plate solve returns coordinates very close to target (within
        // tolerance). NB the solver returns RA in DEGREES, so the on-target
        // value is `targetRa * 15` (10h -> 150°), not `targetRa`.
        final solveResult = PlateSolveResult(
          success: true,
          ra: targetRa * 15.0, // Same as target, expressed in degrees
          dec: targetDec, // Same as target
          rotation: 0.0,
          pixelScale: 1.0,
          fieldWidth: 2.0,
          fieldHeight: 1.5,
          solveTimeSecs: 0.0,
          cd11: 0,
          cd12: 0,
          cd21: 0,
          cd22: 0,
          sipAOrder: 0,
          sipBOrder: 0,
          sipACoeffs: Float64List(0),
          sipBCoeffs: Float64List(0),
          sipApOrder: 0,
          sipBpOrder: 0,
          sipApCoeffs: Float64List(0),
          sipBpCoeffs: Float64List(0),
        );

        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => capturedImage);

        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) async => solveResult);

        // Act
        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRa,
          targetDec: targetDec,
          solverConfig: solverConfig,
          config: config,
        );

        // Assert
        expect(result.success, isTrue);
        expect(result.iterations, equals(1));
        expect(result.finalOffsetArcsec, lessThanOrEqualTo(toleranceArcsec));
        expect(result.iterationHistory, hasLength(1));
        expect(result.iterationHistory.first.plateSolveSuccess, isTrue);

        // Verify no slewing occurred since we were already centered
        verifyNever(mockDeviceService.slewMountToCoordinates(any, any));
      });

      test(
        'omitted gain and offset preserve current imaging settings',
        () async {
          const solverConfig = PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: '/usr/bin/astap',
          );
          container.read(exposureSettingsProvider.notifier).state =
              const ExposureSettings(exposureTime: 120, gain: 137, offset: 42);
          ExposureSettings? commandedSettings;
          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((invocation) async {
            commandedSettings =
                invocation.namedArguments[#settings] as ExposureSettings;
            return _centeringImage('/tmp/inherit-camera-settings.fits');
          });
          when(
            mockPlateSolveService.solveWithFallback(
              imagePath: anyNamed('imagePath'),
              hintRaHours: anyNamed('hintRaHours'),
              hintDecDegrees: anyNamed('hintDecDegrees'),
              searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
              timeoutSeconds: anyNamed('timeoutSeconds'),
            ),
          ).thenAnswer((_) async => _solvedAt(150, 45));

          final result = await container
              .read(centeringServiceProvider)
              .centerOnTarget(
                targetRa: 10,
                targetDec: 45,
                solverConfig: solverConfig,
              );

          expect(result.success, isTrue);
          expect(commandedSettings?.gain, 137);
          expect(commandedSettings?.offset, 42);
        },
      );

      // RA units
      //
      // `PlateSolveResult.ra` is in DEGREES (the Rust solver reads FITS CRVAL1
      // verbatim; the network host forwards it unchanged). The centering target
      // (`targetRa`), the slew/sync calls and the mount frame are all in HOURS.
      // Rescaling both puts the solved RA 15× from the target's frame, so the
      // haversine offset never falls below tolerance and slew-and-center burns
      // its iterations without converging. These tests pin the unit handling.

      // Helper: build a CapturedImageData with a given file path.
      CapturedImageData raUnitFixture(String path) {
        return CapturedImageData(
          width: 1920,
          height: 1080,
          displayData: Uint8List(1920 * 1080 * 4),
          histogram: List.filled(256, 0),
          stats: const ImageStats(mean: 100.0, stdDev: 10.0),
          capturedAt: DateTime.now(),
          settings: const ExposureSettings(
            exposureTime: 3.0,
            gain: 100,
            offset: 50,
          ),
          filePath: path,
        );
      }

      test('RA unit: solver degrees on target converge on the first iteration '
          '(no spurious 15x offset)', () async {
        // Target 10h / +45°. Solver reports the SAME point but in degrees:
        // 10h == 150.0°. With the bug this looked like a ~2250° (mod) error
        // in the offset math and never converged; corrected, the offset is
        // ~0 and we succeed immediately.
        const targetRaHours = 10.0;
        const targetDecDeg = 45.0;
        const solvedRaDeg = targetRaHours * 15.0; // 150.0°

        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => raUnitFixture('/tmp/ra_unit_on.fits'));

        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer(
          (_) async => PlateSolveResult(
            success: true,
            ra: solvedRaDeg, // DEGREES
            dec: targetDecDeg,
            rotation: 0.0,
            pixelScale: 1.0,
            fieldWidth: 2.0,
            fieldHeight: 1.5,
            solveTimeSecs: 0.0,
            cd11: 0,
            cd12: 0,
            cd21: 0,
            cd22: 0,
            sipAOrder: 0,
            sipBOrder: 0,
            sipACoeffs: Float64List(0),
            sipBCoeffs: Float64List(0),
            sipApOrder: 0,
            sipBpOrder: 0,
            sipApCoeffs: Float64List(0),
            sipBpCoeffs: Float64List(0),
          ),
        );

        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRaHours,
          targetDec: targetDecDeg,
          solverConfig: solverConfig,
          config: const CenteringConfig(
            maxIterations: 5,
            toleranceArcsec: 30.0,
          ),
        );

        expect(
          result.success,
          isTrue,
          reason: 'On-target solve (degrees) must converge immediately',
        );
        expect(result.iterations, equals(1));
        // Offset must be a hair, not a 15x-inflated value.
        expect(result.finalOffsetArcsec, isNotNull);
        expect(result.finalOffsetArcsec!, lessThan(1.0));
        // Solved RA is recorded back in HOURS (150° -> 10h).
        expect(
          result.iterationHistory.first.solvedRa,
          closeTo(targetRaHours, 1e-9),
        );
        verifyNever(mockDeviceService.slewMountToCoordinates(any, any));
      });

      test(
        'RA unit: a known pure-RA offset produces the true angular separation '
        '(offset = cos(dec) x deltaRA), not a 15x value',
        () async {
          // Put the solved RA 0.10° east of the target at +60° dec.
          // True separation along a great circle for a small pure-RA step is
          // cos(dec) * deltaRA: cos(60°) = 0.5, so 0.10° of RA => 0.05° on the
          // sky == 180 arcsec. We assert the FIRST iteration's recorded offset
          // matches 180" (the corrected math), proving the solved RA was NOT
          // re-scaled by 15. We use a tolerance tight enough that a 15x error
          // (which would read ~2700"+, well past max) is impossible to pass.
          const targetRaHours = 6.0; // 90.0° in the solver frame
          const targetDecDeg = 60.0;
          const deltaRaDeg = 0.10;
          const expectedArcsec = 180.0; // cos(60°) * 0.10° * 3600
          const solvedRaDeg = targetRaHours * 15.0 + deltaRaDeg; // 90.10°

          const solverConfig = PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: '/usr/bin/astap',
          );

          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((_) async => raUnitFixture('/tmp/ra_unit_off.fits'));

          when(
            mockPlateSolveService.solveWithFallback(
              imagePath: anyNamed('imagePath'),
              hintRaHours: anyNamed('hintRaHours'),
              hintDecDegrees: anyNamed('hintDecDegrees'),
              searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
              timeoutSeconds: anyNamed('timeoutSeconds'),
            ),
          ).thenAnswer(
            (_) async => PlateSolveResult(
              success: true,
              ra: solvedRaDeg, // DEGREES
              dec: targetDecDeg,
              rotation: 0.0,
              pixelScale: 1.0,
              fieldWidth: 2.0,
              fieldHeight: 1.5,
              solveTimeSecs: 0.0,
              cd11: 0,
              cd12: 0,
              cd21: 0,
              cd22: 0,
              sipAOrder: 0,
              sipBOrder: 0,
              sipACoeffs: Float64List(0),
              sipBCoeffs: Float64List(0),
              sipApOrder: 0,
              sipBpOrder: 0,
              sipApCoeffs: Float64List(0),
              sipBpCoeffs: Float64List(0),
            ),
          );
          when(
            mockDeviceService.slewMountToCoordinates(any, any),
          ).thenAnswer((_) async => {});

          final service = container.read(centeringServiceProvider);
          final result = await service.centerOnTarget(
            targetRa: targetRaHours,
            targetDec: targetDecDeg,
            solverConfig: solverConfig,
            // tolerance below the offset so the run records the offset then
            // proceeds to slew; cap iterations at 1 so the (unchanging) stub
            // doesn't loop forever.
            config: const CenteringConfig(
              maxIterations: 1,
              toleranceArcsec: 30.0,
            ),
          );

          // maxIterations=1 with a persistent offset -> not centered.
          expect(result.success, isFalse);
          expect(result.iterationHistory, hasLength(1));
          final recordedOffset = result.iterationHistory.first.offsetArcsec;
          expect(recordedOffset, isNotNull);
          // 1 arcsec tolerance: a 15x-scaled bug could never land here.
          expect(
            recordedOffset!,
            closeTo(expectedArcsec, 1.0),
            reason:
                'Corrected math: cos(60°)*0.10°=0.05°=180". A 15x RA error '
                'would read thousands of arcsec.',
          );
        },
      );

      test(
        'RA unit: sync path receives the solved RA in HOURS, not degrees',
        () async {
          // With syncMount=true the service syncs to the solved coordinates
          // before slewing to target. `syncMountToCoordinates` expects HOURS,
          // so the value passed must be the degrees solve normalised to hours.
          const targetRaHours = 3.0;
          const targetDecDeg = 20.0;
          // Solver reports 2 arcmin of pure-RA error so a slew (and, with
          // syncMount, a sync) is triggered on the first iteration.
          const solvedRaDeg =
              targetRaHours * 15.0 + (120.0 / 3600.0); // degrees

          const solverConfig = PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: '/usr/bin/astap',
          );

          var iter = 0;
          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((_) async => raUnitFixture('/tmp/ra_unit_sync.fits'));
          when(
            mockPlateSolveService.solveWithFallback(
              imagePath: anyNamed('imagePath'),
              hintRaHours: anyNamed('hintRaHours'),
              hintDecDegrees: anyNamed('hintDecDegrees'),
              searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
              timeoutSeconds: anyNamed('timeoutSeconds'),
            ),
          ).thenAnswer((_) async {
            iter++;
            if (iter == 1) {
              return PlateSolveResult(
                success: true,
                ra: solvedRaDeg, // off-target, degrees
                dec: targetDecDeg,
                rotation: 0.0,
                pixelScale: 1.0,
                fieldWidth: 2.0,
                fieldHeight: 1.5,
                solveTimeSecs: 0.0,
                cd11: 0,
                cd12: 0,
                cd21: 0,
                cd22: 0,
                sipAOrder: 0,
                sipBOrder: 0,
                sipACoeffs: Float64List(0),
                sipBCoeffs: Float64List(0),
                sipApOrder: 0,
                sipBpOrder: 0,
                sipApCoeffs: Float64List(0),
                sipBpCoeffs: Float64List(0),
              );
            }
            // Second solve: on target, in degrees.
            return PlateSolveResult(
              success: true,
              ra: targetRaHours * 15.0,
              dec: targetDecDeg,
              rotation: 0.0,
              pixelScale: 1.0,
              fieldWidth: 2.0,
              fieldHeight: 1.5,
              solveTimeSecs: 0.0,
              cd11: 0,
              cd12: 0,
              cd21: 0,
              cd22: 0,
              sipAOrder: 0,
              sipBOrder: 0,
              sipACoeffs: Float64List(0),
              sipBCoeffs: Float64List(0),
              sipApOrder: 0,
              sipBpOrder: 0,
              sipApCoeffs: Float64List(0),
              sipBpCoeffs: Float64List(0),
            );
          });
          when(
            mockDeviceService.syncMountToCoordinates(any, any),
          ).thenAnswer((_) async => {});
          when(
            mockDeviceService.slewMountToCoordinates(any, any),
          ).thenAnswer((_) async => {});

          final service = container.read(centeringServiceProvider);
          final result = await service.centerOnTarget(
            targetRa: targetRaHours,
            targetDec: targetDecDeg,
            solverConfig: solverConfig,
            config: const CenteringConfig(
              maxIterations: 2,
              toleranceArcsec: 30.0,
              syncMount: true,
            ),
          );

          expect(result.success, isTrue);
          // The sync must have been handed the solved RA in HOURS. The solved
          // degrees value normalised to hours is solvedRaDeg/15.
          const expectedSyncRaHours = solvedRaDeg / 15.0;
          final captured = verify(
            mockDeviceService.syncMountToCoordinates(captureAny, captureAny),
          ).captured;
          // captured is a flat [ra, dec, ra, dec, ...]; first call's RA.
          final syncedRaHours = captured[0] as double;
          expect(
            syncedRaHours,
            closeTo(expectedSyncRaHours, 1e-9),
            reason:
                'sync RA must be the degrees solve normalised to hours, '
                'never the raw degrees (which would be 15x too large)',
          );
        },
      );

      // A mis-pointed mount must actually be CORRECTED. Shipping 6.0.0 ran
      // centering with `syncMount: false` from both desktop call sites, and
      // that branch re-issued the original target slew unchanged: every
      // iteration re-measured a bit-identical offset (observed live:
      // 17570.40506768608 arcsec three times running) and the run ended on
      // "Maximum iterations (3) reached". These tests drive a mount with a
      // constant pointing error and require convergence on both branches.
      group('pointing error correction', () {
        const targetRaHours = 5.0;
        const targetDecDeg = 30.0;
        const errorRaHours = 0.02; // 0.3 deg of RA
        const errorDecDeg = 0.2; // 720 arcsec, well outside tolerance
        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        late double commandedRa;
        late double commandedDec;
        late double pointingErrorRa;
        late double pointingErrorDec;
        late List<List<double>> slews;

        /// Wire a mount that points `pointingError` away from whatever it was
        /// last commanded, and a solver that reports where it truly points. A
        /// sync teaches the mount its real position, so the next slew lands
        /// where it was asked to.
        void wireMisPointedMount() {
          commandedRa = targetRaHours;
          commandedDec = targetDecDeg;
          pointingErrorRa = errorRaHours;
          pointingErrorDec = errorDecDeg;
          slews = [];

          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((_) async => _centeringImage('/tmp/pointing.fits'));
          when(mockDeviceService.slewMountToCoordinates(any, any)).thenAnswer((
            invocation,
          ) async {
            commandedRa = invocation.positionalArguments[0] as double;
            commandedDec = invocation.positionalArguments[1] as double;
            slews.add([commandedRa, commandedDec]);
          });
          when(mockDeviceService.syncMountToCoordinates(any, any)).thenAnswer((
            _,
          ) async {
            pointingErrorRa = 0.0;
            pointingErrorDec = 0.0;
          });
          when(
            mockPlateSolveService.solveWithFallback(
              imagePath: anyNamed('imagePath'),
              hintRaHours: anyNamed('hintRaHours'),
              hintDecDegrees: anyNamed('hintDecDegrees'),
              searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
              timeoutSeconds: anyNamed('timeoutSeconds'),
            ),
          ).thenAnswer(
            (_) async => _solvedAt(
              (commandedRa + pointingErrorRa) * 15.0,
              commandedDec + pointingErrorDec,
            ),
          );
        }

        test('the default config syncs and converges', () async {
          wireMisPointedMount();

          final service = container.read(centeringServiceProvider);
          final result = await service.centerOnTarget(
            targetRa: targetRaHours,
            targetDec: targetDecDeg,
            solverConfig: solverConfig,
            config: const CenteringConfig(
              maxIterations: 4,
              toleranceArcsec: 30.0,
              exposureTime: 1.0,
            ),
          );

          expect(result.success, isTrue, reason: result.errorMessage ?? '');
          expect(result.iterations, 2);
          // The sync was handed the SOLVED position, in hours.
          final synced = verify(
            mockDeviceService.syncMountToCoordinates(captureAny, captureAny),
          ).captured;
          expect(
            synced[0] as double,
            closeTo(targetRaHours + errorRaHours, 1e-9),
          );
          expect(
            synced[1] as double,
            closeTo(targetDecDeg + errorDecDeg, 1e-9),
          );
        });

        test(
          'without a sync the correction is an offset slew, not a repeat',
          () async {
            wireMisPointedMount();

            final service = container.read(centeringServiceProvider);
            final result = await service.centerOnTarget(
              targetRa: targetRaHours,
              targetDec: targetDecDeg,
              solverConfig: solverConfig,
              config: const CenteringConfig(
                maxIterations: 4,
                toleranceArcsec: 30.0,
                exposureTime: 1.0,
                syncMount: false,
              ),
            );

            expect(result.success, isTrue, reason: result.errorMessage ?? '');
            expect(result.iterations, 2);
            verifyNever(mockDeviceService.syncMountToCoordinates(any, any));
            expect(slews, hasLength(1));
            expect(
              slews.single[0],
              closeTo(targetRaHours - errorRaHours, 1e-9),
              reason: 'the corrective slew must not repeat the target RA',
            );
            expect(
              slews.single[1],
              closeTo(targetDecDeg - errorDecDeg, 1e-9),
              reason: 'the corrective slew must not repeat the target Dec',
            );
          },
        );

        test('a persistent pointing error never repeats one slew', () async {
          wireMisPointedMount();
          // The live failure: the solver reports the SAME offset every
          // iteration. Even then each correction must command the mount
          // somewhere new instead of re-issuing the coordinates that produced
          // the mis-pointed frame.
          when(
            mockPlateSolveService.solveWithFallback(
              imagePath: anyNamed('imagePath'),
              hintRaHours: anyNamed('hintRaHours'),
              hintDecDegrees: anyNamed('hintDecDegrees'),
              searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
              timeoutSeconds: anyNamed('timeoutSeconds'),
            ),
          ).thenAnswer(
            (_) async => _solvedAt(
              (targetRaHours + errorRaHours) * 15.0,
              targetDecDeg + errorDecDeg,
            ),
          );

          final service = container.read(centeringServiceProvider);
          final result = await service.centerOnTarget(
            targetRa: targetRaHours,
            targetDec: targetDecDeg,
            solverConfig: solverConfig,
            config: const CenteringConfig(
              maxIterations: 3,
              toleranceArcsec: 30.0,
              exposureTime: 1.0,
              syncMount: false,
            ),
          );

          expect(result.success, isFalse);
          expect(slews, hasLength(3));
          final distinct = slews.map((s) => '${s[0]}/${s[1]}').toSet();
          expect(
            distinct,
            hasLength(3),
            reason: 'each correction must move the mount somewhere new',
          );
        });
      });

      test('succeeds after multiple iterations', () async {
        // Arrange
        const targetRa = 10.0; // hours
        const targetDec = 45.0; // degrees
        const toleranceArcsec = 30.0;

        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        const config = CenteringConfig(
          maxIterations: 5,
          toleranceArcsec: toleranceArcsec,
          exposureTime: 3.0,
        );

        final capturedImage = CapturedImageData(
          width: 1920,
          height: 1080,
          displayData: Uint8List(1920 * 1080 * 4),
          histogram: List.filled(256, 0),
          stats: const ImageStats(mean: 100.0, stdDev: 10.0),
          capturedAt: DateTime.now(),
          settings: const ExposureSettings(
            exposureTime: 3.0,
            gain: 100,
            offset: 50,
          ),
          filePath: '/tmp/test_image.fits',
        );

        // First iteration: 2 arcmin off
        // Second iteration: 30 arcsec off (within tolerance)
        var iterationCount = 0;
        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => capturedImage);

        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) async {
          iterationCount++;
          if (iterationCount == 1) {
            // First solve: 2 arcmin (120 arcsec) off in RA. Solver RA is in
            // DEGREES: on-target is targetRa*15 (=150°), plus 120 arcsec
            // expressed in degrees (120/3600).
            return PlateSolveResult(
              success: true,
              ra: targetRa * 15.0 + (120.0 / 3600.0),
              dec: targetDec,
              rotation: 0.0,
              pixelScale: 1.0,
              fieldWidth: 2.0,
              fieldHeight: 1.5,
              solveTimeSecs: 0.0,
              cd11: 0,
              cd12: 0,
              cd21: 0,
              cd22: 0,
              sipAOrder: 0,
              sipBOrder: 0,
              sipACoeffs: Float64List(0),
              sipBCoeffs: Float64List(0),
              sipApOrder: 0,
              sipBpOrder: 0,
              sipApCoeffs: Float64List(0),
              sipBpCoeffs: Float64List(0),
            );
          } else {
            // Second solve: within tolerance (on-target, in degrees).
            return PlateSolveResult(
              success: true,
              ra: targetRa * 15.0,
              dec: targetDec,
              rotation: 0.0,
              pixelScale: 1.0,
              fieldWidth: 2.0,
              fieldHeight: 1.5,
              solveTimeSecs: 0.0,
              cd11: 0,
              cd12: 0,
              cd21: 0,
              cd22: 0,
              sipAOrder: 0,
              sipBOrder: 0,
              sipACoeffs: Float64List(0),
              sipBCoeffs: Float64List(0),
              sipApOrder: 0,
              sipBpOrder: 0,
              sipApCoeffs: Float64List(0),
              sipBpCoeffs: Float64List(0),
            );
          }
        });

        when(
          mockDeviceService.slewMountToCoordinates(any, any),
        ).thenAnswer((_) async => {});

        // Act
        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRa,
          targetDec: targetDec,
          solverConfig: solverConfig,
          config: config,
        );

        // Assert
        expect(result.success, isTrue);
        expect(result.iterations, equals(2));
        expect(result.finalOffsetArcsec, lessThanOrEqualTo(toleranceArcsec));
        expect(result.iterationHistory, hasLength(2));

        // Verify slew was called once (after first failed iteration)
        verify(
          mockDeviceService.slewMountToCoordinates(targetRa, targetDec),
        ).called(1);
      });

      test('fails when max iterations reached', () async {
        // Arrange
        const targetRa = 10.0;
        const targetDec = 45.0;
        const toleranceArcsec = 30.0;
        const maxIterations = 3;

        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        const config = CenteringConfig(
          maxIterations: maxIterations,
          toleranceArcsec: toleranceArcsec,
          exposureTime: 3.0,
        );

        final capturedImage = CapturedImageData(
          width: 1920,
          height: 1080,
          displayData: Uint8List(1920 * 1080 * 4),
          histogram: List.filled(256, 0),
          stats: const ImageStats(mean: 100.0, stdDev: 10.0),
          capturedAt: DateTime.now(),
          settings: const ExposureSettings(
            exposureTime: 3.0,
            gain: 100,
            offset: 50,
          ),
          filePath: '/tmp/test_image.fits',
        );

        // All iterations return coordinates significantly off target
        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => capturedImage);

        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) async {
          // Solver RA in DEGREES: on-target targetRa*15 plus 300 arcsec
          // (5 arcmin) expressed in degrees (300/3600).
          return PlateSolveResult(
            success: true,
            ra: targetRa * 15.0 + (300.0 / 3600.0),
            dec: targetDec,
            rotation: 0.0,
            pixelScale: 1.0,
            fieldWidth: 2.0,
            fieldHeight: 1.5,
            solveTimeSecs: 0.0,
            cd11: 0,
            cd12: 0,
            cd21: 0,
            cd22: 0,
            sipAOrder: 0,
            sipBOrder: 0,
            sipACoeffs: Float64List(0),
            sipBCoeffs: Float64List(0),
            sipApOrder: 0,
            sipBpOrder: 0,
            sipApCoeffs: Float64List(0),
            sipBpCoeffs: Float64List(0),
          );
        });

        when(
          mockDeviceService.slewMountToCoordinates(any, any),
        ).thenAnswer((_) async => {});

        // Act
        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRa,
          targetDec: targetDec,
          solverConfig: solverConfig,
          config: config,
        );

        // Assert
        expect(result.success, isFalse);
        expect(result.iterations, equals(maxIterations));
        expect(result.errorMessage, contains('Maximum iterations'));
        expect(result.iterationHistory, hasLength(maxIterations));

        // Verify slew was called for each iteration except the last
        verify(
          mockDeviceService.slewMountToCoordinates(targetRa, targetDec),
        ).called(maxIterations);
      });

      test('fails when camera not connected', () async {
        // Arrange
        final disconnectedContainer = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            cameraStateProvider.overrideWith((ref) {
              return CameraStateNotifier(ref); // Default is disconnected
            }),
            mountStateProvider.overrideWith((ref) {
              final notifier = MountStateNotifier(ref);
              notifier.setConnecting('test_mount');
              notifier.setConnected();
              return notifier;
            }),
          ],
        );

        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        // Act
        final service = disconnectedContainer.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: 10.0,
          targetDec: 45.0,
          solverConfig: solverConfig,
        );

        // Assert
        expect(result.success, isFalse);
        expect(result.errorMessage, contains('Camera not connected'));
        expect(result.iterations, equals(0));

        disconnectedContainer.dispose();
      });

      test('missing selected solver fails before taking an exposure', () async {
        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '',
        );
        when(
          mockPlateSolveService.ensureSolverAvailable(),
        ).thenThrow(const SolverNotAvailableError('ASTAP is not configured'));

        final service = container.read(centeringServiceProvider);
        await expectLater(
          service.centerOnTarget(
            targetRa: 10,
            targetDec: 45,
            solverConfig: solverConfig,
          ),
          throwsA(isA<SolverNotAvailableError>()),
        );

        verifyNever(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        );
        expect(service.isRunning, isFalse);
      });

      test(
        'timeout cancels the exposure and waits for its owner Future to settle',
        () async {
          const solverConfig = PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: '/usr/bin/astap',
          );

          // Signal when the exposure is actually in flight. The pre-capture
          // pipeline (validation, solver availability, initial-slew status)
          // takes a machine-dependent number of event-loop turns; a
          // too-tight overallTimeout can fire BEFORE the capture starts, in
          // which case there is legitimately no exposure to cancel and the
          // abort guards return promptly. This test pins the
          // timeout-DURING-capture contract, so it must first observe the
          // capture starting.
          final captureStarted = Completer<void>();
          final exposureCompleter = Completer<CapturedImageData?>();
          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((_) {
            if (!captureStarted.isCompleted) captureStarted.complete();
            return exposureCompleter.future;
          });

          final service = container.read(centeringServiceProvider);
          var terminal = false;
          final resultFuture = service.centerOnTarget(
            targetRa: 10.0,
            targetDec: 45.0,
            solverConfig: solverConfig,
            config: const CenteringConfig(
              overallTimeout: Duration(milliseconds: 400),
            ),
          );
          unawaited(resultFuture.whenComplete(() => terminal = true));

          // Capture must be in flight well before the 400ms timeout.
          await captureStarted.future;
          // Let the overall timeout fire while the exposure is still pending.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          expect(terminal, isFalse);
          expect(service.isRunning, isTrue);
          verify(mockImagingService.cancelExposure()).called(1);

          // A real ImagingService completes its capture Future in response to
          // cancelExposure(). Drive that settlement explicitly in this mock.
          exposureCompleter.complete(null);
          final result = await resultFuture;

          expect(result.success, isFalse);
          expect(result.errorMessage, contains('timed out'));
          expect(service.isRunning, isFalse);
        },
      );

      test('stop while idle does not interrupt unrelated hardware', () async {
        final service = container.read(centeringServiceProvider);

        await service.stop();

        verifyNever(mockImagingService.cancelExposure());
        verifyNever(mockDeviceService.abortMountSlew());
      });

      test(
        'invalid coordinates and capture configuration fail before hardware',
        () async {
          final result = await container
              .read(centeringServiceProvider)
              .centerOnTarget(
                targetRa: 25,
                targetDec: 45,
                solverConfig: const PlateSolverConfig(
                  type: PlateSolverType.astap,
                  executablePath: '/usr/bin/astap',
                ),
                config: const CenteringConfig(exposureTime: -1),
              );

          expect(result.success, isFalse);
          expect(result.errorMessage, contains('RA'));
          verifyNever(mockPlateSolveService.ensureSolverAvailable());
          verifyNever(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          );
        },
      );

      test('abort during plate solve never commands a late slew', () async {
        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );
        final solveCompleter = Completer<PlateSolveResult>();
        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => _centeringImage('/tmp/cancel-solve.fits'));
        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) => solveCompleter.future);

        final service = container.read(centeringServiceProvider);
        final resultFuture = service.centerOnTarget(
          targetRa: 10,
          targetDec: 45,
          solverConfig: solverConfig,
        );
        await untilCalled(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        );

        await service.stop();
        solveCompleter.complete(_solvedAt(150.1, 45));
        final result = await resultFuture;

        expect(result.success, isFalse);
        expect(result.errorMessage, contains('Aborted'));
        verifyNever(mockDeviceService.syncMountToCoordinates(any, any));
        verifyNever(mockDeviceService.slewMountToCoordinates(any, any));
      });

      test(
        'a concurrent centering request is rejected without another capture',
        () async {
          const solverConfig = PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: '/usr/bin/astap',
          );
          final exposureCompleter = Completer<CapturedImageData?>();
          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((_) => exposureCompleter.future);

          final service = container.read(centeringServiceProvider);
          final first = service.centerOnTarget(
            targetRa: 10,
            targetDec: 45,
            solverConfig: solverConfig,
          );
          await untilCalled(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          );

          final second = await service.centerOnTarget(
            targetRa: 11,
            targetDec: 46,
            solverConfig: solverConfig,
          );
          expect(second.success, isFalse);
          expect(second.errorMessage, contains('already running'));
          verify(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).called(1);

          await service.stop();
          exposureCompleter.complete(null);
          await first;
        },
      );

      test('fails when mount not connected', () async {
        // Arrange
        final disconnectedContainer = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            cameraStateProvider.overrideWith((ref) {
              final notifier = CameraStateNotifier(ref);
              notifier.setConnecting('test_camera', 'Test Camera');
              notifier.setConnected();
              return notifier;
            }),
            mountStateProvider.overrideWith((ref) {
              return MountStateNotifier(ref); // Default is disconnected
            }),
          ],
        );

        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        // Act
        final service = disconnectedContainer.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: 10.0,
          targetDec: 45.0,
          solverConfig: solverConfig,
        );

        // Assert
        expect(result.success, isFalse);
        expect(result.errorMessage, contains('Mount not connected'));
        expect(result.iterations, equals(0));

        disconnectedContainer.dispose();
      });

      test('fails when plate solve fails', () async {
        // Arrange
        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        final capturedImage = CapturedImageData(
          width: 1920,
          height: 1080,
          displayData: Uint8List(1920 * 1080 * 4),
          histogram: List.filled(256, 0),
          stats: const ImageStats(mean: 100.0, stdDev: 10.0),
          capturedAt: DateTime.now(),
          settings: const ExposureSettings(
            exposureTime: 3.0,
            gain: 100,
            offset: 50,
          ),
          filePath: '/tmp/test_image.fits',
        );

        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => capturedImage);

        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) async {
          return PlateSolveResult(
            success: false,
            ra: 0,
            dec: 0,
            pixelScale: 0,
            rotation: 0,
            fieldWidth: 0,
            fieldHeight: 0,
            solveTimeSecs: 0,
            error: 'No stars found in image',
            cd11: 0,
            cd12: 0,
            cd21: 0,
            cd22: 0,
            sipAOrder: 0,
            sipBOrder: 0,
            sipACoeffs: Float64List(0),
            sipBCoeffs: Float64List(0),
            sipApOrder: 0,
            sipBpOrder: 0,
            sipApCoeffs: Float64List(0),
            sipBpCoeffs: Float64List(0),
          );
        });

        // Act
        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: 10.0,
          targetDec: 45.0,
          solverConfig: solverConfig,
        );

        // Assert
        expect(result.success, isFalse);
        expect(result.errorMessage, contains('Plate solve failed'));
        expect(result.iterations, equals(5));
        expect(result.iterationHistory.first.plateSolveSuccess, isFalse);
      });

      test('reports status updates during centering', () async {
        // Arrange
        const targetRa = 10.0;
        const targetDec = 45.0;

        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        const config = CenteringConfig(maxIterations: 2);

        final capturedImage = CapturedImageData(
          width: 1920,
          height: 1080,
          displayData: Uint8List(1920 * 1080 * 4),
          histogram: List.filled(256, 0),
          stats: const ImageStats(mean: 100.0, stdDev: 10.0),
          capturedAt: DateTime.now(),
          settings: const ExposureSettings(
            exposureTime: 3.0,
            gain: 100,
            offset: 50,
          ),
          filePath: '/tmp/test_image.fits',
        );

        var iterationCount = 0;
        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => capturedImage);

        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) async {
          iterationCount++;
          if (iterationCount == 1) {
            // Solver RA in DEGREES: targetRa*15 + 120 arcsec (in degrees).
            return PlateSolveResult(
              success: true,
              ra: targetRa * 15.0 + (120.0 / 3600.0),
              dec: targetDec,
              rotation: 0.0,
              pixelScale: 1.0,
              fieldWidth: 2.0,
              fieldHeight: 1.5,
              solveTimeSecs: 0.0,
              cd11: 0,
              cd12: 0,
              cd21: 0,
              cd22: 0,
              sipAOrder: 0,
              sipBOrder: 0,
              sipACoeffs: Float64List(0),
              sipBCoeffs: Float64List(0),
              sipApOrder: 0,
              sipBpOrder: 0,
              sipApCoeffs: Float64List(0),
              sipBpCoeffs: Float64List(0),
            );
          } else {
            return PlateSolveResult(
              success: true,
              ra: targetRa * 15.0,
              dec: targetDec,
              rotation: 0.0,
              pixelScale: 1.0,
              fieldWidth: 2.0,
              fieldHeight: 1.5,
              solveTimeSecs: 0.0,
              cd11: 0,
              cd12: 0,
              cd21: 0,
              cd22: 0,
              sipAOrder: 0,
              sipBOrder: 0,
              sipACoeffs: Float64List(0),
              sipBCoeffs: Float64List(0),
              sipApOrder: 0,
              sipBpOrder: 0,
              sipApCoeffs: Float64List(0),
              sipBpCoeffs: Float64List(0),
            );
          }
        });

        when(
          mockDeviceService.slewMountToCoordinates(any, any),
        ).thenAnswer((_) async => {});

        final statusUpdates = <CenteringStatus>[];

        // Act
        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRa,
          targetDec: targetDec,
          solverConfig: solverConfig,
          config: config,
          onStatusUpdate: (status) => statusUpdates.add(status),
        );

        // Assert
        expect(result.success, isTrue);
        expect(statusUpdates, isNotEmpty);

        // Verify we got exposing, solving, and slewing states
        expect(
          statusUpdates.where((s) => s.state == CenteringState.exposing),
          isNotEmpty,
        );
        expect(
          statusUpdates.where((s) => s.state == CenteringState.solving),
          isNotEmpty,
        );
        expect(
          statusUpdates.where((s) => s.state == CenteringState.slewing),
          isNotEmpty,
        );
        expect(
          statusUpdates.where((s) => s.state == CenteringState.completed),
          isNotEmpty,
        );
      });

      test(
        'waits for an initial slew to settle before the first exposure',
        () async {
          const solverConfig = PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: '/usr/bin/astap',
          );
          final settleCompleter = Completer<MountStatus>();
          var statusCalls = 0;
          mt.when(() => pollBackend.getMountStatus(mt.any())).thenAnswer((_) {
            statusCalls++;
            if (statusCalls == 1) {
              return Future.value(_settledMount(slewing: true));
            }
            if (statusCalls == 2) return settleCompleter.future;
            return Future.value(_settledMount());
          });
          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((_) async => _centeringImage('/tmp/initial-slew.fits'));
          when(
            mockPlateSolveService.solveWithFallback(
              imagePath: anyNamed('imagePath'),
              hintRaHours: anyNamed('hintRaHours'),
              hintDecDegrees: anyNamed('hintDecDegrees'),
              searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
              timeoutSeconds: anyNamed('timeoutSeconds'),
            ),
          ).thenAnswer((_) async => _solvedAt(150, 45));

          final resultFuture = container
              .read(centeringServiceProvider)
              .centerOnTarget(
                targetRa: 10,
                targetDec: 45,
                solverConfig: solverConfig,
              );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          verifyNever(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          );

          settleCompleter.complete(_settledMount());
          final result = await resultFuture;
          expect(result.success, isTrue);
          verify(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).called(1);
        },
      );

      // Post-slew polling escalation
      //
      // The centering service runs a settle-poll loop after each slew. If the
      // mount stops answering `getMountStatus` for too long, the loop must
      // escalate to a typed failure instead of dragging out the full 60s
      // wall-clock cap. The four tests below cover the contract:
      //   1. Healthy mount  -> normal proceed.
      //   2. ONE transient blip -> recovers, do not escalate.
      //   3. 6 consecutive failures -> abort with the typed exception.
      //   4. Failure then success -> counter resets, polling continues.

      // Shared fixture for all four polling-escalation tests: a captured
      // image good enough that plate-solve returns a 2-arcmin offset on the
      // first attempt, forcing exactly one slew + one settle-poll cycle.
      CapturedImageData buildPollFixtureImage() {
        return CapturedImageData(
          width: 1920,
          height: 1080,
          displayData: Uint8List(1920 * 1080 * 4),
          histogram: List.filled(256, 0),
          stats: const ImageStats(mean: 100.0, stdDev: 10.0),
          capturedAt: DateTime.now(),
          settings: const ExposureSettings(
            exposureTime: 3.0,
            gain: 100,
            offset: 50,
          ),
          filePath: '/tmp/poll_test.fits',
        );
      }

      void stubTwoIterationPlateSolve(double targetRa, double targetDec) {
        var iterationCount = 0;
        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => buildPollFixtureImage());
        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) async {
          iterationCount++;
          // First poll: 2 arcmin off (forces slew + post-slew poll path).
          // Second poll: on-target (test terminates with success once the
          // poll loop completes / escalates).
          if (iterationCount == 1) {
            // Solver RA in DEGREES: targetRa*15 + 120 arcsec (in degrees).
            return PlateSolveResult(
              success: true,
              ra: targetRa * 15.0 + (120.0 / 3600.0),
              dec: targetDec,
              rotation: 0.0,
              pixelScale: 1.0,
              fieldWidth: 2.0,
              fieldHeight: 1.5,
              solveTimeSecs: 0.0,
              cd11: 0,
              cd12: 0,
              cd21: 0,
              cd22: 0,
              sipAOrder: 0,
              sipBOrder: 0,
              sipACoeffs: Float64List(0),
              sipBCoeffs: Float64List(0),
              sipApOrder: 0,
              sipBpOrder: 0,
              sipApCoeffs: Float64List(0),
              sipBpCoeffs: Float64List(0),
            );
          }
          // On-target: 10h in degrees = 150°.
          return PlateSolveResult(
            success: true,
            ra: 150.0,
            dec: 45.0,
            rotation: 0.0,
            pixelScale: 1.0,
            fieldWidth: 2.0,
            fieldHeight: 1.5,
            solveTimeSecs: 0.0,
            cd11: 0,
            cd12: 0,
            cd21: 0,
            cd22: 0,
            sipAOrder: 0,
            sipBOrder: 0,
            sipACoeffs: Float64List(0),
            sipBCoeffs: Float64List(0),
            sipApOrder: 0,
            sipBpOrder: 0,
            sipApCoeffs: Float64List(0),
            sipBpCoeffs: Float64List(0),
          );
        });
        when(
          mockDeviceService.slewMountToCoordinates(any, any),
        ).thenAnswer((_) async => {});
      }

      test(
        'post-slew poll: a mount that never settles fails explicitly',
        () async {
          const targetRa = 10.0;
          const targetDec = 45.0;
          const solverConfig = PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: '/usr/bin/astap',
          );
          stubTwoIterationPlateSolve(targetRa, targetDec);
          var statusCalls = 0;
          mt.when(() => pollBackend.getMountStatus(mt.any())).thenAnswer((
            _,
          ) async {
            statusCalls++;
            // The initial pre-exposure check is settled. Once the service
            // commands its correction slew, the mount remains moving for
            // the full bounded poll window.
            return _settledMount(slewing: statusCalls > 1);
          });

          final result = await container
              .read(centeringServiceProvider)
              .centerOnTarget(
                targetRa: targetRa,
                targetDec: targetDec,
                solverConfig: solverConfig,
                config: const CenteringConfig(maxIterations: 2),
              );

          expect(result.success, isFalse);
          expect(result.errorMessage, contains('still slewing'));
          verify(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).called(1);
        },
      );

      test('post-slew poll: mount answers every tick -> centering proceeds '
          'normally (regression)', () async {
        const targetRa = 10.0;
        const targetDec = 45.0;
        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        stubTwoIterationPlateSolve(targetRa, targetDec);
        // Default setUp stub already returns a settled mount, but pin it
        // explicitly so the contract is obvious from this test body.
        mt
            .when(() => pollBackend.getMountStatus(mt.any()))
            .thenAnswer((_) async => _settledMount());

        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRa,
          targetDec: targetDec,
          solverConfig: solverConfig,
          config: const CenteringConfig(maxIterations: 2),
        );

        expect(
          result.success,
          isTrue,
          reason: 'Healthy mount must complete centering normally',
        );
        expect(result.errorMessage, isNull);
        expect(result.iterations, equals(2));
      });

      test('post-slew poll: single transient failure recovers, does not '
          'escalate (regression — must not be over-aggressive)', () async {
        const targetRa = 10.0;
        const targetDec = 45.0;
        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        stubTwoIterationPlateSolve(targetRa, targetDec);

        // Throw once, then return settled. The escalation threshold is 6
        // CONSECUTIVE failures, so a single blip must NOT abort centering.
        var calls = 0;
        mt.when(() => pollBackend.getMountStatus(mt.any())).thenAnswer((
          _,
        ) async {
          calls++;
          if (calls == 1) {
            throw Exception('transient I/O blip');
          }
          return _settledMount();
        });

        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRa,
          targetDec: targetDec,
          solverConfig: solverConfig,
          config: const CenteringConfig(maxIterations: 2),
        );

        expect(
          result.success,
          isTrue,
          reason:
              'A single transient query failure must not escalate; the '
              'poll loop must ride it out and continue.',
        );
        expect(
          calls,
          greaterThanOrEqualTo(2),
          reason: 'Loop must have polled at least twice (blip + recover)',
        );
      });

      test('post-slew poll: 6 consecutive failures -> centering aborts with '
          'CenteringMountUnresponsiveException', () async {
        const targetRa = 10.0;
        const targetDec = 45.0;
        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        // Only need the FIRST iteration to slew, then fail polling.
        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => buildPollFixtureImage());
        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) async {
          // Solver RA in DEGREES: 2 arcmin off = targetRa*15 + 120/3600.
          return PlateSolveResult(
            success: true,
            ra: targetRa * 15.0 + (120.0 / 3600.0),
            dec: targetDec,
            rotation: 0.0,
            pixelScale: 1.0,
            fieldWidth: 2.0,
            fieldHeight: 1.5,
            solveTimeSecs: 0.0,
            cd11: 0,
            cd12: 0,
            cd21: 0,
            cd22: 0,
            sipAOrder: 0,
            sipBOrder: 0,
            sipACoeffs: Float64List(0),
            sipBCoeffs: Float64List(0),
            sipApOrder: 0,
            sipBpOrder: 0,
            sipApCoeffs: Float64List(0),
            sipBpCoeffs: Float64List(0),
          );
        });
        when(
          mockDeviceService.slewMountToCoordinates(any, any),
        ).thenAnswer((_) async => {});

        // Every poll throws — escalation must trip at 6 consecutive
        // failures (3 seconds) instead of waiting the full 60s.
        //
        // NB: the live `MountStateNotifier` also polls `getMountStatus`
        // on its own 2s timer once the mount is "connected", so the raw
        // mock call count can drift above 6 by a tick or two. We assert
        // on the failure message + wall-clock budget instead.
        mt.when(() => pollBackend.getMountStatus(mt.any())).thenAnswer((
          _,
        ) async {
          throw Exception('mount disconnected');
        });

        final stopwatch = Stopwatch()..start();
        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRa,
          targetDec: targetDec,
          solverConfig: solverConfig,
          config: const CenteringConfig(maxIterations: 3),
        );
        stopwatch.stop();

        expect(result.success, isFalse);
        expect(result.errorMessage, isNotNull);
        expect(
          result.errorMessage,
          allOf(
            contains('6 times consecutively'),
            contains('aborting centering'),
            contains('disconnected or unresponsive'),
          ),
          reason: 'Failure must carry the typed exception message',
        );
        // Fail-fast: 6 ticks × 500ms = 3s for the poll loop, plus the
        // single exposure + slew of one iteration. Must come in well
        // under the 60s wall-clock cap.
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 15)),
          reason:
              'Must fail fast (~3s of poll ticks), not drag out the full '
              '60s wall-clock cap',
        );
      });

      test('post-slew poll: failure then success resets counter, polling '
          'continues', () async {
        const targetRa = 10.0;
        const targetDec = 45.0;
        const solverConfig = PlateSolverConfig(
          type: PlateSolverType.astap,
          executablePath: '/usr/bin/astap',
        );

        stubTwoIterationPlateSolve(targetRa, targetDec);

        // Pattern (per-call sequence on the mock): fail 5×, then settled.
        // If the consecutive-failure counter were NOT resetting, a
        // subsequent failure would compound and trip the threshold at
        // count=6. By following the 5 fails with a clean success we
        // prove the counter resets (centering completes successfully
        // instead of throwing CenteringMountUnresponsiveException).
        //
        // NB: `MountStateNotifier` also polls `getMountStatus` on its
        // own 2s timer, so additional unrelated calls can hit the mock.
        // We tolerate that by gating only the *first* 5 calls into the
        // failure phase and answering everything after that as settled.
        //
        // The contract under test is the SERVICE behavior (does
        // centering succeed?), not a precise mock call count.
        var sequenceCall = 0;
        mt.when(() => pollBackend.getMountStatus(mt.any())).thenAnswer((
          _,
        ) async {
          sequenceCall++;
          if (sequenceCall <= 5) {
            throw Exception('transient blip $sequenceCall');
          }
          return _settledMount();
        });

        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: targetRa,
          targetDec: targetDec,
          solverConfig: solverConfig,
          config: const CenteringConfig(maxIterations: 2),
        );

        expect(
          result.success,
          isTrue,
          reason:
              'Counter must reset on a successful poll. After 5 fails '
              'followed by a success, the next poll starts fresh — '
              'centering must complete normally (no escalation).',
        );
        // Sanity: confirm we actually exercised the failure path.
        expect(
          sequenceCall,
          greaterThanOrEqualTo(5),
          reason:
              'Mock must have been hit at least through the 5 fail '
              'sequence — otherwise the test is not exercising the '
              'counter-reset branch.',
        );
      });

      // Dedicated test for the bare exception type so the contract is
      // explicit and not just inferred from the failure message above.
      test(
        'CenteringMountUnresponsiveException carries diagnostic context',
        () {
          const e = CenteringMountUnresponsiveException(
            consecutiveFailures: 6,
            elapsed: Duration(seconds: 3),
            cause: 'mount disconnected',
          );
          expect(e.consecutiveFailures, equals(6));
          expect(e.elapsed, equals(const Duration(seconds: 3)));
          expect(e.cause, equals('mount disconnected'));
          final s = e.toString();
          expect(s, contains('6 times consecutively'));
          expect(s, contains('3.0s'));
          expect(s, contains('mount disconnected'));
        },
      );
    });

    group('plate-solve frames are not keepers', () {
      // Centering and verification frames are a MEANS (solve this pointing),
      // not a product. Routing them through captureImage wrote a full-size
      // light into the operator's light-frame folder and indexed it in
      // captured_images on EVERY iteration, inflating the night's frame and
      // integration totals with images nobody will ever stack.
      const solverConfig = PlateSolverConfig(
        type: PlateSolverType.astap,
        executablePath: '/usr/bin/astap',
      );

      PlateSolveResult onTarget(double raHours, double dec) => PlateSolveResult(
        success: true,
        ra: raHours * 15.0,
        dec: dec,
        rotation: 0.0,
        pixelScale: 1.0,
        fieldWidth: 2.0,
        fieldHeight: 1.5,
        solveTimeSecs: 0.0,
        cd11: 0,
        cd12: 0,
        cd21: 0,
        cd22: 0,
        sipAOrder: 0,
        sipBOrder: 0,
        sipACoeffs: Float64List(0),
        sipBCoeffs: Float64List(0),
        sipApOrder: 0,
        sipBpOrder: 0,
        sipApCoeffs: Float64List(0),
        sipBpCoeffs: Float64List(0),
      );

      void stubSolve(double raHours, double dec) {
        when(
          mockPlateSolveService.solveWithFallback(
            imagePath: anyNamed('imagePath'),
            hintRaHours: anyNamed('hintRaHours'),
            hintDecDegrees: anyNamed('hintDecDegrees'),
            searchRadiusDegrees: anyNamed('searchRadiusDegrees'),
            timeoutSeconds: anyNamed('timeoutSeconds'),
          ),
        ).thenAnswer((_) async => onTarget(raHours, dec));
      }

      test('centerOnTarget never uses the keeper capture path', () async {
        when(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).thenAnswer((_) async => _centeringImage());
        stubSolve(10.0, 45.0);

        final service = container.read(centeringServiceProvider);
        final result = await service.centerOnTarget(
          targetRa: 10.0,
          targetDec: 45.0,
          solverConfig: solverConfig,
        );

        expect(result.success, isTrue);
        verify(
          mockImagingService.captureUtilityFrame(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
          ),
        ).called(greaterThanOrEqualTo(1));
        verifyNever(
          mockImagingService.captureImage(
            settings: anyNamed('settings'),
            targetName: anyNamed('targetName'),
            frameNumber: anyNamed('frameNumber'),
            producingNodeId: anyNamed('producingNodeId'),
            producingRunId: anyNamed('producingRunId'),
          ),
        );
      });

      // A guider left guiding fights every correction slew and trails the
      // solve frames: on the rig (2026-10-20) a Slew & Center with PHD2
      // guiding converged only to 5.4" and timed out.
      group('a guider that is guiding', () {
        void connectGuider({required bool guiding}) {
          final guider = container.read(guiderStateProvider.notifier);
          guider.setConnecting('phd2', 'PHD2');
          guider.setConnected();
          guider.setGuiding(guiding);
        }

        Future<CenteringResult> center() {
          when(
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ).thenAnswer((_) async => _centeringImage());
          stubSolve(10.0, 45.0);
          return container
              .read(centeringServiceProvider)
              .centerOnTarget(
                targetRa: 10.0,
                targetDec: 45.0,
                solverConfig: solverConfig,
              );
        }

        test('is stopped before the first centering frame', () async {
          connectGuider(guiding: true);
          when(mockDeviceService.stopGuiding()).thenAnswer((_) async {});

          final result = await center();

          expect(result.success, isTrue);
          verifyInOrder([
            mockDeviceService.stopGuiding(),
            mockImagingService.captureUtilityFrame(
              settings: anyNamed('settings'),
              targetName: anyNamed('targetName'),
            ),
          ]);
        });

        test('an idle guider is left alone', () async {
          connectGuider(guiding: false);

          final result = await center();

          expect(result.success, isTrue);
          verifyNever(mockDeviceService.stopGuiding());
        });

        test('a guider that will not stop does not stop centering', () async {
          connectGuider(guiding: true);
          when(
            mockDeviceService.stopGuiding(),
          ).thenThrow(Exception('PHD2 did not answer'));

          final result = await center();

          expect(result.success, isTrue);
        });
      });
    });
  });
}

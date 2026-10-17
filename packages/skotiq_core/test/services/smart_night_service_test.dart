import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show TargetVisibilityInfo;

class _MockLoggingService extends Mock implements LoggingService {}

void main() {
  group('SmartNightService', () {
    late SmartNightService service;
    late EquipmentProfileModel monoProfile;
    late EquipmentProfileModel oscProfile;
    late EquipmentProfileModel narrowbandProfile;

    setUp(() {
      service = SmartNightService(
        suggestionService: TargetSuggestionService(
          loggingService: _MockLoggingService(),
        ),
        logging: _MockLoggingService(),
      );

      monoProfile = const EquipmentProfileModel(
        id: 1,
        name: 'ASI2600MM + RedCat 71',
        focalLength: 350,
        aperture: 71,
        focalRatio: 4.9,
        cameraName: 'ZWO ASI2600MM Pro',
        telescopeName: 'WO RedCat 71',
        mountName: 'ZWO AM5',
        defaultGain: 100,
        defaultOffset: 50,
        filterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
      );

      oscProfile = const EquipmentProfileModel(
        id: 2,
        name: 'ASI2600MC + RedCat 51',
        focalLength: 250,
        aperture: 51,
        focalRatio: 4.9,
        cameraName: 'ZWO ASI2600MC Pro',
        telescopeName: 'WO RedCat 51',
        mountName: 'ZWO AM3',
        defaultGain: 100,
        defaultOffset: 50,
        filterNames: ['L-eXtreme'],
      );

      narrowbandProfile = const EquipmentProfileModel(
        id: 3,
        name: 'ASI2600MM + FRA400 (narrowband only)',
        focalLength: 400,
        aperture: 72,
        focalRatio: 5.6,
        cameraName: 'ZWO ASI2600MM Pro',
        telescopeName: 'Askar FRA400',
        mountName: 'iOptron CEM40',
        defaultGain: 100,
        defaultOffset: 50,
        filterNames: ['Ha', 'OIII', 'SII'],
      );
    });

    TargetSuggestion fakeSuggestion({
      required int id,
      required String name,
      double ra = 10.0,
      double dec = 40.0,
      double score = 75.0,
      String objectType = 'Galaxy',
      DateTime? rise,
      DateTime? set,
      double peakAltitude = 65.0,
    }) {
      final start = rise ?? DateTime(2026, 5, 17, 22);
      final end = set ?? DateTime(2026, 5, 18, 5);
      return TargetSuggestion(
        targetId: id,
        targetName: name,
        raHours: ra,
        decDegrees: dec,
        totalScore: score,
        objectType: objectType,
        reasoning: 'High altitude, far from moon',
        visibility: TargetVisibilityInfo(
          currentAltitude: 50,
          currentAzimuth: 180,
          airmass: 1.4,
          peakAltitude: peakAltitude,
          riseTime: start,
          setTime: end,
          peakAltitudeTime: DateTime(2026, 5, 18, 1),
          moonDistance: 90,
          hoursAboveMinAlt: 6,
          transitTime: DateTime(2026, 5, 18, 1),
        ),
      );
    }

    SmartNightContext baseContext() {
      return SmartNightContext(
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        bortleClass: 4,
        rainOrCloudProbability: null,
      );
    }

    test('camera and filter group select gains on emitted exposures', () {
      for (final filters in [
        <String>['L', 'R', 'G', 'B'],
        <String>['Ha', 'SII', 'OIII'],
      ]) {
        final result = service.buildSingleTargetSequence(
          profile: monoProfile.copyWith(cameraName: 'ZWO ASI1600MM-Cool'),
          suggestion: fakeSuggestion(id: 1, name: 'Target'),
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          availableFilters: filters,
        );
        final plans = result.sequence.nodes.values
            .whereType<SmartExposureNode>()
            .single
            .plans;
        for (final plan in plans) {
          expect(plan.gain, filters.first == 'L' ? 76 : 139);
          expect(plan.offset, filters.first == 'L' ? 15 : 21);
        }
      }
      final result = service.buildSingleTargetSequence(
        profile: monoProfile.copyWith(cameraName: 'ZWO ASI1600MM-Cool'),
        suggestion: fakeSuggestion(id: 1, name: 'Target'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: const [],
        settings: const SmartNightSettings(
          gainOverride: 80,
          offsetOverride: 16,
        ),
      );
      final exposure = result.sequence.nodes.values
          .whereType<ExposureNode>()
          .single;
      expect(exposure.gain, 80);
      expect(exposure.offset, 16);
    });

    test('builds LRGB sequence from a single target', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      expect(plan.plannedTargets, hasLength(1));
      expect(plan.plannedTargets.first.suggestion.targetName, 'M51');
      // L+R+G+B filter rows
      expect(
        plan.plannedTargets.first.filterPlans.map((p) => p.filterName),
        containsAll(['L', 'R', 'G', 'B']),
      );

      // Sequence root must be an InstructionSetNode with children for
      // CoolCamera, Unpark, Target, WarmCamera, Park (5 mandatory).
      final root =
          plan.sequence.nodes[plan.sequence.rootNodeId] as InstructionSetNode;
      expect(root.childIds.length, greaterThanOrEqualTo(5));

      // Confirm at least one CoolCamera + one TargetHeader + one
      // SmartExposure + one ParkNode + one WarmCameraNode in the tree.
      expect(
        plan.sequence.nodes.values.whereType<CoolCameraNode>(),
        isNotEmpty,
      );
      expect(plan.sequence.nodes.values.whereType<UnparkNode>(), isNotEmpty);
      expect(
        plan.sequence.nodes.values.whereType<TargetHeaderNode>(),
        hasLength(1),
      );
      expect(
        plan.sequence.nodes.values.whereType<SmartExposureNode>(),
        hasLength(1),
      );
      expect(
        plan.sequence.nodes.values.whereType<WarmCameraNode>(),
        isNotEmpty,
      );
      expect(plan.sequence.nodes.values.whereType<ParkNode>(), isNotEmpty);
    });

    test('SmartNightPlan JSON round-trips for draft persistence', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext().copyWith(
          rainOrCloudProbability: 0.55,
          missingDarkLibraryNotes: const ['Missing 120s @ G100'],
        ),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(
          maxSessionHours: 6,
          subExposureFloorSecs: 45,
          subExposureCeilingSecs: 420,
          targetSnr: 42,
        ),
      );

      final restored = SmartNightPlan.fromJson(plan.toJson());

      expect(restored.sequence.name, plan.sequence.name);
      expect(restored.sequence.rootNodeId, isNotNull);
      expect(restored.sequence.nodes.length, plan.sequence.nodes.length);
      expect(restored.plannedTargets, hasLength(1));
      expect(restored.plannedTargets.first.suggestion.targetName, 'M51');
      expect(restored.plannedTargets.first.filterPlans, isNotEmpty);
      expect(
        restored.plannedTargets.first.filterPlans.first.recommendation?.seconds,
        plan.plannedTargets.first.filterPlans.first.recommendation?.seconds,
      );
      expect(restored.settings.subExposureFloorSecs, 45);
      expect(restored.settings.subExposureCeilingSecs, 420);
      expect(restored.settings.targetSnr, 42);
      expect(restored.context.rainOrCloudProbability, 0.55);
      expect(
        restored.context.missingDarkLibraryNotes,
        contains('Missing 120s @ G100'),
      );
      expect(restored.strategy, SmartNightStrategy.autoLrgb);
    });

    test('emits TargetSchedulerNode for >=3 targets', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [
          fakeSuggestion(id: 1, name: 'M31'),
          fakeSuggestion(id: 2, name: 'M81'),
          fakeSuggestion(id: 3, name: 'M51'),
        ],
        strategy: SmartNightStrategy.autoLrgb,
        // Short per-target budget so all 3 fit in the 7-hour window.
        settings: const SmartNightSettings(defaultIntegrationBudgetHours: 1.5),
      );

      // Three TargetHeaders should fit when each is only 1.5h.
      expect(
        plan.sequence.nodes.values.whereType<TargetHeaderNode>().length,
        equals(3),
      );
      // ...and exactly one TargetSchedulerNode wrapping them.
      expect(
        plan.sequence.nodes.values.whereType<TargetSchedulerNode>(),
        hasLength(1),
      );
    });

    test('build uses shared exposure context when supplied', () {
      final baseline = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );
      final lowFullWell = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(),
        exposureContext: const SmartNightExposureContext(
          camera: CameraExposureSpec(
            readNoiseE: 1.5,
            fullWellE: 2000,
            qePeak: 0.91,
          ),
          bortleClass: 4,
          focalLengthMm: 350,
          apertureMm: 71,
          pixelSizeMicrons: 2.4,
          availableFilterNames: ['L', 'R', 'G', 'B'],
          userCapSeconds: 300,
          floorSeconds: 10,
        ),
      );

      final baselineL = baseline.plannedTargets.first.filterPlans.firstWhere(
        (plan) => plan.filterName == 'L',
      );
      final lowFullWellL = lowFullWell.plannedTargets.first.filterPlans
          .firstWhere((plan) => plan.filterName == 'L');

      expect(
        lowFullWellL.recommendation!.allCeilings[ExposureLimitingFactor
            .saturation],
        lessThan(
          baselineL.recommendation!.allCeilings[ExposureLimitingFactor
              .saturation]!,
        ),
      );
    });

    test('narrowband-only profile + SHO strategy emits Ha+OIII+SII rows', () {
      final plan = service.build(
        profile: narrowbandProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [
          fakeSuggestion(
            id: 10,
            name: 'NGC 7000',
            objectType: 'Emission Nebula',
          ),
        ],
        strategy: SmartNightStrategy.narrowbandSho,
        settings: const SmartNightSettings(),
      );

      final smartExposure = plan.sequence.nodes.values
          .whereType<SmartExposureNode>()
          .single;
      final filterNames = smartExposure.plans.map((p) => p.filterName).toSet();
      expect(filterNames, containsAll(['Ha', 'OIII', 'SII']));
      // Does not include broadband.
      expect(filterNames.contains('L'), isFalse);
      expect(filterNames.contains('R'), isFalse);
    });

    test('OSC strategy works on a no-wheel profile', () {
      final plan = service.build(
        profile: oscProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [
          fakeSuggestion(
            id: 20,
            name: 'Heart Nebula',
            objectType: 'Emission Nebula',
          ),
        ],
        strategy: SmartNightStrategy.oscOneShot,
        settings: const SmartNightSettings(),
      );
      final smartExposure = plan.sequence.nodes.values
          .whereType<SmartExposureNode>()
          .single;
      expect(smartExposure.plans, hasLength(1));
      expect(smartExposure.plans.first.filterName, equals('L-eXtreme'));
    });

    test('rejects build with no targets', () {
      expect(
        () => service.build(
          profile: monoProfile,
          latitudeDeg: 41.0,
          longitudeDeg: -73.0,
          context: baseContext(),
          selectedSuggestions: const [],
          strategy: SmartNightStrategy.autoLrgb,
          settings: const SmartNightSettings(),
        ),
        throwsA(isA<SmartNightBuildException>()),
      );
    });

    test('rejects build with no location', () {
      expect(
        () => service.build(
          profile: monoProfile,
          latitudeDeg: 0.0,
          longitudeDeg: 0.0,
          context: baseContext(),
          selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
          strategy: SmartNightStrategy.autoLrgb,
          settings: const SmartNightSettings(),
        ),
        throwsA(isA<SmartNightBuildException>()),
      );
    });

    test('rejects mismatch between strategy and available filters', () {
      // OSC profile has no narrowband — picking SHO must fail loudly.
      expect(
        () => service.build(
          profile: oscProfile,
          latitudeDeg: 41.0,
          longitudeDeg: -73.0,
          context: baseContext(),
          selectedSuggestions: [fakeSuggestion(id: 1, name: 'NGC 7000')],
          strategy: SmartNightStrategy.narrowbandSho,
          settings: const SmartNightSettings(),
        ),
        throwsA(isA<SmartNightBuildException>()),
      );
    });

    test('adds polar alignment node when last alignment is stale', () {
      final context = SmartNightContext(
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        bortleClass: 4,
        daysSinceLastPolarAlignment: 30, // way past threshold
      );

      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: context,
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(),
      );

      expect(
        plan.sequence.nodes.values.whereType<PolarAlignmentNode>(),
        hasLength(1),
      );
      expect(plan.warnings.any((w) => w.contains('polar alignment')), isTrue);
    });

    test(
      'polar alignment node targets the correct celestial pole by latitude',
      () {
        SmartNightContext staleContext() => SmartNightContext(
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          bortleClass: 4,
          daysSinceLastPolarAlignment: 30,
        );

        PolarAlignmentNode polarNodeFor(double latitudeDeg) {
          final plan = service.build(
            profile: monoProfile,
            latitudeDeg: latitudeDeg,
            longitudeDeg: -73.0,
            context: staleContext(),
            selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
            strategy: SmartNightStrategy.autoLrgb,
            settings: const SmartNightSettings(),
          );
          return plan.sequence.nodes.values
              .whereType<PolarAlignmentNode>()
              .single;
        }

        // Northern site → north celestial pole.
        expect(polarNodeFor(41.0).isNorth, isTrue);
        // Southern site → south celestial pole (the bug being fixed).
        expect(polarNodeFor(-33.9).isNorth, isFalse);
      },
    );

    test('adds CloudArriving recovery node when rain forecast > 40%', () {
      final context = SmartNightContext(
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        bortleClass: 4,
        rainOrCloudProbability: 0.7,
      );

      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: context,
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(),
      );

      expect(
        plan.sequence.nodes.values.whereType<RecoveryNode>().any(
          (r) => r.triggerType == TriggerType.weatherUnsafe,
        ),
        isTrue,
      );
    });

    test('honors per-target integration budget setting', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(defaultIntegrationBudgetHours: 2.0),
      );

      final target = plan.plannedTargets.single;
      // Allow ~10% slack for rounding (count is floored against
      // per-filter ratio budget).
      expect(target.integrationSecs, lessThanOrEqualTo(2.0 * 3600 * 1.10));
    });

    test('appends flats group when profile has cover calibrator '
        'and includeFlatsAtEnd=true (with ADU-calibrated flat plan)', () {
      // Flats now require ADU-calibrated exposures (no blind 3s). Supply a
      // flat plan covering the LRGB rotation so the group is emitted.
      const flatPlan = SmartNightFlatPlan(
        perFilter: {
          'L': SmartNightFlatExposure(
            filterName: 'L',
            exposureSecs: 2.5,
            panelBrightness: 90,
            histogramTargetPercent: 50,
            actualAdu: 32000,
          ),
          'R': SmartNightFlatExposure(
            filterName: 'R',
            exposureSecs: 3.5,
            panelBrightness: 90,
            histogramTargetPercent: 50,
            actualAdu: 31000,
          ),
          'G': SmartNightFlatExposure(
            filterName: 'G',
            exposureSecs: 4.5,
            panelBrightness: 90,
            histogramTargetPercent: 50,
            actualAdu: 30000,
          ),
          'B': SmartNightFlatExposure(
            filterName: 'B',
            exposureSecs: 6.0,
            panelBrightness: 90,
            histogramTargetPercent: 50,
            actualAdu: 29000,
          ),
        },
        uncalibratedFilters: [],
      );
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(hasCoverCalibrator: true),
        flatPlan: flatPlan,
      );

      // Calibrator on, change filter, flats, calibrator off.
      expect(
        plan.sequence.nodes.values.whereType<CalibratorOnNode>(),
        isNotEmpty,
      );
      expect(
        plan.sequence.nodes.values.whereType<CalibratorOffNode>(),
        isNotEmpty,
      );
      final flatExposures = plan.sequence.nodes.values
          .whereType<ExposureNode>()
          .where((n) => n.frameType == FrameType.flat);
      expect(flatExposures, isNotEmpty);
      // None of them is a blind 3.0s exposure: each comes from a calibration.
      expect(flatExposures.every((n) => n.durationSecs != 3.0), isTrue);
    });

    test('emits an empty-plan exception when no target window fits', () {
      // Window is 5 minutes long → too short for any target.
      final tightContext = SmartNightContext(
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 17, 22, 5),
        bortleClass: 4,
      );
      expect(
        () => service.build(
          profile: monoProfile,
          latitudeDeg: 41.0,
          longitudeDeg: -73.0,
          context: tightContext,
          selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
          strategy: SmartNightStrategy.autoLrgb,
          settings: const SmartNightSettings(),
        ),
        throwsA(isA<SmartNightBuildException>()),
      );
    });

    test('emitted sequence passes structural invariants', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [
          fakeSuggestion(id: 1, name: 'M31'),
          fakeSuggestion(id: 2, name: 'M81'),
          fakeSuggestion(id: 3, name: 'M51'),
        ],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(),
      );
      expect(plan.sequence.invariants(), isEmpty);
    });

    test('adds simulator warning when emitted plan overruns dark window', () {
      final tightContext = SmartNightContext(
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 0),
        bortleClass: 4,
      );

      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: tightContext,
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(defaultIntegrationBudgetHours: 2.0),
      );

      expect(
        plan.warnings.any((w) => w.contains('after the dark window ends')),
        isTrue,
      );
    });

    test('Smart Exposure node embeds per-target integration budget', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(),
      );
      final header = plan.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .single;
      expect(header.integrationBudget, isNotNull);
      expect(header.integrationBudget!.isActive, isTrue);
      // SmartExposure carries its own budget too.
      final smart = plan.sequence.nodes.values
          .whereType<SmartExposureNode>()
          .single;
      expect(smart.integrationBudgetSecs, greaterThan(0));
    });

    test('calculateWindow returns sensible bounds at NY latitude', () {
      final w = service.calculateWindow(
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        now: DateTime(2026, 5, 17, 14), // mid-afternoon
      );
      expect(w.start.isBefore(w.end), isTrue);
      // Should be at least 4 hours of dark window in mid-May at lat 41
      expect(w.end.difference(w.start).inHours, greaterThanOrEqualTo(4));
    });

    test('calculateWindow rejects polar midnight sun as a dark window', () {
      expect(
        () => service.calculateWindow(
          latitudeDeg: 69.65,
          longitudeDeg: 18.96,
          now: DateTime(2026, 6, 21, 14),
        ),
        throwsA(
          isA<SmartNightBuildException>().having(
            (error) => error.message,
            'message',
            contains('Sun does not set'),
          ),
        ),
      );
    });

    test('calculateWindow keeps a conservative window during polar night', () {
      final window = service.calculateWindow(
        latitudeDeg: 89.0,
        longitudeDeg: 0.0,
        now: DateTime(2026, 12, 21, 14),
      );

      expect(window.start.hour, 21);
      expect(window.end.difference(window.start), const Duration(hours: 8));
    });

    test('previewTargetIntegration scales with per-target imaging window', () {
      const exposureContext = SmartNightExposureContext(
        camera: CameraExposureSpec(
          readNoiseE: 1.5,
          fullWellE: 2000,
          qePeak: 0.91,
        ),
        bortleClass: 4,
        focalLengthMm: 350,
        apertureMm: 71,
        pixelSizeMicrons: 2.4,
        availableFilterNames: ['L', 'R', 'G', 'B'],
        userCapSeconds: 300,
        floorSeconds: 10,
      );
      const settings = SmartNightSettings(
        defaultIntegrationBudgetHours: 8,
        subExposureFloorSecs: 1,
      );
      final windowStart = DateTime(2026, 5, 17, 22);
      final windowEnd = DateTime(2026, 5, 18, 5);

      TargetSuggestion suggestionWithHours(double hours) {
        return TargetSuggestion(
          targetId: hours.hashCode,
          targetName: 'Target $hours',
          raHours: 10,
          decDegrees: 40,
          totalScore: 80,
          objectType: 'Galaxy',
          visibility: TargetVisibilityInfo(
            currentAltitude: 50,
            currentAzimuth: 180,
            airmass: 1.4,
            peakAltitude: 70,
            riseTime: windowStart,
            setTime: windowEnd,
            moonDistance: 90,
            hoursAboveMinAlt: hours,
          ),
        );
      }

      final longWindow = service.previewTargetIntegration(
        profile: monoProfile,
        suggestion: suggestionWithHours(6),
        windowStart: windowStart,
        windowEnd: windowEnd,
        availableFilters: monoProfile.filterNames,
        exposureContext: exposureContext,
        settings: settings,
      );
      final shortWindow = service.previewTargetIntegration(
        profile: monoProfile,
        suggestion: suggestionWithHours(2),
        windowStart: windowStart,
        windowEnd: windowEnd,
        availableFilters: monoProfile.filterNames,
        exposureContext: exposureContext,
        settings: settings,
      );

      expect(longWindow, isNotNull);
      expect(shortWindow, isNotNull);
      expect(
        longWindow!.estimatedIntegrationHours,
        greaterThan(shortWindow!.estimatedIntegrationHours),
      );
    });

    test('buildSingleTargetSequence emits LRGB SmartExposure for galaxy', () {
      final result = service.buildSingleTargetSequence(
        profile: monoProfile,
        suggestion: fakeSuggestion(id: 1, name: 'M51'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: monoProfile.filterNames,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      expect(result.strategy, SmartNightStrategy.autoLrgb);
      expect(
        result.filterPlans.map((p) => p.filterName),
        containsAll(['L', 'R', 'G', 'B']),
      );

      final smartExposure = result.sequence.nodes.values
          .whereType<SmartExposureNode>()
          .single;
      expect(smartExposure.rotateFilters, isTrue);
      expect(
        smartExposure.plans.map((p) => p.filterName),
        containsAll(['L', 'R', 'G', 'B']),
      );
      expect(result.sequence.nodes.values.whereType<SlewNode>(), isNotEmpty);
      expect(
        result.sequence.nodes.values.whereType<AutofocusNode>(),
        isNotEmpty,
      );
    });

    test('buildSingleTargetSequence infers SHO for emission nebula', () {
      final result = service.buildSingleTargetSequence(
        profile: narrowbandProfile,
        suggestion: fakeSuggestion(
          id: 10,
          name: 'NGC 7000',
          objectType: 'Emission Nebula',
        ),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: narrowbandProfile.filterNames,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      expect(result.strategy, SmartNightStrategy.narrowbandSho);
      expect(
        result.filterPlans.map((p) => p.filterName),
        containsAll(['Ha', 'OIII', 'SII']),
      );
    });

    test('buildSingleTargetSequence with only L filter emits single plan', () {
      const lOnlyProfile = EquipmentProfileModel(
        id: 4,
        name: 'L-only rig',
        focalLength: 350,
        aperture: 71,
        cameraName: 'ZWO ASI2600MM Pro',
        filterNames: ['L'],
      );

      final result = service.buildSingleTargetSequence(
        profile: lOnlyProfile,
        suggestion: fakeSuggestion(id: 1, name: 'M51'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: lOnlyProfile.filterNames,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      expect(result.filterPlans, hasLength(1));
      expect(result.filterPlans.single.filterName, 'L');
      expect(
        result.sequence.nodes.values
            .whereType<SmartExposureNode>()
            .single
            .plans,
        hasLength(1),
      );
    });

    group('no filter wheel', () {
      const noFilterProfile = EquipmentProfileModel(
        id: 20,
        name: 'OSC, no filter wheel',
        focalLength: 250,
        aperture: 51,
        cameraName: 'ZWO ASI2600MC Pro',
      );

      test('buildSingleTargetSequence plans a single unfiltered row', () {
        final result = service.buildSingleTargetSequence(
          profile: noFilterProfile,
          suggestion: fakeSuggestion(id: 1, name: 'M51'),
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          availableFilters: const [],
          settings: const SmartNightSettings(subExposureFloorSecs: 1),
        );

        expect(result.strategy, SmartNightStrategy.oscOneShot);
        expect(result.filterPlans, hasLength(1));
        expect(result.filterPlans.single.filterName, isEmpty);
        expect(result.filterPlans.single.count, greaterThan(0));
      });

      test('unfiltered sequence emits no filter-change instruction', () {
        final result = service.buildSingleTargetSequence(
          profile: noFilterProfile,
          suggestion: fakeSuggestion(id: 1, name: 'M51'),
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          availableFilters: const [],
          settings: const SmartNightSettings(subExposureFloorSecs: 1),
        );

        final nodes = result.sequence.nodes.values;
        expect(nodes.whereType<FilterChangeNode>(), isEmpty);
        expect(nodes.whereType<SmartExposureNode>(), isEmpty);
        expect(
          nodes.every(
            (node) => !node.requiredDevices.contains(DeviceType.filterWheel),
          ),
          isTrue,
        );

        final lights = nodes
            .whereType<ExposureNode>()
            .where((n) => n.frameType == FrameType.light)
            .toList();
        expect(lights, hasLength(1));
        expect(lights.single.filter, isNull);
        expect(lights.single.filterIndex, isNull);
        expect(lights.single.count, greaterThan(0));
        expect(lights.single.durationSecs, greaterThan(0));
      });

      test('unfiltered target header keeps an integration budget', () {
        final result = service.buildSingleTargetSequence(
          profile: noFilterProfile,
          suggestion: fakeSuggestion(id: 1, name: 'M51'),
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          availableFilters: const [],
          settings: const SmartNightSettings(subExposureFloorSecs: 1),
        );

        final header = result.sequence.nodes.values
            .whereType<TargetHeaderNode>()
            .single;
        expect(header.integrationBudget, isNotNull);
        expect(header.integrationBudget!.isActive, isTrue);
        expect(header.integrationBudget!.perFilter.keys, ['']);
      });

      test('previewTargetIntegration estimates an unfiltered night', () {
        final preview = service.previewTargetIntegration(
          profile: noFilterProfile,
          suggestion: fakeSuggestion(id: 1, name: 'M51'),
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          availableFilters: const [],
          settings: const SmartNightSettings(subExposureFloorSecs: 1),
        );

        expect(preview, isNotNull);
        expect(preview!.estimatedIntegrationHours, greaterThan(0));
        expect(preview.filterNames, ['']);
      });

      test('sequence description names the unfiltered plan', () {
        final result = service.buildSingleTargetSequence(
          profile: noFilterProfile,
          suggestion: fakeSuggestion(id: 1, name: 'M51'),
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          availableFilters: const [],
          settings: const SmartNightSettings(subExposureFloorSecs: 1),
        );

        expect(result.sequence.description, contains('no filter'));
        expect(result.plannedTarget.rationale, contains('no filter'));
      });

      test('a profile whose filters miss the strategy still fails loud', () {
        expect(
          () => service.buildSingleTargetSequence(
            profile: narrowbandProfile,
            suggestion: fakeSuggestion(id: 1, name: 'M51'),
            windowStart: DateTime(2026, 5, 17, 22),
            windowEnd: DateTime(2026, 5, 18, 5),
            availableFilters: narrowbandProfile.filterNames,
            strategy: SmartNightStrategy.monoLrgb,
            settings: const SmartNightSettings(subExposureFloorSecs: 1),
          ),
          throwsA(
            isA<SmartNightBuildException>().having(
              (e) => e.message,
              'message',
              contains('matched the available filter list'),
            ),
          ),
        );
      });
    });

    test(
      'full-window captures repeat until the cutoff, then warm and park',
      () {
        final end = DateTime(2026, 5, 18, 5);
        for (final filters in [monoProfile.filterNames, <String>[]]) {
          final result = service.buildSingleTargetSequence(
            profile: monoProfile,
            suggestion: fakeSuggestion(id: 1, name: 'M51'),
            windowStart: DateTime(2026, 5, 17, 22),
            windowEnd: end,
            availableFilters: filters,
            fillWindow: true,
            includeSessionShutdown: true,
          );
          final nodes = result.sequence.nodes;
          final header = nodes.values.whereType<TargetHeaderNode>().single;
          expect(header.endBefore, end);
          expect(header.integrationBudget!.stopOnBudgetMet, isFalse);
          if (filters.isEmpty) {
            final loop = nodes.values.whereType<LoopNode>().single;
            expect(loop.repeatUntil, end);
            expect(loop.conditionType, LoopConditionType.untilTime);
            expect(nodes[loop.childIds.single], isA<ExposureNode>());
          } else {
            final exposure = nodes.values.whereType<SmartExposureNode>().single;
            expect(exposure.loopUntilStopped, isTrue);
            expect(exposure.integrationBudgetSecs, 0);
          }
          final children = nodes[result.sequence.rootNodeId]!.childIds
              .map((id) => nodes[id])
              .toList();
          expect(children[children.length - 2], isA<WarmCameraNode>());
          expect(children.last, isA<ParkNode>());
          expect(nodes.values.whereType<CoolCameraNode>(), isEmpty);
        }
      },
    );

    test('shutdown can be disabled independently of startup', () {
      final result = service.buildSingleTargetSequence(
        profile: monoProfile,
        suggestion: fakeSuggestion(id: 1, name: 'M51'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: monoProfile.filterNames,
        includeSessionPreamble: true,
        includeSessionShutdown: false,
      );
      expect(
        result.sequence.nodes.values.whereType<CoolCameraNode>(),
        isNotEmpty,
      );
      expect(result.sequence.nodes.values.whereType<ParkNode>(), isEmpty);
      expect(result.sequence.nodes.values.whereType<WarmCameraNode>(), isEmpty);
    });

    test(
      'recipe exposures survive generation without collapsing to the floor',
      () {
        final result = service.buildSingleTargetSequence(
          profile: monoProfile,
          suggestion: fakeSuggestion(id: 1, name: 'M51'),
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          availableFilters: monoProfile.filterNames,
          settings: const SmartNightSettings(
            useExposurePresets: true,
            defaultFrameDurationSecs: {'L': 120, 'R': 180, 'G': 180, 'B': 180},
          ),
        );
        expect(result.filterPlans.map((p) => p.durationSecs), [
          120,
          180,
          180,
          180,
        ]);
        expect(
          SmartNightSettings.fromJson(
            const SmartNightSettings(useExposurePresets: true).toJson(),
          ).useExposurePresets,
          isTrue,
        );
      },
    );

    test('generated lights carry the selected camera gain and offset', () {
      for (final filters in [monoProfile.filterNames, <String>[]]) {
        final result = service.buildSingleTargetSequence(
          profile: monoProfile,
          suggestion: fakeSuggestion(id: 1, name: 'M51'),
          windowStart: DateTime(2026, 5, 17, 22),
          windowEnd: DateTime(2026, 5, 18, 5),
          availableFilters: filters,
        );
        final nodes = result.sequence.nodes.values;
        if (filters.isEmpty) {
          final light = nodes.whereType<ExposureNode>().single;
          expect(light.gain, 100);
          expect(light.offset, 50);
        } else {
          for (final row in nodes.whereType<SmartExposureNode>().single.plans) {
            expect(row.gain, 100);
            expect(row.offset, 50);
          }
        }
      }
    });

    test('integration goals merge with budget fill for remaining filters', () {
      final goals = [
        IntegrationGoalProgress(
          goal: IntegrationGoal(
            id: 1,
            targetId: 1,
            filter: 'L',
            exposureSeconds: 120,
            frameCount: 40,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          capturedCount: 10,
        ),
        IntegrationGoalProgress(
          goal: IntegrationGoal(
            id: 2,
            targetId: 1,
            filter: 'Ha',
            exposureSeconds: 300,
            frameCount: 20,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          capturedCount: 20,
        ),
      ];

      final result = service.buildSingleTargetSequence(
        profile: monoProfile,
        suggestion: fakeSuggestion(id: 1, name: 'M51'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: monoProfile.filterNames,
        integrationGoalProgress: goals,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      final filterNames = result.filterPlans.map((p) => p.filterName).toList();
      expect(filterNames, contains('L'));
      expect(filterNames, containsAll(['R', 'G', 'B']));
      expect(filterNames, isNot(contains('Ha')));

      final lPlan = result.filterPlans.firstWhere((p) => p.filterName == 'L');
      expect(lPlan.count, 30);
      expect(lPlan.durationSecs, 120);
    });

    test('partial LRGB wheel emits L R G without B', () {
      const partialLrgbProfile = EquipmentProfileModel(
        id: 5,
        name: 'Partial LRGB',
        focalLength: 350,
        aperture: 71,
        cameraName: 'ZWO ASI2600MM Pro',
        filterNames: ['L', 'R', 'G'],
      );

      final result = service.buildSingleTargetSequence(
        profile: partialLrgbProfile,
        suggestion: fakeSuggestion(id: 1, name: 'M51'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: partialLrgbProfile.filterNames,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      expect(
        result.filterPlans.map((p) => p.filterName),
        containsAll(['L', 'R', 'G']),
      );
      expect(result.filterPlans.map((p) => p.filterName), isNot(contains('B')));
    });

    test('buildSingleTargetSequence infers HOO for emission nebula', () {
      const hooProfile = EquipmentProfileModel(
        id: 6,
        name: 'HOO rig',
        focalLength: 400,
        aperture: 72,
        cameraName: 'ZWO ASI2600MM Pro',
        filterNames: ['Ha', 'OIII'],
      );

      final result = service.buildSingleTargetSequence(
        profile: hooProfile,
        suggestion: fakeSuggestion(
          id: 10,
          name: 'Heart Nebula',
          objectType: 'Emission Nebula',
        ),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: hooProfile.filterNames,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      expect(result.strategy, SmartNightStrategy.narrowbandHoo);
      expect(
        result.filterPlans.map((p) => p.filterName),
        containsAll(['Ha', 'OIII']),
      );
    });

    test('StartGuiding omitted when profile has no guider', () {
      const noGuiderProfile = EquipmentProfileModel(
        id: 7,
        name: 'No guider',
        focalLength: 350,
        aperture: 71,
        cameraName: 'ZWO ASI2600MM Pro',
        filterNames: ['L'],
      );

      final result = service.buildSingleTargetSequence(
        profile: noGuiderProfile,
        suggestion: fakeSuggestion(id: 1, name: 'M51'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: noGuiderProfile.filterNames,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      expect(
        result.sequence.nodes.values.whereType<StartGuidingNode>(),
        isEmpty,
      );
    });

    test('StartGuiding included when profile has guider configured', () {
      const guiderProfile = EquipmentProfileModel(
        id: 8,
        name: 'With guider',
        focalLength: 350,
        aperture: 71,
        cameraName: 'ZWO ASI2600MM Pro',
        filterNames: ['L'],
        guiderId: 'phd2',
        guiderName: 'PHD2',
      );

      final result = service.buildSingleTargetSequence(
        profile: guiderProfile,
        suggestion: fakeSuggestion(id: 1, name: 'M51'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: guiderProfile.filterNames,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );

      expect(
        result.sequence.nodes.values.whereType<StartGuidingNode>(),
        isNotEmpty,
      );
      final target = result.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .single;
      final targetChildren = target.childIds
          .map((id) => result.sequence.nodes[id])
          .toList();
      final autofocusIndex = targetChildren.indexWhere(
        (node) => node is AutofocusNode,
      );
      final guidingIndex = targetChildren.indexWhere(
        (node) => node is StartGuidingNode,
      );
      expect(autofocusIndex, isNonNegative);
      expect(guidingIndex, isNonNegative);
      expect(autofocusIndex, lessThan(guidingIndex));
    });

    test('includeSessionPreamble adds cool unpark warm park nodes', () {
      final result = service.buildSingleTargetSequence(
        profile: monoProfile,
        suggestion: fakeSuggestion(id: 1, name: 'M51'),
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        availableFilters: ['L'],
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
        includeSessionPreamble: true,
      );

      expect(
        result.sequence.nodes.values.whereType<CoolCameraNode>(),
        isNotEmpty,
      );
      expect(result.sequence.nodes.values.whereType<UnparkNode>(), isNotEmpty);
      expect(
        result.sequence.nodes.values.whereType<WarmCameraNode>(),
        isNotEmpty,
      );
      expect(result.sequence.nodes.values.whereType<ParkNode>(), isNotEmpty);
    });

    // Auto-schedule missing darks

    SmartNightContext darkGapContext({
      List<DarkFrameRequirement> requirements = const [],
      List<String> notes = const [],
    }) {
      return SmartNightContext(
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        bortleClass: 4,
        missingDarkLibraryNotes: notes,
        missingDarkRequirements: requirements,
      );
    }

    Iterable<ExposureNode> darkExposures(SmartNightPlan plan) => plan
        .sequence
        .nodes
        .values
        .whereType<ExposureNode>()
        .where((n) => n.frameType == FrameType.dark);

    test(
      'auto-schedule darks OFF: no dark nodes appended, warning preserved',
      () {
        final plan = service.build(
          profile: monoProfile,
          latitudeDeg: 41.0,
          longitudeDeg: -73.0,
          context: darkGapContext(
            notes: const ['gain=100, temp=-10C, duration=120s, binning=1x1'],
            requirements: const [
              DarkFrameRequirement(
                gain: 100,
                offset: 50,
                durationSecs: 120,
                binX: 1,
                binY: 1,
                targetTemp: -10,
              ),
            ],
          ),
          selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
          strategy: SmartNightStrategy.autoLrgb,
          settings: const SmartNightSettings(),
        );

        expect(darkExposures(plan), isEmpty);
        expect(
          plan.warnings.any((w) => w.contains('does not auto-schedule')),
          isTrue,
        );
        expect(
          plan.warnings.any(
            (w) => w.contains('Dark library refresh scheduled'),
          ),
          isFalse,
        );
      },
    );

    test('auto-schedule darks ON with no gaps: no dark nodes added '
        'and no dark library warning emitted', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: darkGapContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(autoScheduleMissingDarks: true),
      );

      expect(darkExposures(plan), isEmpty);
      expect(
        plan.warnings.any(
          (w) =>
              w.contains('does not auto-schedule') ||
              w.contains('Dark library refresh scheduled'),
        ),
        isFalse,
      );
    });

    test('auto-schedule darks ON with gaps: dark group is appended '
        'and informational warning replaces the gap-warning', () {
      const requirements = [
        DarkFrameRequirement(
          gain: 100,
          offset: 50,
          durationSecs: 120,
          binX: 1,
          binY: 1,
          targetTemp: -10,
        ),
        DarkFrameRequirement(
          gain: 100,
          offset: 50,
          durationSecs: 300,
          binX: 1,
          binY: 1,
          targetTemp: -10,
        ),
      ];
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: darkGapContext(
          notes: const [
            'gain=100, temp=-10C, duration=120s, binning=1x1',
            'gain=100, temp=-10C, duration=300s, binning=1x1',
          ],
          requirements: requirements,
        ),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(
          autoScheduleMissingDarks: true,
          darkFramesPerRequirement: 15,
        ),
      );

      // Two missing combinations × 15 frames each → two ExposureNodes,
      // one per combination, with FrameType.dark and count=15.
      final darks = darkExposures(plan).toList();
      expect(darks, hasLength(2));
      for (final node in darks) {
        expect(node.count, 15);
        expect(node.gain, 100);
        expect(node.offset, 50);
        expect(node.binning, BinningMode.one);
      }
      final durations = darks.map((n) => n.durationSecs).toSet();
      expect(durations, containsAll(<double>[120, 300]));

      // Dark group is its own InstructionSetNode named "Dark Library
      // Refresh…" — separable in the tree.
      final darkGroups = plan.sequence.nodes.values
          .whereType<InstructionSetNode>()
          .where((n) => n.name.startsWith('Dark Library Refresh'));
      expect(darkGroups, hasLength(1));

      // Informational warning is emitted (not the "does not auto-schedule"
      // text).
      expect(
        plan.warnings.any((w) => w.contains('does not auto-schedule')),
        isFalse,
      );
      expect(
        plan.warnings.any(
          (w) =>
              w.contains('Dark library refresh scheduled') &&
              w.contains('30 dark frames') &&
              w.contains('2 combinations'),
        ),
        isTrue,
      );
    });

    test('dark group sits AFTER the target headers and BEFORE WarmCamera '
        '— preserves cooled-sensor temperature for the darks', () {
      const requirements = [
        DarkFrameRequirement(
          gain: 100,
          offset: 50,
          durationSecs: 60,
          binX: 1,
          binY: 1,
          targetTemp: -10,
        ),
      ];
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: darkGapContext(requirements: requirements),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(autoScheduleMissingDarks: true),
      );

      final root =
          plan.sequence.nodes[plan.sequence.rootNodeId] as InstructionSetNode;
      final ids = root.childIds;
      String? darkGroupId;
      String? warmId;
      String? targetHeaderId;
      for (final id in ids) {
        final node = plan.sequence.nodes[id];
        if (node is InstructionSetNode &&
            node.name.startsWith('Dark Library Refresh')) {
          darkGroupId = id;
        } else if (node is WarmCameraNode) {
          warmId = id;
        } else if (node is TargetHeaderNode) {
          targetHeaderId = id;
        }
      }
      expect(darkGroupId, isNotNull);
      expect(warmId, isNotNull);
      expect(targetHeaderId, isNotNull);
      expect(ids.indexOf(targetHeaderId!), lessThan(ids.indexOf(darkGroupId!)));
      expect(ids.indexOf(darkGroupId), lessThan(ids.indexOf(warmId!)));
    });

    test('auto-schedule darks emits CloseCover/OpenCover when a cover '
        'calibrator is on the profile', () {
      const requirements = [
        DarkFrameRequirement(
          gain: 100,
          offset: 50,
          durationSecs: 60,
          binX: 1,
          binY: 1,
          targetTemp: -10,
        ),
      ];
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: darkGapContext(requirements: requirements),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(
          autoScheduleMissingDarks: true,
          hasCoverCalibrator: true,
          includeFlatsAtEnd: false,
        ),
      );

      // Close/Open cover nodes parented under the dark group exist.
      final darkGroup = plan.sequence.nodes.values
          .whereType<InstructionSetNode>()
          .firstWhere((n) => n.name.startsWith('Dark Library Refresh'));
      final children = darkGroup.childIds
          .map((id) => plan.sequence.nodes[id])
          .toList(growable: false);
      expect(children.whereType<CloseCoverNode>(), isNotEmpty);
      expect(children.whereType<OpenCoverNode>(), isNotEmpty);
    });

    test('auto-schedule darks emits a NotificationNode reminder '
        'when no cover calibrator is available', () {
      const requirements = [
        DarkFrameRequirement(
          gain: 100,
          offset: 50,
          durationSecs: 60,
          binX: 1,
          binY: 1,
          targetTemp: -10,
        ),
      ];
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: darkGapContext(requirements: requirements),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(autoScheduleMissingDarks: true),
      );

      final darkGroup = plan.sequence.nodes.values
          .whereType<InstructionSetNode>()
          .firstWhere((n) => n.name.startsWith('Dark Library Refresh'));
      final children = darkGroup.childIds
          .map((id) => plan.sequence.nodes[id])
          .toList(growable: false);
      final notifications = children.whereType<NotificationNode>().toList();
      expect(notifications, isNotEmpty);
      expect(notifications.first.title, contains('Cover the OTA'));
    });

    test('JSON round-trip preserves missingDarkRequirements + '
        'autoScheduleMissingDarks settings', () {
      const requirements = [
        DarkFrameRequirement(
          gain: 100,
          offset: 50,
          durationSecs: 180,
          binX: 1,
          binY: 1,
          targetTemp: -5,
        ),
      ];
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: darkGapContext(requirements: requirements),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(
          autoScheduleMissingDarks: true,
          darkFramesPerRequirement: 12,
        ),
      );

      final restored = SmartNightPlan.fromJson(plan.toJson());

      expect(restored.context.missingDarkRequirements, hasLength(1));
      final req = restored.context.missingDarkRequirements.single;
      expect(req.gain, 100);
      expect(req.offset, 50);
      expect(req.durationSecs, 180);
      expect(req.targetTemp, -5);
      expect(restored.settings.autoScheduleMissingDarks, isTrue);
      expect(restored.settings.darkFramesPerRequirement, 12);
    });

    // Guide-RMS threading into the tracking-limited ceiling

    SmartNightExposureContext guidedExposureContext({
      double? guideRmsArcsec,
      int guideSampleCount = 0,
    }) {
      return SmartNightExposureContext(
        camera: const CameraExposureSpec(
          readNoiseE: 1.4,
          fullWellE: 50000,
          qePeak: 0.8,
        ),
        bortleClass: 4,
        focalLengthMm: 400,
        apertureMm: 72,
        pixelSizeMicrons: 3.76,
        availableFilterNames: const ['Ha', 'OIII', 'SII'],
        guideRmsArcsec: guideRmsArcsec,
        guideSampleCount: guideSampleCount,
        userCapSeconds: 600,
        floorSeconds: 1,
      );
    }

    test('build() threads guide RMS from the exposure context into the '
        'mount-tracking ceiling (no "sparse" warning when RMS is known)', () {
      // A poor guide RMS with >= 3 samples must engage the mount ceiling and
      // shorten the sub-exposure. The context itself carries no guide history
      // (the wizard main path never populates it) — proving the fallback to
      // exposureContext is what makes the ceiling active. We assert on a
      // narrowband filter (Ha) where the dark-sky Glover ceiling is long, so
      // the mount ceiling is the binding constraint and the RMS difference is
      // observable.
      final emissionTarget = fakeSuggestion(
        id: 1,
        name: 'NGC 7000',
        objectType: 'Emission Nebula',
      );
      final tightPlan = service.build(
        profile: narrowbandProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [emissionTarget],
        strategy: SmartNightStrategy.narrowbandSho,
        settings: const SmartNightSettings(
          subExposureFloorSecs: 1,
          subExposureCeilingSecs: 600,
        ),
        exposureContext: guidedExposureContext(
          guideRmsArcsec: 3.0,
          guideSampleCount: 5,
        ),
      );

      // The "sparse history" warning must NOT appear — the RMS was threaded.
      expect(
        tightPlan.warnings.any(
          (w) => w.contains('guide-RMS history is sparse'),
        ),
        isFalse,
        reason:
            'guide RMS from the exposure context should activate the '
            'mount ceiling, so the sparse-history warning must not fire.',
      );

      // A pristine mount (very low RMS) must allow a LONGER sub-exposure than
      // a sloppy mount — confirming the ceiling actually scales with RMS.
      final loosePlan = service.build(
        profile: narrowbandProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [emissionTarget],
        strategy: SmartNightStrategy.narrowbandSho,
        settings: const SmartNightSettings(
          subExposureFloorSecs: 1,
          subExposureCeilingSecs: 600,
        ),
        exposureContext: guidedExposureContext(
          guideRmsArcsec: 0.3,
          guideSampleCount: 5,
        ),
      );

      double haFilterSecs(SmartNightPlan plan) => plan
          .plannedTargets
          .first
          .filterPlans
          .firstWhere((p) => p.filterName == 'Ha')
          .durationSecs;

      expect(
        haFilterSecs(tightPlan),
        lessThan(haFilterSecs(loosePlan)),
        reason:
            'a 3.0" RMS mount must cap the sub-exposure shorter than a '
            '0.3" RMS mount once the guide RMS is threaded through.',
      );
    });

    test('build() keeps the sparse-history warning when neither the context '
        'nor the exposure context carry guide RMS', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
        exposureContext: guidedExposureContext(),
      );

      expect(
        plan.warnings.any((w) => w.contains('guide-RMS history is sparse')),
        isTrue,
      );
    });

    // Pixel size must not silently fall back to 3.76um

    test('build() fails loud when pixel size is unknown (no exposure context '
        'and camera not in catalog)', () {
      const unknownCameraProfile = EquipmentProfileModel(
        id: 9,
        name: 'Mystery rig',
        focalLength: 600,
        aperture: 120,
        cameraName: 'Totally Unknown Sensor 9000',
        defaultGain: 100,
        defaultOffset: 30,
        filterNames: ['L', 'R', 'G', 'B'],
      );

      expect(
        () => service.build(
          profile: unknownCameraProfile,
          latitudeDeg: 41.0,
          longitudeDeg: -73.0,
          context: baseContext(),
          selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
          strategy: SmartNightStrategy.autoLrgb,
          settings: const SmartNightSettings(subExposureFloorSecs: 1),
          // No exposureContext → must NOT invent a 3.76um pitch.
        ),
        throwsA(
          isA<SmartNightBuildException>().having(
            (e) => e.message,
            'message',
            allOf(contains('pixel size'), contains('not in the bundled')),
          ),
        ),
      );
    });

    test('build() uses the catalog pixel size for a known camera without an '
        'exposure context (no silent 3.76um)', () {
      // monoProfile's camera ("ZWO ASI2600MM Pro") is in the bundled catalog,
      // so the build must succeed using the catalog pixel size — not throw,
      // and not depend on an exposure context.
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(subExposureFloorSecs: 1),
      );
      expect(plan.plannedTargets, hasLength(1));
    });

    // --- P1: auto-flats must use ADU-calibrated exposures, not blind 3s --

    test('build() emits a loud reminder instead of blind flats when no flat '
        'calibration is available', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(
          subExposureFloorSecs: 1,
          includeFlatsAtEnd: true,
          hasCoverCalibrator: true,
        ),
        // flatPlan omitted → no calibration data.
      );

      // No blind flat ExposureNode (frameType flat) should exist.
      final flatExposures = plan.sequence.nodes.values
          .whereType<ExposureNode>()
          .where((n) => n.frameType == FrameType.flat);
      expect(
        flatExposures,
        isEmpty,
        reason: 'must not emit blind flats without ADU calibration',
      );

      // A loud notification + a build warning must be present.
      expect(
        plan.sequence.nodes.values.whereType<NotificationNode>().any(
          (n) => n.title.contains('Automated flats skipped'),
        ),
        isTrue,
      );
      expect(
        plan.warnings.any((w) => w.contains('No ADU-calibrated flat exposure')),
        isTrue,
      );
    });

    test('build() emits ADU-calibrated flat exposures + calibrated panel '
        'brightness when a flat plan is supplied', () {
      const flatPlan = SmartNightFlatPlan(
        perFilter: {
          'L': SmartNightFlatExposure(
            filterName: 'L',
            exposureSecs: 2.5,
            panelBrightness: 90,
            histogramTargetPercent: 50,
            actualAdu: 32000,
          ),
          'R': SmartNightFlatExposure(
            filterName: 'R',
            exposureSecs: 4.0,
            panelBrightness: 90,
            histogramTargetPercent: 50,
            actualAdu: 31000,
          ),
          'G': SmartNightFlatExposure(
            filterName: 'G',
            exposureSecs: 7.5,
            panelBrightness: 140,
            histogramTargetPercent: 50,
            actualAdu: 33000,
          ),
        },
        uncalibratedFilters: ['B'],
      );

      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(
          subExposureFloorSecs: 1,
          includeFlatsAtEnd: true,
          hasCoverCalibrator: true,
          flatCountPerFilter: 15,
        ),
        flatPlan: flatPlan,
      );

      final flatExposures = plan.sequence.nodes.values
          .whereType<ExposureNode>()
          .where((n) => n.frameType == FrameType.flat)
          .toList();

      // Only the LRGB filters the target actually used AND that have a
      // calibration appear. The plan's M51 LRGB rotation uses L/R/G/B; B is
      // uncalibrated so it must NOT get a blind exposure.
      final flatFilters = flatExposures.map((n) => n.filter).toSet();
      expect(flatFilters, containsAll(<String>{'L', 'R', 'G'}));
      expect(flatFilters, isNot(contains('B')));

      // Each calibrated flat uses its calibrated exposure — never 3.0s.
      double durFor(String f) =>
          flatExposures.firstWhere((n) => n.filter == f).durationSecs;
      expect(durFor('L'), closeTo(2.5, 1e-9));
      expect(durFor('R'), closeTo(4.0, 1e-9));
      expect(durFor('G'), closeTo(7.5, 1e-9));
      for (final n in flatExposures) {
        expect(n.durationSecs, isNot(3.0));
        expect(n.count, 15);
      }

      // The panel is set to the calibrated brightness (90 and 140), never 128.
      final brightnesses = plan.sequence.nodes.values
          .whereType<CalibratorOnNode>()
          .map((n) => n.brightness)
          .toSet();
      expect(brightnesses, containsAll(<int>{90, 140}));
      expect(brightnesses, isNot(contains(128)));

      // The uncalibrated filter (B) triggers a loud reminder.
      expect(
        plan.sequence.nodes.values.whereType<NotificationNode>().any(
          (n) =>
              n.message.contains('B') &&
              n.title.contains('no calibrated flat exposure'),
        ),
        isTrue,
      );
    });

    test('build() lists each uncalibrated filter once, comma-separated, in '
        'sorted order in the reminder message', () {
      // Only L is ADU-calibrated, so the M51 LRGB rotation leaves R/G/B
      // uncalibrated. The reminder must enumerate them deduped and in the
      // same sorted, comma-separated order the emitter produces.
      const flatPlan = SmartNightFlatPlan(
        perFilter: {
          'L': SmartNightFlatExposure(
            filterName: 'L',
            exposureSecs: 2.5,
            panelBrightness: 90,
            histogramTargetPercent: 50,
            actualAdu: 32000,
          ),
        },
        uncalibratedFilters: ['R', 'G', 'B'],
      );

      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: baseContext(),
        selectedSuggestions: [fakeSuggestion(id: 1, name: 'M51')],
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(
          subExposureFloorSecs: 1,
          includeFlatsAtEnd: true,
          hasCoverCalibrator: true,
          flatCountPerFilter: 15,
        ),
        flatPlan: flatPlan,
      );

      final reminder = plan.sequence.nodes.values
          .whereType<NotificationNode>()
          .firstWhere((n) => n.title.contains('no calibrated flat exposure'));
      expect(reminder.message, contains('exists for: B, G, R.'));
    });
  });

  // Phase B (scheduler-activation): the emitted in-sequence TargetSchedulerNode
  // must carry the adaptive-swap threshold (default ON) and the operator's
  // site horizon mask. These are config values on the in-sequence node and
  // never touch the live SchedulerEngine's W1–W5 decision math.
  group('SmartNightService TargetScheduler presets (Phase B)', () {
    late SmartNightService service;
    late EquipmentProfileModel monoProfile;

    setUp(() {
      service = SmartNightService(
        suggestionService: TargetSuggestionService(
          loggingService: _MockLoggingService(),
        ),
        logging: _MockLoggingService(),
      );
      monoProfile = const EquipmentProfileModel(
        id: 1,
        name: 'ASI2600MM + RedCat 71',
        focalLength: 350,
        aperture: 71,
        focalRatio: 4.9,
        cameraName: 'ZWO ASI2600MM Pro',
        telescopeName: 'WO RedCat 71',
        mountName: 'ZWO AM5',
        defaultGain: 100,
        defaultOffset: 50,
        filterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
      );
    });

    TargetSuggestion suggestion({required int id, required String name}) {
      return TargetSuggestion(
        targetId: id,
        targetName: name,
        raHours: 10.0,
        decDegrees: 40.0,
        totalScore: 75.0,
        objectType: 'Galaxy',
        reasoning: 'High altitude, far from moon',
        visibility: TargetVisibilityInfo(
          currentAltitude: 50,
          currentAzimuth: 180,
          airmass: 1.4,
          peakAltitude: 65.0,
          riseTime: DateTime(2026, 5, 17, 22),
          setTime: DateTime(2026, 5, 18, 5),
          peakAltitudeTime: DateTime(2026, 5, 18, 1),
          moonDistance: 90,
          hoursAboveMinAlt: 6,
          transitTime: DateTime(2026, 5, 18, 1),
        ),
      );
    }

    SmartNightContext contextWith({HorizonProfile? horizon}) {
      return SmartNightContext(
        windowStart: DateTime(2026, 5, 17, 22),
        windowEnd: DateTime(2026, 5, 18, 5),
        bortleClass: 4,
        rainOrCloudProbability: null,
        horizonProfile: horizon,
      );
    }

    List<TargetSuggestion> threeTargets() => [
      suggestion(id: 1, name: 'M31'),
      suggestion(id: 2, name: 'M81'),
      suggestion(id: 3, name: 'M51'),
    ];

    test('preset default ON: emitted node carries swap threshold 80', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: contextWith(),
        selectedSuggestions: threeTargets(),
        strategy: SmartNightStrategy.autoLrgb,
        // Default settings: adaptiveTargetSwap is true out of the box.
        settings: const SmartNightSettings(defaultIntegrationBudgetHours: 1.5),
      );

      final scheduler = plan.sequence.nodes.values
          .whereType<TargetSchedulerNode>()
          .single;
      expect(
        scheduler.swapOnConditionsBelow,
        SmartNightSettings.adaptiveSwapConditionsFloor,
      );
      expect(scheduler.swapOnConditionsBelow, 80.0);
      // Recompute cadence is the self-driving default (5), not boundary-only.
      expect(scheduler.recomputeEveryNExposures, 5);
    });

    test('adaptiveTargetSwap=false leaves swap disabled (null)', () {
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: contextWith(),
        selectedSuggestions: threeTargets(),
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(
          defaultIntegrationBudgetHours: 1.5,
          adaptiveTargetSwap: false,
        ),
      );

      final scheduler = plan.sequence.nodes.values
          .whereType<TargetSchedulerNode>()
          .single;
      expect(scheduler.swapOnConditionsBelow, isNull);
    });

    test('emitted node carries the operator site horizon mask', () {
      const horizon = HorizonProfile(
        name: 'Backyard fence',
        samples: [
          HorizonSample(0.0, 20.0),
          HorizonSample(90.0, 35.0),
          HorizonSample(180.0, 15.0),
          HorizonSample(270.0, 30.0),
        ],
      );

      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: contextWith(horizon: horizon),
        selectedSuggestions: threeTargets(),
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(defaultIntegrationBudgetHours: 1.5),
      );

      final scheduler = plan.sequence.nodes.values
          .whereType<TargetSchedulerNode>()
          .single;
      expect(scheduler.horizonProfile, isNotNull);
      expect(scheduler.horizonProfile!.samples, hasLength(4));
      // The mask interpolates per-azimuth exactly like the live autopilot's
      // HorizonProfile.minAltitudeAt — spot-check a sample and a midpoint.
      expect(
        scheduler.horizonProfile!.minAltitudeAt(90.0),
        closeTo(35.0, 1e-9),
      );
      expect(
        scheduler.horizonProfile!.minAltitudeAt(45.0),
        closeTo(27.5, 1e-9),
      );
    });

    test(
      'no horizon in context leaves the node on a flat floor (null mask)',
      () {
        final plan = service.build(
          profile: monoProfile,
          latitudeDeg: 41.0,
          longitudeDeg: -73.0,
          context: contextWith(),
          selectedSuggestions: threeTargets(),
          strategy: SmartNightStrategy.autoLrgb,
          settings: const SmartNightSettings(
            defaultIntegrationBudgetHours: 1.5,
          ),
        );

        final scheduler = plan.sequence.nodes.values
            .whereType<TargetSchedulerNode>()
            .single;
        expect(scheduler.horizonProfile, isNull);
      },
    );

    test('SmartNightPlan JSON round-trips the swap preset + horizon mask', () {
      const horizon = HorizonProfile(
        name: 'Backyard fence',
        samples: [HorizonSample(0.0, 20.0), HorizonSample(180.0, 15.0)],
      );
      final plan = service.build(
        profile: monoProfile,
        latitudeDeg: 41.0,
        longitudeDeg: -73.0,
        context: contextWith(horizon: horizon),
        selectedSuggestions: threeTargets(),
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(defaultIntegrationBudgetHours: 1.5),
      );

      final restored = SmartNightPlan.fromJson(plan.toJson());
      final scheduler = restored.sequence.nodes.values
          .whereType<TargetSchedulerNode>()
          .single;
      expect(scheduler.swapOnConditionsBelow, 80.0);
      expect(scheduler.horizonProfile, isNotNull);
      expect(scheduler.horizonProfile!.samples, hasLength(2));
      expect(scheduler.horizonProfile!.name, 'Backyard fence');
      // The context's horizon profile also survives the round-trip.
      expect(restored.context.horizonProfile?.samples, hasLength(2));
    });
  });

  group('inferSmartNightStrategy', () {
    TargetSuggestion minimalSuggestion({
      required int id,
      required String name,
      String? objectType,
    }) {
      return TargetSuggestion(
        targetId: id,
        targetName: name,
        raHours: 10,
        decDegrees: 40,
        totalScore: 80,
        objectType: objectType,
        visibility: const TargetVisibilityInfo(
          currentAltitude: 50,
          currentAzimuth: 180,
          airmass: 1.4,
          moonDistance: 90,
        ),
      );
    }

    test('galaxy with LRGB filters picks autoLrgb', () {
      expect(
        inferSmartNightStrategy(
          minimalSuggestion(id: 1, name: 'M51', objectType: 'Galaxy'),
          const ['L', 'R', 'G', 'B'],
        ),
        SmartNightStrategy.autoLrgb,
      );
    });

    test('emission nebula with SHO filters picks narrowbandSho', () {
      expect(
        inferSmartNightStrategy(
          minimalSuggestion(
            id: 2,
            name: 'NGC 7000',
            objectType: 'Emission Nebula',
          ),
          const ['Ha', 'OIII', 'SII'],
        ),
        SmartNightStrategy.narrowbandSho,
      );
    });

    test('planetary nebula on mixed rig picks LRGB not SHO', () {
      expect(
        inferSmartNightStrategy(
          minimalSuggestion(id: 4, name: 'M57', objectType: 'Planetary Nebula'),
          const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
        ),
        SmartNightStrategy.autoLrgb,
      );
    });

    test('reflection nebula on mixed rig picks LRGB not SHO', () {
      expect(
        inferSmartNightStrategy(
          minimalSuggestion(
            id: 5,
            name: 'M45',
            objectType: 'Reflection Nebula',
          ),
          const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
        ),
        SmartNightStrategy.autoLrgb,
      );
    });

    test('generic nebula label without emission does not force SHO', () {
      expect(
        inferSmartNightStrategy(
          minimalSuggestion(id: 6, name: 'NGC 2244', objectType: 'Nebula'),
          const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
        ),
        SmartNightStrategy.autoLrgb,
      );
    });

    test('single filter rig picks oscOneShot', () {
      expect(
        inferSmartNightStrategy(
          minimalSuggestion(id: 3, name: 'M42', objectType: 'Emission Nebula'),
          const ['L-eXtreme'],
        ),
        SmartNightStrategy.oscOneShot,
      );
    });
  });

  group('latitudeSign', () {
    test('northern latitudes resolve to north celestial pole', () {
      expect(latitudeSign(41.0), isTrue);
      expect(latitudeSign(0.1), isTrue);
    });

    test('southern latitudes resolve to south celestial pole', () {
      expect(latitudeSign(-33.9), isFalse);
      expect(latitudeSign(-0.1), isFalse);
    });

    test('exact equator and unknown latitude fall back to north', () {
      expect(latitudeSign(0.0), isTrue);
      expect(latitudeSign(null), isTrue);
      expect(latitudeSign(double.nan), isTrue);
    });
  });
}

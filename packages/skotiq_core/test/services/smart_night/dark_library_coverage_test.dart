import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('SmartNightDarkLibraryCoverage', () {
    late SkotiqDatabase database;
    late SmartNightDarkLibraryCoverage coverage;

    const profile = EquipmentProfileModel(
      id: 1,
      name: 'Mono rig',
      focalLength: 350,
      aperture: 71,
      cameraName: 'ZWO ASI2600MM Pro',
      defaultGain: 100,
      defaultOffset: 50,
      defaultBinX: 1,
      defaultBinY: 1,
      defaultCoolingTemp: -10,
      filterNames: ['L', 'R', 'G', 'B'],
    );
    const exposureContext = SmartNightExposureContext(
      camera: CameraExposureSpec(
        readNoiseE: 1.4,
        fullWellE: 50000,
        qePeak: 0.8,
      ),
      bortleClass: 3,
      focalLengthMm: 350,
      apertureMm: 71,
      pixelSizeMicrons: 3.76,
      availableFilterNames: ['L', 'R', 'G', 'B'],
      userCapSeconds: 245,
      floorSeconds: 45,
    );

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      coverage = SmartNightDarkLibraryCoverage(
        darkLibraryService: DarkLibraryService(DarkLibraryDao(database)),
      );
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'uses Smart Night exposure recommendations for required durations',
      () async {
        final expectedDuration = exposureContext
            .recommendForFilter('L')
            .seconds
            .toStringAsFixed(0);

        final notes = await coverage.missingNotes(
          profile: profile,
          strategy: SmartNightStrategy.oscOneShot,
          settings: const SmartNightSettings(),
          exposureContext: exposureContext,
          minCoverage: 10,
        );

        expect(notes, isNotEmpty);
        expect(notes.first, contains('duration=${expectedDuration}s'));
        if (expectedDuration != '120') {
          expect(notes.first, isNot(contains('duration=120s')));
        }
      },
    );

    test('returns no notes when a matching master exists', () async {
      // L / R / G / B no longer share a single exposure: the calculator now
      // models per-channel sky brightness (blue sees the darkest sky and needs
      // the longest sub), so an autoLrgb plan requires a dark master at each
      // distinct duration. Seed one master per unique required duration so the
      // library is genuinely fully covered.
      final dao = DarkLibraryDao(database);
      final requiredDurations = <double>{
        for (final filter in const ['L', 'R', 'G', 'B'])
          exposureContext.recommendForFilter(filter).seconds,
      };
      var index = 0;
      for (final duration in requiredDurations) {
        await dao.addEntry(
          DarkLibraryCompanion.insert(
            filePath: '/tmp/master_$index.fits',
            exposureTime: duration,
            frameType: const Value('dark'),
            temperature: const Value(-10),
            gain: const Value(100),
            offset: const Value(50),
            binX: const Value(1),
            binY: const Value(1),
            masterDarkPath: Value('/tmp/master_$index.fits'),
            masterFrameCount: const Value(20),
          ),
        );
        index++;
      }

      final notes = await coverage.missingNotes(
        profile: profile,
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(),
        exposureContext: exposureContext,
        minCoverage: 10,
      );

      expect(notes, isEmpty);
    });

    test('dark requirements track the lights cooling setpoint '
        '(settings.coolDownTargetC), not profile.defaultCoolingTemp', () async {
      // The lights are cooled by the Smart Night CoolCamera node to
      // settings.coolDownTargetC. Darks MUST be requested at that SAME
      // setpoint, even when the profile carries a different default cooling
      // temp — otherwise the captured darks land in a temperature bucket the
      // lights never used and cannot calibrate them.
      const profileWithDifferentDefault = EquipmentProfileModel(
        id: 1,
        name: 'Mono rig',
        focalLength: 350,
        aperture: 71,
        cameraName: 'ZWO ASI2600MM Pro',
        defaultGain: 100,
        defaultOffset: 50,
        defaultBinX: 1,
        defaultBinY: 1,
        // Profile default is -20, but the lights will be cooled to -10.
        defaultCoolingTemp: -20,
        filterNames: ['L', 'R', 'G', 'B'],
      );

      final result = await coverage.missing(
        profile: profileWithDifferentDefault,
        strategy: SmartNightStrategy.autoLrgb,
        settings: const SmartNightSettings(coolDownTargetC: -10),
        exposureContext: exposureContext,
        minCoverage: 10,
      );

      expect(result.requirements, isNotEmpty);
      for (final req in result.requirements) {
        expect(
          req.targetTemp,
          -10,
          reason:
              'darks must match the lights cooling setpoint (-10), '
              'not the profile default (-20).',
        );
      }
    });
  });

  group('SmartNightFlatCoverage', () {
    late SkotiqDatabase database;
    late SmartNightFlatCoverage flatCoverage;

    // id is null so the lookup does not constrain on equipmentProfileId
    // (which carries a FK to EquipmentProfiles — unseeded in this test DB).
    // The per-filter / per-gain resolution is what's under test here.
    const profile = EquipmentProfileModel(
      name: 'Mono rig',
      focalLength: 350,
      aperture: 71,
      cameraName: 'ZWO ASI2600MM Pro',
      defaultGain: 100,
      defaultOffset: 50,
      filterNames: ['L', 'R', 'G', 'B'],
    );

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      flatCoverage = SmartNightFlatCoverage(
        flatHistoryDao: FlatHistoryDao(database),
      );
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'resolves the most recent ADU-calibrated exposure per filter',
      () async {
        final dao = FlatHistoryDao(database);
        // Older, then newer calibration for L — newest must win. Explicit
        // timestamps make the "newest wins" assertion deterministic (the
        // default currentDateAndTime is second-resolution and could tie).
        await dao.insertEntry(
          FlatHistoryCompanion.insert(
            filterName: 'L',
            exposureTime: 1.0,
            histogramTarget: 50,
            actualAdu: 30000,
            panelBrightness: const Value(80),
            gain: const Value(100),
            timestamp: Value(DateTime(2026, 5, 1)),
          ),
        );
        await dao.insertEntry(
          FlatHistoryCompanion.insert(
            filterName: 'L',
            exposureTime: 2.5,
            histogramTarget: 50,
            actualAdu: 32000,
            panelBrightness: const Value(95),
            gain: const Value(100),
            timestamp: Value(DateTime(2026, 5, 20)),
          ),
        );
        await dao.insertEntry(
          FlatHistoryCompanion.insert(
            filterName: 'R',
            exposureTime: 4.0,
            histogramTarget: 50,
            actualAdu: 31000,
            panelBrightness: const Value(95),
            gain: const Value(100),
            timestamp: Value(DateTime(2026, 5, 20)),
          ),
        );

        final plan = await flatCoverage.resolve(
          profile: profile,
          filters: {'L', 'R', 'B'},
        );

        expect(plan.hasAnyCalibration, isTrue);
        expect(plan.perFilter['L']!.exposureSecs, 2.5);
        expect(plan.perFilter['L']!.panelBrightness, 95);
        expect(plan.perFilter['L']!.actualAdu, 32000);
        expect(plan.perFilter['R']!.exposureSecs, 4.0);
        // B has no calibration history → flagged uncalibrated, never guessed.
        expect(plan.perFilter.containsKey('B'), isFalse);
        expect(plan.uncalibratedFilters, contains('B'));
      },
    );

    test('reports every filter uncalibrated when history is empty', () async {
      final plan = await flatCoverage.resolve(
        profile: profile,
        filters: {'L', 'R'},
      );
      expect(plan.hasAnyCalibration, isFalse);
      expect(plan.uncalibratedFilters, containsAll(<String>['L', 'R']));
    });
  });
}

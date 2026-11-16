// One altitude floor, by direction. With a tree line in the east (40 degrees
// from north-east to south-east) and open sky in the west, everything that
// plans or scores a target gives the same answer: an eastern target waits to
// clear the trees and a western one does not. With no horizon, both are held
// to the minimum altitude.

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';
import '../fakes/fake_target_scoring.dart';

class _Logging extends Mock implements LoggingService {}

class _Sink implements SchedulerSequenceSink {
  int dispatched = 0;

  @override
  Future<void> dispatchSequence(Sequence sequence) async => dispatched++;
  @override
  Future<void> pauseSequence() async {}
  @override
  Future<void> resumeSequence() async {}
  @override
  Future<void> stopSequence() async {}
  @override
  Future<void> parkForEndOfNight() async {}
  @override
  Future<void> releaseSequenceOwnership() async {}
}

const _latitude = 40.0;
const _longitude = -75.0;

/// 22:00 local on a January night: both targets are 30 to 40 degrees up.
final _night = DateTime.utc(2026, 1, 15, 3);
final _dawn = _night.add(const Duration(hours: 7));

const _east = (name: 'East', raHours: 10.0, decDegrees: 20.0);
const _west = (name: 'West', raHours: 1.5, decDegrees: 20.0);

final _trees = SiteHorizonProfile.fromSamples(const [
  (azimuth: 0, altitude: 0),
  (azimuth: 44, altitude: 0),
  (azimuth: 45, altitude: 40),
  (azimuth: 135, altitude: 40),
  (azimuth: 136, altitude: 0),
  (azimuth: 359, altitude: 0),
]);
final _noHorizon = SiteHorizonProfile.fromJson('{}');

AltitudeFloor _floor(SiteHorizonProfile horizon) =>
    AltitudeFloor(horizon: horizon, minimumDeg: 30);

typedef _Target = ({String name, double raHours, double decDegrees});

DateTime? _clears(AltitudeFloor floor, _Target target) => floor.risesAbove(
  raDeg: target.raHours * 15,
  decDeg: target.decDegrees,
  from: _night,
  until: _dawn,
  latitudeDeg: _latitude,
  longitudeDeg: _longitude,
);

Matcher _within(DateTime expected, Duration tolerance) => predicate<DateTime?>(
  (actual) => actual != null && actual.difference(expected).abs() <= tolerance,
  'within $tolerance of $expected',
);

void main() {
  final trees = _floor(_trees);
  final minimum = _floor(_noHorizon);
  final eastClears = _clears(trees, _east)!;

  test('the premise: the east is behind the trees for a while, the west is '
      'open', () {
    expect(trees.followsHorizon, isTrue);
    expect(eastClears.isAfter(_night.add(const Duration(minutes: 20))), isTrue);
    expect(_clears(trees, _west), _night);
    expect(minimum.followsHorizon, isFalse);
    expect(_clears(minimum, _east), _night);
    expect(_clears(minimum, _west), _night);
  });

  group('the scheduler', () {
    Future<int> dispatches(SiteHorizonProfile horizon, _Target target) async {
      final sink = _Sink();
      final engine = SchedulerEngine(
        site: SchedulerSite(
          latitudeDegrees: _latitude,
          longitudeDegrees: _longitude,
          localOffset: const Duration(hours: -5),
          horizon: horizon,
        ),
        sequenceSink: sink,
        candidateLoader: () async => [
          SchedulerCandidate(
            targetId: 1,
            name: target.name,
            raHours: target.raHours,
            decDegrees: target.decDegrees,
            userPriority: 5,
            goals: const [],
            capturedCounts: const [],
            availableFilters: const ['L'],
            constraints: const [],
            horizonProfiles: const {},
          ),
        ],
        clock: () => _night,
      );
      addTearDown(engine.dispose);
      await engine.start();
      return sink.dispatched;
    }

    test('does not start the eastern target behind the trees', () async {
      expect(await dispatches(_trees, _east), 0);
    });
    test('starts the western one', () async {
      expect(await dispatches(_trees, _west), 1);
    });
    test('starts both with no horizon', () async {
      expect(await dispatches(_noHorizon, _east), 1);
      expect(await dispatches(_noHorizon, _west), 1);
    });
  });

  group('the plan timer and pre-flight', () {
    DateTime imagingStarts(AltitudeFloor floor, _Target target) {
      final sequence = Sequence.create(
        name: 'Plan',
        rootNodeId: 'target',
        nodes: {
          'target': TargetHeaderNode(
            id: 'target',
            name: target.name,
            targetName: target.name,
            raHours: target.raHours,
            decDegrees: target.decDegrees,
            childIds: const ['light'],
          ),
          'light': ExposureNode(
            id: 'light',
            name: 'Light 60s',
            durationSecs: 60,
            count: 5,
            parentId: 'target',
          ),
        },
      );
      final timings = SequenceTimeEstimator(floor: floor)
          .estimateSequenceTiming(
            sequence,
            _night,
            latitude: _latitude,
            longitude: _longitude,
          );
      return timings.firstWhere((t) => t.nodeId == 'light').estimatedStart;
    }

    test('time the eastern target from when it clears the trees', () {
      expect(
        imagingStarts(trees, _east),
        _within(eastClears, const Duration(minutes: 2)),
      );
    });
    test('time the western one from the start', () {
      expect(imagingStarts(trees, _west), _night);
    });
    test('time both from the start with no horizon', () {
      expect(imagingStarts(minimum, _east), _night);
      expect(imagingStarts(minimum, _west), _night);
    });
  });

  group('Smart Night', () {
    const profile = EquipmentProfileModel(
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
      filterNames: ['L'],
    );

    DateTime windowStarts(AltitudeFloor floor, _Target target) {
      final result =
          SmartNightService(
            suggestionService: TargetSuggestionService(
              loggingService: _Logging(),
              scorer: TargetScorer(FakeTargetScoring()),
            ),
            logging: _Logging(),
            floor: floor,
          ).buildSingleTargetSequence(
            profile: profile,
            suggestion: TargetSuggestion(
              targetId: 1,
              targetName: target.name,
              raHours: target.raHours,
              decDegrees: target.decDegrees,
              totalScore: 80,
              objectType: 'Galaxy',
              visibility: const TargetVisibilityInfo(
                currentAltitude: 35,
                currentAzimuth: 90,
                airmass: 1.7,
                moonDistance: 90,
                hoursAboveMinAlt: 5,
              ),
            ),
            windowStart: _night,
            windowEnd: _dawn,
            latitudeDeg: _latitude,
            longitudeDeg: _longitude,
            availableFilters: const ['L'],
            settings: const SmartNightSettings(subExposureFloorSecs: 1),
          );
      final header = result.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .single;
      expect(header.minAltitude, isNull);
      return header.startAfter!;
    }

    test('plans the eastern target from when it clears the trees', () {
      expect(
        windowStarts(trees, _east),
        _within(eastClears, const Duration(minutes: 1)),
      );
    });
    test('plans the western one from the start of the night', () {
      expect(windowStarts(trees, _west), _night);
    });
  });

  group('Plan Tonight scoring and Best Targets Tonight', () {
    DbTarget row(int id, _Target target) => DbTarget(
      id: id,
      name: target.name,
      ra: target.raHours,
      dec: target.decDegrees,
      minAltitude: 30,
      priority: 0,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0,
      goalIntegrationSecs: 0,
      createdAt: _night,
      updatedAt: _night,
      isFavorite: false,
    );

    test('the scorer is asked to hold the night to the site floor', () async {
      final scoring = FakeTargetScoring();
      await TargetSuggestionService(
        loggingService: _Logging(),
        scorer: TargetScorer(scoring),
      ).getSuggestionsForTonight(
        config: const TargetSuggestionConfig(minScore: 0),
        latitude: _latitude,
        longitude: _longitude,
        targets: [row(1, _east)],
        sessions: const [],
        observationTime: _night,
        floor: trees,
      );
      final samples = trees.asSamples();
      expect(
        scoring.nightRequests.single.sky.floor.map(
          (s) => (s.azimuthDeg, s.altitudeDeg),
        ),
        [
          for (var i = 0; i < samples.azimuths.length; i++)
            (samples.azimuths[i], samples.altitudes[i]),
        ],
      );
    });

    test('Best Targets reports the eastern target rising when it clears the '
        'trees', () async {
      final ranked = await rankTonightTargets(
        scorer: TargetScorer(FakeTargetScoring()).scoreForNight,
        raDeg: [_east.raHours * 15],
        decDeg: [_east.decDegrees],
        latitudeDeg: _latitude,
        longitudeDeg: _longitude,
        nightDate: DateTime(2026, 1, 14),
        floor: trees.asSamples(),
      );
      expect(
        ranked.single.visibility.riseTime,
        _within(eastClears, const Duration(minutes: 3)),
      );
    });
  });

  test('the run is sent the same floor, by azimuth', () {
    final wire = trees.toWire()['samples']! as List;
    expect(wire.length, 360);
    final east = wire.cast<Map<String, Object?>>().firstWhere(
      (sample) => sample['az'] == 90.0,
    );
    final west = wire.cast<Map<String, Object?>>().firstWhere(
      (sample) => sample['az'] == 270.0,
    );
    expect(east['alt'], 40.0);
    expect(west['alt'], 0.0);
    expect(minimum.toWire()['samples'], [
      {'az': 0.0, 'alt': 30.0},
    ]);
  });
}

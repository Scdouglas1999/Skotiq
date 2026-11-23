// Pins the whole tree the Smart Night emitter writes for a set of plans: the
// order of every root step, each node's fields and the parent links. Node ids
// are random, so they are renamed by their position in a walk from the root.
//
// Regenerate (only when the emitted tree is meant to change):
//   UPDATE_EMITTER_GOLDENS=1 flutter test test/services/smart_night/emitter_tree_golden_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show TargetVisibilityInfo;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

import '../../fakes/fake_target_scoring.dart';
import '../node_codec_goldens/node_fixtures.dart' show dumpNode, plain;

class _MockLoggingService extends Mock implements LoggingService {}

const _goldenDir = 'test/services/smart_night/goldens';
final bool _update = Platform.environment['UPDATE_EMITTER_GOLDENS'] == '1';

DateTime _siteTime(int day, int hour) => DateTime.utc(2026, 5, day, hour + 4);

Map<String, Object?> _dumpTree(Sequence sequence) {
  final order = <String>[];
  void walk(String id) {
    if (order.contains(id)) return;
    order.add(id);
    for (final child in sequence.nodes[id]?.childIds ?? const <String>[]) {
      walk(child);
    }
  }

  final root = sequence.rootNodeId;
  if (root != null) walk(root);
  final rest = sequence.nodes.keys.where((id) => !order.contains(id)).toList()
    ..sort();
  order.addAll(rest);
  final rename = {for (var i = 0; i < order.length; i++) order[i]: 'n$i'};

  Object? renamed(Object? value) {
    if (value is String) return rename[value] ?? value;
    if (value is List) return [for (final v in value) renamed(v)];
    if (value is Map) {
      return {
        for (final MapEntry(:key, :value) in value.entries)
          key.toString(): renamed(value),
      };
    }
    return value;
  }

  return {
    // The plan name carries the date it was built on.
    'name': sequence.name.replaceAll(RegExp(r'\d{4}-\d{2}-\d{2}'), 'DATE'),
    'description': sequence.description,
    'root': rename[sequence.rootNodeId],
    'nodes': {
      for (final id in order)
        rename[id]!: renamed(plain(dumpNode(sequence.nodes[id]!))),
    },
  };
}

void _expectGolden(String name, Sequence sequence) {
  final file = File('$_goldenDir/$name.json');
  final text =
      '${const JsonEncoder.withIndent('  ').convert(_dumpTree(sequence))}\n';
  if (_update) {
    file.createSync(recursive: true);
    file.writeAsStringSync(text);
    return;
  }
  expect(file.existsSync(), isTrue, reason: '${file.path} is missing');
  if (text != file.readAsStringSync()) {
    final actual =
        File('${Directory.systemTemp.path}/emitter_goldens_actual/$name.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(text);
    fail('${file.path} differs; the new output is in ${actual.path}');
  }
}

void main() {
  final service = SmartNightService(
    suggestionService: TargetSuggestionService(
      loggingService: _MockLoggingService(),
      scorer: TargetScorer(FakeTargetScoring()),
    ),
    logging: _MockLoggingService(),
    floor: const AltitudeFloor(horizon: null, minimumDeg: 0),
  );

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
    filterWheelId: 'efw-1',
    filterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
  );

  TargetSuggestion suggestion(int id, String name, {int transitHour = 1}) =>
      TargetSuggestion(
        targetId: id,
        targetName: name,
        raHours: 10.0 + id,
        decDegrees: 40.0,
        totalScore: 90.0 - id,
        objectType: 'Galaxy',
        reasoning: 'High altitude',
        visibility: TargetVisibilityInfo(
          currentAltitude: 50,
          currentAzimuth: 180,
          airmass: 1.4,
          peakAltitude: 65,
          riseTime: _siteTime(17, 22),
          setTime: _siteTime(18, 5),
          peakAltitudeTime: _siteTime(18, transitHour),
          moonDistance: 90,
          hoursAboveMinAlt: 6,
          transitTime: _siteTime(18, transitHour),
        ),
      );

  group('single-target emitter', () {
    for (final preamble in [false, true]) {
      for (final shutdown in <bool?>[null, true, false]) {
        for (final fill in [false, true]) {
          final name = 'single_pre-${preamble}_shut-${shutdown}_fill-$fill';
          test(name, () {
            final result = service.buildSingleTargetSequence(
              profile: profile,
              suggestion: suggestion(1, 'M51'),
              windowStart: _siteTime(17, 22),
              windowEnd: _siteTime(18, 5),
              availableFilters: profile.filterNames,
              latitudeDeg: 80,
              longitudeDeg: -73,
              includeSessionPreamble: preamble,
              includeSessionShutdown: shutdown,
              fillWindow: fill,
            );
            _expectGolden(name, result.sequence);
          });
        }
      }
    }
  });

  group('multi-target emitter', () {
    SmartNightPlan build({
      required SmartNightContext context,
      SmartNightSettings settings = const SmartNightSettings(
        subExposureFloorSecs: 1,
      ),
      SmartNightFlatPlan? flatPlan,
      int targets = 2,
    }) => service.build(
      profile: profile,
      availableFilters: profile.filterNames,
      latitudeDeg: 80,
      longitudeDeg: -73,
      context: context,
      selectedSuggestions: [
        for (var i = 1; i <= targets; i++)
          suggestion(i, 'Target $i', transitHour: i == 1 ? 23 : 3),
      ],
      strategy: SmartNightStrategy.autoLrgb,
      settings: settings,
      planTimer: PlanTimer(site: (latitude: 80.0, longitude: -73.0)),
      flatPlan: flatPlan,
    );

    SmartNightContext context({
      double? cloud,
      int? polarDays,
      List<DarkFrameRequirement> darks = const [],
    }) => SmartNightContext(
      windowStart: _siteTime(17, 22),
      windowEnd: _siteTime(18, 5),
      bortleClass: 4,
      rainOrCloudProbability: cloud,
      daysSinceLastPolarAlignment: polarDays,
      missingDarkRequirements: darks,
    );

    test('plain two-target night', () {
      _expectGolden('multi_plain', build(context: context()).sequence);
    });

    test('one target', () {
      _expectGolden(
        'multi_one_target',
        build(context: context(), targets: 1).sequence,
      );
    });

    test('stale polar alignment, darks, flats and weather recovery', () {
      final plan = build(
        context: context(
          cloud: 0.8,
          polarDays: 30,
          darks: const [
            DarkFrameRequirement(
              gain: 100,
              offset: 50,
              durationSecs: 300,
              binX: 1,
              binY: 1,
              targetTemp: -10,
            ),
          ],
        ),
        settings: const SmartNightSettings(
          subExposureFloorSecs: 1,
          autoScheduleMissingDarks: true,
          includeFlatsAtEnd: true,
          hasCoverCalibrator: true,
        ),
        flatPlan: const SmartNightFlatPlan(
          perFilter: {
            'L': SmartNightFlatExposure(
              filterName: 'L',
              exposureSecs: 0.5,
              panelBrightness: 40,
              histogramTargetPercent: 50,
              actualAdu: 30000,
            ),
          },
          uncalibratedFilters: ['R', 'G', 'B'],
        ),
      );
      _expectGolden('multi_everything', plan.sequence);
    });

    test('flats without a cover calibrator', () {
      final plan = build(
        context: context(),
        settings: const SmartNightSettings(
          subExposureFloorSecs: 1,
          includeFlatsAtEnd: true,
        ),
      );
      _expectGolden('multi_flats_no_cover', plan.sequence);
    });
  });
}

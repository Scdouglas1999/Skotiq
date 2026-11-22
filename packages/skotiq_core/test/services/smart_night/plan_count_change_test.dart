import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show TargetVisibilityInfo;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

import '../../fakes/fake_target_scoring.dart';

class _MockLoggingService extends Mock implements LoggingService {}

DateTime _siteTime(int day, int hour) => DateTime.utc(2026, 5, day, hour + 4);

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
    name: 'Mono',
    focalLength: 350,
    aperture: 71,
    focalRatio: 4.9,
    cameraName: 'ZWO ASI2600MM Pro',
    defaultGain: 100,
    defaultOffset: 50,
    filterWheelId: 'efw-1',
    filterNames: ['L', 'R', 'G', 'B'],
  );
  TargetSuggestion suggestion(int id) => TargetSuggestion(
    targetId: id,
    targetName: 'Target $id',
    raHours: 10.0 + id,
    decDegrees: 40,
    totalScore: 90.0 - id,
    objectType: 'Galaxy',
    reasoning: 'High',
    visibility: TargetVisibilityInfo(
      currentAltitude: 50,
      currentAzimuth: 180,
      airmass: 1.4,
      peakAltitude: 65,
      riseTime: _siteTime(17, 22),
      setTime: _siteTime(18, 5),
      peakAltitudeTime: _siteTime(18, 1),
      moonDistance: 90,
      hoursAboveMinAlt: 6,
      transitTime: _siteTime(18, 1),
    ),
  );

  SmartNightPlan plan() => service.build(
    profile: profile,
    availableFilters: profile.filterNames,
    latitudeDeg: 80,
    longitudeDeg: -73,
    context: SmartNightContext(
      windowStart: _siteTime(17, 22),
      windowEnd: _siteTime(18, 5),
      bortleClass: 4,
      rainOrCloudProbability: null,
    ),
    selectedSuggestions: [suggestion(1), suggestion(2)],
    strategy: SmartNightStrategy.autoLrgb,
    settings: const SmartNightSettings(subExposureFloorSecs: 1),
    planTimer: PlanTimer(site: (latitude: 80.0, longitude: -73.0)),
  );

  test('a count change moves the target, the totals and its capture step', () {
    final before = plan();
    final target = before.plannedTargets.first;
    final row = target.filterPlans.first;
    final after = smartNightPlanWithCountChange(before, target, 0, 2);

    final changed = after.plannedTargets.first;
    expect(changed.filterPlans.first.count, row.count + 2);
    expect(
      changed.integrationSecs,
      target.integrationSecs + 2 * row.durationSecs,
    );
    expect(after.plannedTargets[1], same(before.plannedTargets[1]));
    expect(
      after.totalIntegrationSecs,
      before.totalIntegrationSecs + 2 * row.durationSecs,
    );
    expect(
      after.estimatedWallClockSecs,
      before.estimatedWallClockSecs + 2 * row.durationSecs,
    );

    final header = after.sequence.nodes.values
        .whereType<TargetHeaderNode>()
        .firstWhere((h) => h.targetName == target.suggestion.targetName);
    final step = after.sequence.nodes.values
        .whereType<SmartExposureNode>()
        .firstWhere((n) => after.sequence.enclosingTarget(n.id) == header);
    expect(
      step.plans.firstWhere((p) => p.filterName == row.filterName).count,
      row.count + 2,
    );
    expect(step.integrationBudgetSecs, changed.integrationSecs);
  });

  test('a count stays within 1..999', () {
    final before = plan();
    final target = before.plannedTargets.first;
    final low = smartNightPlanWithCountChange(before, target, 0, -100000);
    expect(low.plannedTargets.first.filterPlans.first.count, 1);
    final high = smartNightPlanWithCountChange(before, target, 0, 100000);
    expect(high.plannedTargets.first.filterPlans.first.count, 999);
  });

  test('a count change on one of two same-named targets leaves the other', () {
    final twins = service.build(
      profile: profile,
      availableFilters: profile.filterNames,
      latitudeDeg: 80,
      longitudeDeg: -73,
      context: SmartNightContext(
        windowStart: _siteTime(17, 22),
        windowEnd: _siteTime(18, 5),
        bortleClass: 4,
        rainOrCloudProbability: null,
      ),
      selectedSuggestions: [
        suggestion(1),
        suggestion(2).copyWith(targetName: 'Target 1'),
      ],
      strategy: SmartNightStrategy.autoLrgb,
      settings: const SmartNightSettings(subExposureFloorSecs: 1),
      planTimer: PlanTimer(site: (latitude: 80.0, longitude: -73.0)),
    );
    expect(twins.plannedTargets, hasLength(2));
    final first = twins.plannedTargets.first;
    final second = twins.plannedTargets.last;
    final after = smartNightPlanWithCountChange(twins, first, 0, 3);

    int? lCountUnder(SmartNightPlannedTarget target) {
      for (final node in after.sequence.nodes.values) {
        if (node is! SmartExposureNode) continue;
        final header = after.sequence.enclosingTarget(node.id);
        if (header?.raHours != target.suggestion.raHours) continue;
        return node.plans.first.count;
      }
      return null;
    }

    expect(lCountUnder(first), first.filterPlans.first.count + 3);
    expect(lCountUnder(second), second.filterPlans.first.count);
  });
}

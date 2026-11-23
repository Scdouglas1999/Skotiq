import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

// A plan's filters are matched to the goals' wheel slots by the filter-name
// rule: a set that says "Ha 7nm" is the wheel's "Ha" slot, so the goal's
// remaining frames plan that filter and no second budget row is made for it.
void main() {
  const profile = EquipmentProfileModel(
    id: 1,
    name: 'Mono',
    focalLength: 350,
    aperture: 71,
    cameraName: 'ZWO ASI2600MM Pro',
    filterNames: ['L', 'Ha'],
  );

  IntegrationGoalProgress goal(String filter, {int frames = 20}) =>
      IntegrationGoalProgress(
        goal: IntegrationGoal(
          id: 1,
          targetId: 1,
          filter: filter,
          exposureSeconds: 300,
          frameCount: frames,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
        capturedCount: 5,
      );

  List<SmartNightFilterPlan> plan(
    List<String> activeFilters, {
    required List<IntegrationGoalProgress> goals,
    List<String>? wheel,
  }) => composeSmartNightFilterPlans(
    shares: const {},
    activeFilters: activeFilters,
    windowSecs: 4 * 3600,
    profile: profile,
    cameraSpec: const CameraExposureSpec(
      readNoiseE: 1.5,
      fullWellE: 50000,
      qePeak: 0.8,
    ),
    focalLengthMm: 350,
    apertureMm: 71,
    pixelSizeUm: 3.76,
    bortleClass: 5,
    recentGuideRmsArcsec: null,
    recentGuideSamples: 0,
    settings: const SmartNightSettings(subExposureFloorSecs: 1),
    integrationGoalProgress: goals,
    availableFiltersForGoals: wheel ?? profile.filterNames,
  );

  test('a set filter named "Ha 7nm" takes the goal planned on slot "Ha"', () {
    final plans = plan(['Ha 7nm'], goals: [goal('Ha')]);
    expect(
      [for (final p in plans) (p.filterName, p.count, p.durationSecs)],
      [('Ha', 15, 300.0)],
    );
  });

  test('a goal-covered filter gets no budget row beside the goal row', () {
    final plans = plan(['L', 'Ha 7nm'], goals: [goal('Ha')]);
    expect([for (final p in plans) p.filterName], ['L', 'Ha']);
    expect(plans.last.count, 15);
  });

  test('two Ha slots stay two filters: a goal on one leaves the other', () {
    final plans = plan(
      ['Ha 3nm', 'Ha 7nm'],
      goals: [goal('Ha 3nm')],
      wheel: ['Ha 3nm', 'Ha 7nm'],
    );
    expect([for (final p in plans) p.filterName], ['Ha 3nm', 'Ha 7nm']);
    expect(plans.first.count, 15);
  });
}

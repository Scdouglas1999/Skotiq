import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/panel/guide/guide_metrics.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

class _NoAppDither extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(ditherEnabled: false);
}

void main() {
  test('a running smart exposure dithers on its filter plans\' cadence',
      () async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(_NoAppDither.new),
        nightActiveStepProvider.overrideWithValue(
          NightPlanEntry(
            node: SmartExposureNode(
              id: 'lrgb',
              plans: const [
                FilterPlan(
                  filterName: 'L',
                  filterIndex: 0,
                  count: 40,
                  durationSecs: 120,
                  ditherEvery: 3,
                ),
                FilterPlan(
                  filterName: 'R',
                  filterIndex: 1,
                  count: 15,
                  durationSecs: 120,
                  ditherEvery: 3,
                ),
              ],
            ),
            depth: 1,
            multiplier: 1,
            openEnded: false,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    expect(container.read(nightDitherEveryProvider), 3);
  });
}

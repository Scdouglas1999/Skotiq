import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_exposure_properties.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../widgets/filter_set_picker_test_support.dart';

const _ownerWheel = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII', 'DARK'];
const _profile = EquipmentProfileModel(
  id: 7,
  name: '10" Newt',
  focalLength: 1200,
  aperture: 254,
  cameraName: 'ZWO ASI1600MM-Cool',
  defaultGain: 139,
  defaultOffset: 21,
  filterWheelId: 'sim_filterwheel_1',
  filterNames: _ownerWheel,
);
const _m1 = TargetSuggestion(
  targetId: 1,
  targetName: 'M1',
  catalogId: 'M1',
  raHours: 5.58,
  decDegrees: 22.01,
  objectType: 'Supernova Remnant',
  totalScore: 0,
  visibility: TargetVisibilityInfo(
    currentAltitude: 0,
    currentAzimuth: 0,
    airmass: 0,
    moonDistance: 0,
  ),
);

void main() {
  late ProviderContainer container;
  late SmartExposureNode smart;

  setUp(() {
    smart = SmartExposureNode(
      id: 'smart',
      name: 'Smart Exposure: L+R',
      parentId: 'm1',
      rotateFilters: false,
      integrationBudgetSecs: 3 * 3600,
      plans: const [
        FilterPlan(filterName: 'L', durationSecs: 60, count: 5, ditherEvery: 4),
        FilterPlan(filterName: 'R', durationSecs: 60, count: 5, ditherEvery: 4),
      ],
    );
    final header = TargetHeaderNode(
      id: 'm1',
      name: 'Target: M1',
      targetName: 'M1',
      raHours: 5.58,
      decDegrees: 22.01,
      childIds: const ['smart'],
    );
    final sequence = Sequence.create(
      name: 'M1',
      rootNodeId: header.id,
      nodes: {header.id: header, smart.id: smart},
    );
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = sequence;
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        currentSequenceProvider.overrideWith((_) => notifier),
        activeEquipmentProfileProvider.overrideWithValue(_profile),
        effectiveFiltersProvider.overrideWithValue(_ownerWheel),
        smartNightExposureContextProvider.overrideWith((ref) async => null),
        sequenceTargetSuggestionProvider.overrideWith((ref, key) async => _m1),
        targetFilterChoiceProvider.overrideWith(
          (ref, target) async => chooseSmartNightFilters(
            target: target,
            availableFilters: _ownerWheel,
          ),
        ),
        smartNightServiceProvider.overrideWithValue(
          SmartNightService(
            suggestionService: TargetSuggestionService(
              loggingService: LoggingService(),
            ),
            logging: LoggingService(),
            floor: const AltitudeFloor(horizon: null, minimumDeg: 0),
          ),
        ),
        filterSetPreferencesProvider.overrideWith(
          MemoryFilterSetPreferences.new,
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Consumer(
                builder: (context, ref, _) => SmartExposureProperties(
                  colors: SkotiqColors.dark,
                  node: ref.watch(currentSequenceProvider)!.nodes['smart']!
                      as SmartExposureNode,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SkotiqDropdown picker(WidgetTester tester) => tester.widget<SkotiqDropdown>(
        find.byKey(const ValueKey('filter-set-picker')),
      );

  SmartExposureNode node() =>
      container.read(currentSequenceProvider)!.nodes['smart']!
          as SmartExposureNode;

  testWidgets('rows that match no set show the recommendation to pick', (
    tester,
  ) async {
    await pump(tester);
    expect(picker(tester).value, isNull);
    expect(
      find.text('Recommended: narrowband SHO, M1 is a supernova remnant.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'picking SHO fills every row from the planned time and keeps '
      'the dither cadence, then LRGB swaps them back', (tester) async {
    await pump(tester);
    picker(tester).onChanged!('narrowbandSho');
    await tester.pumpAndSettle();

    var filled = node();
    expect(filled.plans.map((p) => p.filterName), ['Ha', 'OIII', 'SII']);
    expect(filled.plans.map((p) => p.ditherEvery).toSet(), {4});
    expect(filled.plans.map((p) => (p.gain, p.offset)).toSet(), {
      (139, 21),
    });
    // Three hours split evenly into whole frames, each at least one.
    for (final plan in filled.plans) {
      expect(plan.count, greaterThan(1));
      expect(plan.count * plan.durationSecs, lessThanOrEqualTo(3600 + 1e-6));
    }
    // A motorized wheel: one exposure per filter in turn.
    expect(filled.rotateFilters, isTrue);
    expect(picker(tester).value, 'narrowbandSho');
    expect(
      container.read(filterSetPreferencesProvider).requireValue.targetChoices,
      isEmpty,
      reason: 'SHO is the recommendation, so nothing is remembered',
    );

    picker(tester).onChanged!('autoLrgb');
    await tester.pumpAndSettle();
    filled = node();
    expect(filled.plans.map((p) => p.filterName), ['L', 'R', 'G', 'B']);
    expect(filled.name, 'Smart Exposure: L+R+G+B');
    final l = filled.plans.first;
    final r = filled.plans[1];
    expect(l.count * l.durationSecs, greaterThan(r.count * r.durationSecs));
    expect(
      container.read(filterSetPreferencesProvider).requireValue.targetChoices,
      {'M1': 'autoLrgb'},
    );
    expect(find.textContaining('Your choice.'), findsOneWidget);
  });
}

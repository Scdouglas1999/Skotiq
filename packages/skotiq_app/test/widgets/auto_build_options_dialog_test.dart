import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/auto_build_options_dialog.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'filter_set_picker_test_support.dart';

const _profile = EquipmentProfileModel(
    id: 1,
    name: '10 inch Newt',
    cameraName: 'ZWO ASI1600MM-Cool',
    defaultGain: 100,
    defaultOffset: 50);
const _filters = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII'];
const _target = TargetSuggestion(
    targetId: 1,
    targetName: 'NGC7380',
    raHours: 22.78,
    decDegrees: 58.1,
    objectType: 'Emission Nebula',
    totalScore: 80,
    visibility: TargetVisibilityInfo(
        currentAltitude: 60,
        currentAzimuth: 90,
        airmass: 1.2,
        moonDistance: 90,
        hoursAboveMinAlt: 6));
const _m33 = TargetSuggestion(
    targetId: 33,
    targetName: 'M33',
    raHours: 1.56,
    decDegrees: 30.66,
    objectType: 'Galaxy',
    totalScore: 80,
    visibility: TargetVisibilityInfo(
        currentAltitude: 40,
        currentAzimuth: 160,
        airmass: 1.5,
        moonDistance: 90,
        hoursAboveMinAlt: 5));

SmartNightFilterChoice _choice(List<String> filters,
        {TargetSuggestion target = _target, int emissionRegions = 0}) =>
    chooseSmartNightFilters(
        target: target,
        availableFilters: filters,
        catalogedEmissionRegions: emissionRegions);

/// The recipe as the planner opens it, and what it returned and kept.
class _Recipe {
  AutoBuildOptions? result;
  Map<String, dynamic>? saved;
  FilterSet? chosen;
}

Future<_Recipe> _open(
  WidgetTester tester, {
  EquipmentProfileModel profile = _profile,
  List<String> filters = _filters,
  TargetSuggestion target = _target,
  int emissionRegions = 0,
  FilterSet? initialSet,
  Map<String, dynamic> saved = const {},
  Map<String, double> calculatedSeconds = const {},
  ExposureSensitivity sensitivity = const GainSensitivity(),
}) async {
  final recipe = _Recipe();
  final choice =
      _choice(filters, target: target, emissionRegions: emissionRegions);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      filterSetPreferencesProvider.overrideWith(MemoryFilterSetPreferences.new),
    ],
    child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    child: const Text('Open'),
                    onPressed: () async {
                      recipe.result = await showDialog<AutoBuildOptions>(
                          context: context,
                          builder: (_) => AutoBuildOptionsDialog(
                              profile: profile,
                              sensitivity: sensitivity,
                              filters: filters,
                              filterChoice: choice,
                              initialSet: initialSet ?? choice.recommended,
                              target: target,
                              saved: saved,
                              calculatedSeconds: calculatedSeconds,
                              onSave: (value) async => recipe.saved = value,
                              onFilterSetChosen: (set) async =>
                                  recipe.chosen = set));
                    })))),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return recipe;
}

Future<void> _pick(WidgetTester tester, String key) async {
  tester
      .widget<SkotiqDropdown>(find.byKey(const ValueKey('filter-set-picker')))
      .onChanged!(key);
  await tester.pumpAndSettle();
}

/// The set the Filters picker shows, by key.
String? _shown(WidgetTester tester) => tester
    .widget<SkotiqDropdown>(find.byKey(const ValueKey('filter-set-picker')))
    .value;

Future<void> _build(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Build sequence').last);
  await tester.tap(find.text('Build sequence').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('switching filter sets restores each camera recipe and edits',
      (tester) async {
    final recipe = await _open(tester);
    await _pick(tester, 'autoLrgb');
    expect(find.text('76'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
    final gain = find.widgetWithText(TextFormField, 'Gain');
    await tester.ensureVisible(gain);
    await tester.enterText(gain, '80');
    await _pick(tester, 'narrowbandSho');
    expect(find.text('139'), findsOneWidget);
    expect(find.text('21'), findsOneWidget);
    await _pick(tester, 'monoLrgb');
    expect(find.text('80'), findsOneWidget);
    await _build(tester);
    expect(recipe.result!.gain, 80);
    expect(recipe.result!.offset, 15);
    expect((recipe.saved!['captureSettings'] as Map)['narrowband'],
        {'gain': 139, 'offset': 21});
  });

  for (final size in [const Size(1000, 900), const Size(390, 844)]) {
    testWidgets(
        'recipe fits $size and opens on the recommended set with its reason',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final recipe = await _open(tester);
      expect(tester.takeException(), isNull);
      expect(_shown(tester), 'narrowbandSho');
      expect(
          find.text(
              'Recommended: narrowband SHO, NGC7380 is an emission nebula.'),
          findsOneWidget);
      expect(find.text('139'), findsOneWidget);
      expect(find.text('21'), findsOneWidget);
      final ha = tester
          .getRect(find.widgetWithText(TextFormField, 'Ha exposure (seconds)'));
      final oiii = tester.getRect(
          find.widgetWithText(TextFormField, 'OIII exposure (seconds)'));
      expect(oiii.top - ha.bottom, greaterThanOrEqualTo(16));
      await _build(tester);
      expect(recipe.result!.filterSet.key, 'narrowbandSho');
      expect(recipe.result!.end, AutoBuildEnd.astronomical);
      expect(recipe.result!.gain, 139);
      expect(recipe.result!.offset, 21);
      expect(recipe.result!.exposures, {'Ha': 300, 'OIII': 300, 'SII': 300});
      expect(recipe.result!.shutdown, isTrue);
      expect(recipe.chosen!.key, 'narrowbandSho');
    });
  }

  testWidgets('a filter the recipe has no length for gets the calculator\'s',
      (tester) async {
    final recipe = await _open(tester, filters: const [
      'L',
      'R',
      'G',
      'B'
    ], calculatedSeconds: const {
      'L': 55,
      'R': 90,
      'G': 90,
      'B': 90
    }, saved: const {
      'exposures': {'R': 120}
    });
    await _build(tester);
    expect(recipe.result!.exposures, {'L': 55, 'R': 120, 'G': 90, 'B': 90});
  });

  testWidgets('a set the user picks is named as theirs and kept for the target',
      (tester) async {
    final recipe = await _open(tester);
    await _pick(tester, 'autoLrgb');
    expect(
        find.text('Your choice. Recommended: narrowband SHO, NGC7380 is an '
            'emission nebula.'),
        findsOneWidget);
    await _build(tester);
    expect(recipe.result!.filterSet.filters, ['L', 'R', 'G', 'B']);
    expect(recipe.chosen!.key, 'autoLrgb');
    expect(recipe.saved!.containsKey('strategies'), isFalse);
  });

  testWidgets('the recipe opens on a set remembered for the target',
      (tester) async {
    final choice = _choice(_filters);
    final lrgb = choice.sets().firstWhere((set) => set.key == 'autoLrgb');
    await _open(tester, initialSet: lrgb);
    expect(_shown(tester), 'autoLrgb');
    expect(find.textContaining('Your choice.'), findsOneWidget);
  });

  testWidgets(
      'a galaxy with emission regions opens on LRGB with Ha offered; Add Ha '
      'takes LRGB + Ha as the user\'s choice', (tester) async {
    final recipe = await _open(tester, target: _m33, emissionRegions: 9);
    expect(_shown(tester), 'autoLrgb');
    expect(find.text('Recommended: LRGB, M33 is a galaxy.'), findsOneWidget);
    expect(
        find.text('M33 holds 9 emission regions in the catalog, and you have '
            'an Ha filter: add Ha to this plan or a later night.'),
        findsOneWidget);
    await tester.tap(find.text('Add Ha'));
    await tester.pumpAndSettle();
    expect(_shown(tester), 'haLrgb');
    expect(find.text('Add Ha'), findsNothing);
    await _build(tester);
    expect(recipe.result!.filterSet.key, 'haLrgb');
    expect(recipe.chosen!.key, 'haLrgb');
  });

  testWidgets('a galaxy on a wheel without Ha says nothing about Ha',
      (tester) async {
    await _open(tester,
        filters: const ['L', 'R', 'G', 'B', 'OIII'],
        target: _m33,
        emissionRegions: 9);
    expect(find.text('Recommended: LRGB, M33 is a galaxy.'), findsOneWidget);
    expect(find.text('Add Ha'), findsNothing);
    expect(find.textContaining('Ha filter'), findsNothing);
  });

  testWidgets(
      'a motorized wheel rotates the filters by default and the user can '
      'switch to blocks; a profile with no wheel device takes blocks',
      (tester) async {
    var recipe = await _open(tester,
        profile: const EquipmentProfileModel(
            id: 1,
            name: '10 inch Newt',
            cameraName: 'ZWO ASI1600MM-Cool',
            filterWheelId: 'efw-1'));
    expect(find.textContaining('a night cut short still has every filter'),
        findsOneWidget);
    await _build(tester);
    expect(recipe.result!.rotateFilters, isTrue);

    recipe = await _open(tester,
        profile: const EquipmentProfileModel(
            id: 1,
            name: '10 inch Newt',
            cameraName: 'ZWO ASI1600MM-Cool',
            filterWheelId: 'efw-1'));
    await tester.tap(find.text('Blocks'));
    await tester.pumpAndSettle();
    await _build(tester);
    expect(recipe.result!.rotateFilters, isFalse);

    recipe = await _open(tester);
    expect(find.textContaining('for a wheel you turn by hand'), findsOneWidget);
    await _build(tester);
    expect(recipe.result!.rotateFilters, isFalse);
  });

  testWidgets('a DSLR recipe asks for ISO from the camera and has no offset',
      (tester) async {
    final recipe = await _open(tester,
        profile: const EquipmentProfileModel(
            id: 2, name: 'Fuji', cameraName: 'Fujifilm X-T5', defaultGain: 800),
        filters: const [],
        sensitivity: IsoSensitivity(const [125, 400, 800, 1600, 3200]));
    expect(_shown(tester), 'filter:');
    expect(find.widgetWithText(TextFormField, 'Offset'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Gain'), findsNothing);
    expect(find.bySemanticsLabel('ISO'), findsOneWidget);
    expect(find.text('Rotate'), findsNothing);
    await _build(tester);
    expect(recipe.result!.gain, 800);
    expect(recipe.result!.offset, isNull);
    expect(recipe.result!.filterSet.filters, [smartNightUnfilteredName]);
  });
}

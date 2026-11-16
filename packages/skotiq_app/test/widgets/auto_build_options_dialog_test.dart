import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/auto_build_options_dialog.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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

SmartNightFilterChoice _choice(List<String> filters,
        {TargetSuggestion target = _target, int emissionRegions = 0}) =>
    chooseSmartNightFilters(
        target: target,
        availableFilters: filters,
        catalogedEmissionRegions: emissionRegions);

void main() {
  testWidgets('switching filter groups restores each camera recipe and edits',
      (tester) async {
    AutoBuildOptions? result;
    Map<String, dynamic>? saved;
    await tester.pumpWidget(MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    child: const Text('Open'),
                    onPressed: () async {
                      result = await showDialog<AutoBuildOptions>(
                          context: context,
                          builder: (_) => AutoBuildOptionsDialog(
                              profile: _profile,
                              filters: _filters,
                              filterChoice: _choice(_filters),
                              target: _target,
                              saved: const {},
                              onSave: (value) async {
                                saved = value;
                              }));
                    })))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    Future<void> choose(SmartNightStrategy strategy) async {
      tester
          .widget<DropdownButtonFormField<SmartNightStrategy>>(
              find.byType(DropdownButtonFormField<SmartNightStrategy>))
          .onChanged!(strategy);
      await tester.pumpAndSettle();
    }

    await choose(SmartNightStrategy.autoLrgb);
    expect(find.text('76'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
    final gain = find.widgetWithText(TextFormField, 'Gain');
    await tester.ensureVisible(gain);
    await tester.enterText(gain, '80');
    await choose(SmartNightStrategy.narrowbandSho);
    expect(find.text('139'), findsOneWidget);
    expect(find.text('21'), findsOneWidget);
    await choose(SmartNightStrategy.monoLrgb);
    expect(find.text('80'), findsOneWidget);
    await tester.tap(find.text('Build sequence'));
    await tester.pumpAndSettle();
    expect(result!.gain, 80);
    expect(result!.offset, 15);
    expect((saved!['captureSettings'] as Map)['narrowband'],
        {'gain': 139, 'offset': 21});
  });

  for (final size in [const Size(1000, 900), const Size(390, 844)]) {
    testWidgets(
        'recipe fits $size and emits profile values with dawn and shutdown',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? saved;
      AutoBuildOptions? result;
      await tester.pumpWidget(MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        result = await showDialog<AutoBuildOptions>(
                            context: context,
                            builder: (_) => AutoBuildOptionsDialog(
                                profile: _profile,
                                filters: _filters,
                                filterChoice: _choice(_filters),
                                target: _target,
                                saved: const {},
                                onSave: (value) async {
                                  saved = value;
                                }));
                      },
                      child: const Text('Open'))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('SHO · SII + Ha + OIII'), findsOneWidget);
      expect(find.text('139'), findsOneWidget);
      expect(find.text('21'), findsOneWidget);
      final ha = tester
          .getRect(find.widgetWithText(TextFormField, 'Ha exposure (seconds)'));
      final oiii = tester.getRect(
          find.widgetWithText(TextFormField, 'OIII exposure (seconds)'));
      expect(oiii.top - ha.bottom, greaterThanOrEqualTo(16));
      final gain = tester.getRect(find.widgetWithText(TextFormField, 'Gain'));
      final offset =
          tester.getRect(find.widgetWithText(TextFormField, 'Offset'));
      if (size.width < 500) {
        expect(offset.top - gain.bottom, greaterThanOrEqualTo(16));
      } else {
        expect(offset.left - gain.right, greaterThanOrEqualTo(16));
      }
      await tester.tap(find.text('Build sequence'));
      await tester.pumpAndSettle();
      expect(result!.strategy, SmartNightStrategy.narrowbandSho);
      expect(result!.end, AutoBuildEnd.astronomical);
      expect(result!.gain, 139);
      expect(result!.offset, 21);
      expect(result!.exposures, {'Ha': 300, 'OIII': 300, 'SII': 300});
      expect(result!.shutdown, isTrue);
      expect((saved!['captureSettings'] as Map)['narrowband'],
          {'gain': 139, 'offset': 21});
    });
  }

  // qa-surfaces S26: the plan said "Suggested exposure 55 s" for L and Build
  // pre-filled L 120 s.
  testWidgets('Build pre-fills the planner\'s suggested sub length',
      (tester) async {
    AutoBuildOptions? result;
    await tester.pumpWidget(MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    child: const Text('Open'),
                    onPressed: () async {
                      result = await showDialog<AutoBuildOptions>(
                          context: context,
                          builder: (_) => AutoBuildOptionsDialog(
                              profile: _profile,
                              filters: const ['L', 'R', 'G', 'B'],
                              filterChoice: _choice(const ['L', 'R', 'G', 'B']),
                              target: _target,
                              saved: const {},
                              suggestedSeconds: const {'L': 55},
                              onSave: (_) async {}));
                    })))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    tester
        .widget<DropdownButtonFormField<SmartNightStrategy>>(
            find.byType(DropdownButtonFormField<SmartNightStrategy>))
        .onChanged!(SmartNightStrategy.monoLrgb);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build sequence'));
    await tester.pumpAndSettle();
    expect(result!.exposures['L'], 55);
  });

  testWidgets(
      'the recipe says why it chose its filters and remembers only a set '
      'the user picked over it', (tester) async {
    final saves = <Map<String, dynamic>>[];
    Future<void> open(Map<String, dynamic> saved) async {
      await tester.pumpWidget(MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      child: const Text('Open'),
                      onPressed: () => showDialog<AutoBuildOptions>(
                          context: context,
                          builder: (_) => AutoBuildOptionsDialog(
                              profile: _profile,
                              filters: _filters,
                              filterChoice: _choice(_filters),
                              target: _target,
                              saved: saved,
                              onSave: (value) async => saves.add(value))))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    await open(const {});
    expect(find.text('Narrowband SHO: NGC7380 is an emission nebula.'),
        findsOneWidget);
    // Whole seconds read as "300", not "300.0".
    expect(find.text('300'), findsNWidgets(3));
    tester
        .widget<DropdownButtonFormField<SmartNightStrategy>>(
            find.byType(DropdownButtonFormField<SmartNightStrategy>))
        .onChanged!(SmartNightStrategy.autoLrgb);
    await tester.pumpAndSettle();
    expect(
        find.text('Your choice. Skotiq would pick Narrowband SHO: NGC7380 is '
            'an emission nebula.'),
        findsOneWidget);
    await tester.tap(find.text('Build sequence'));
    await tester.pumpAndSettle();
    expect((saves.last['strategies'] as Map)['NGC7380'], 'autoLrgb');

    await open(saves.last);
    expect(find.text('LRGB · more luminance'), findsOneWidget);
    tester
        .widget<DropdownButtonFormField<SmartNightStrategy>>(
            find.byType(DropdownButtonFormField<SmartNightStrategy>))
        .onChanged!(SmartNightStrategy.narrowbandSho);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build sequence'));
    await tester.pumpAndSettle();
    expect(saves.last['strategies'] as Map, isNot(contains('NGC7380')));
  });

  testWidgets(
      'a galaxy with emission regions opens on LRGB with Ha offered; Add Ha '
      'builds LRGB + Ha as the '
      'user\'s choice and is remembered', (tester) async {
    const m33 = TargetSuggestion(
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
    AutoBuildOptions? result;
    Map<String, dynamic>? saved;
    await tester.pumpWidget(MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    child: const Text('Open'),
                    onPressed: () async {
                      result = await showDialog<AutoBuildOptions>(
                          context: context,
                          builder: (_) => AutoBuildOptionsDialog(
                              profile: _profile,
                              filters: _filters,
                              filterChoice: _choice(_filters,
                                  target: m33, emissionRegions: 9),
                              target: m33,
                              saved: const {},
                              onSave: (value) async => saved = value));
                    })))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('LRGB · more luminance'), findsOneWidget);
    expect(find.text('LRGB: M33 is a galaxy.'), findsOneWidget);
    expect(
        find.text('M33 holds 9 emission regions in the catalog, and you have '
            'an Ha filter: add Ha to this plan or a later night.'),
        findsOneWidget);

    await tester.tap(find.text('Add Ha'));
    await tester.pumpAndSettle();
    expect(find.text('LRGB + Ha · starlight and emission'), findsOneWidget);
    expect(find.text('Add Ha'), findsNothing);
    expect(find.textContaining('Your choice.'), findsOneWidget);
    await tester.tap(find.text('Build sequence'));
    await tester.pumpAndSettle();
    expect(result!.strategy, SmartNightStrategy.haLrgb);
    expect((saved!['strategies'] as Map)['M33'], 'haLrgb');
  });

  testWidgets('a galaxy on a wheel without Ha says nothing about Ha',
      (tester) async {
    const m33 = TargetSuggestion(
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
    const filters = ['L', 'R', 'G', 'B', 'OIII'];
    await tester.pumpWidget(MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    child: const Text('Open'),
                    onPressed: () => showDialog<AutoBuildOptions>(
                        context: context,
                        builder: (_) => AutoBuildOptionsDialog(
                            profile: _profile,
                            filters: filters,
                            filterChoice: _choice(filters,
                                target: m33, emissionRegions: 9),
                            target: m33,
                            saved: const {},
                            onSave: (_) async {})))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('LRGB: M33 is a galaxy.'), findsOneWidget);
    expect(find.text('Add Ha'), findsNothing);
    expect(find.textContaining('Ha filter'), findsNothing);
  });
}

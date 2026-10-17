import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_app/widgets/auto_build_options_dialog.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_planetarium/nightshade_planetarium.dart';
import 'package:nightshade_ui/nightshade_ui.dart';

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

void main() {
  testWidgets('switching filter groups restores each camera recipe and edits',
      (tester) async {
    AutoBuildOptions? result;
    Map<String, dynamic>? saved;
    await tester.pumpWidget(MaterialApp(
        theme: NightshadeTheme.dark,
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
          theme: NightshadeTheme.dark,
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        result = await showDialog<AutoBuildOptions>(
                            context: context,
                            builder: (_) => AutoBuildOptionsDialog(
                                profile: _profile,
                                filters: _filters,
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
}

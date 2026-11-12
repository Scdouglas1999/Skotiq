import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/capture_panel.dart';
import 'package:skotiq_app/widgets/sensitivity_field.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

final _dslr = IsoSensitivity(const [100, 200, 400, 800, 1600, 3200, 6400]);

Widget _field({required int? value, required ValueChanged<int> onChanged}) =>
    SizedBox(
      width: 240,
      child: SensitivityField(
        value: value,
        onChanged: onChanged,
        gainField: (_) => const Text('gain field'),
      ),
    );

void main() {
  testWidgets('a gain camera keeps the form\'s own gain field', (tester) async {
    await pumpAppScreen(
      tester,
      _field(value: 100, onChanged: (_) {}),
      extraOverrides: [
        cameraSensitivityProvider.overrideWithValue(
          const GainSensitivity(min: 0, max: 600),
        ),
      ],
    );
    expect(find.text('gain field'), findsOneWidget);
    expect(find.byType(IsoSpeedPicker), findsNothing);
  });

  testWidgets('a DSLR offers its ISO speeds and shows the speed it would take',
      (tester) async {
    int? picked;
    await pumpAppScreen(
      tester,
      _field(value: 850, onChanged: (v) => picked = v),
      extraOverrides: [cameraSensitivityProvider.overrideWithValue(_dslr)],
    );
    expect(find.text('gain field'), findsNothing);
    expect(find.byType(IsoSpeedPicker), findsOneWidget);
    expect(find.text('800'), findsOneWidget);
    expect(find.bySemanticsLabel('ISO'), findsWidgets);

    await tester.tap(find.byType(SkotiqDropdown));
    await tester.pumpAndSettle();
    for (final speed in _dslr.speeds) {
      expect(find.text('$speed'), findsWidgets);
    }
    await tester.tap(find.text('1600').last);
    await tester.pumpAndSettle();
    expect(picked, 1600);
  });

  testWidgets('a step that takes the profile default shows the hint',
      (tester) async {
    await pumpAppScreen(
      tester,
      SizedBox(
        width: 240,
        child: SensitivityField(
          value: null,
          unsetHint: 'Profile default',
          onChanged: (_) {},
          gainField: (_) => const SizedBox(),
        ),
      ),
      extraOverrides: [cameraSensitivityProvider.overrideWithValue(_dslr)],
    );
    expect(find.text('Profile default'), findsOneWidget);
  });

  testWidgets('the Imaging capture panel reads ISO for a DSLR, without offset',
      (tester) async {
    await pumpAppScreen(
      tester,
      CapturePanel(colors: SkotiqColors.dark),
      extraOverrides: [cameraSensitivityProvider.overrideWithValue(_dslr)],
    );
    expect(find.text('ISO'), findsWidgets);
    expect(find.text('Gain / offset'), findsNothing);
    expect(find.byType(IsoSpeedPicker), findsOneWidget);
  });

  testWidgets('the Imaging capture panel keeps gain and offset for a gain camera',
      (tester) async {
    await pumpAppScreen(
      tester,
      CapturePanel(colors: SkotiqColors.dark),
      extraOverrides: [
        cameraSensitivityProvider.overrideWithValue(const GainSensitivity()),
      ],
    );
    expect(find.text('Gain / offset'), findsOneWidget);
    expect(find.byType(IsoSpeedPicker), findsNothing);
  });
}

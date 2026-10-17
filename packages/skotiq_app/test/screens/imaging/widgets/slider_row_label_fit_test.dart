// A setting row's label column is about 50px inside the 216px side panel.
// "Settle threshold" and "Target temperature" are both wider than that, and a
// single word wider than its column wraps MID-WORD: the Dither card rendered
// "Settle threshol" over "d", and Cooling rendered "temperatur" over "e".

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../golden/surface_golden_harness.dart';

Future<void> _pumpAt(WidgetTester tester, double width, String label) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SliderRowInteractive(
              label: label,
              value: 5,
              min: 1,
              max: 20,
              suffix: 'px',
              colors: SkotiqColors.dark,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(SurfaceGoldenHarness.ensureFonts);

  testWidgets('a label that does not fit its column takes the row above it',
      (tester) async {
    const label = 'Settle threshold';

    await _pumpAt(tester, 216, label);
    final narrowLabel = tester.getRect(find.text(label));
    final narrowSlider = tester.getRect(find.byType(Slider));
    expect(narrowLabel.bottom, lessThanOrEqualTo(narrowSlider.top),
        reason: 'the label sits above the slider, not beside it');
    expect(
      tester.renderObject<RenderParagraph>(find.text(label)).size.height,
      lessThan(20),
      reason: 'the label is on one line, not broken mid-word',
    );

    await _pumpAt(tester, 420, label);
    final wideLabel = tester.getRect(find.text(label));
    final wideSlider = tester.getRect(find.byType(Slider));
    expect(wideLabel.top, lessThan(wideSlider.bottom));
    expect(wideLabel.right, lessThanOrEqualTo(wideSlider.left),
        reason: 'with room, the label keeps its column beside the control');
  });

  testWidgets('labelFitsBeside answers for the row it is asked about',
      (tester) async {
    late bool shortInPanel;
    late bool longInPanel;
    late bool longWhenWide;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            shortInPanel = SliderRowInteractive.labelFitsBeside(
              context,
              label: 'Amount',
              rowWidth: 216,
              hasHelp: true,
            );
            longInPanel = SliderRowInteractive.labelFitsBeside(
              context,
              label: 'Settle threshold',
              rowWidth: 216,
              hasHelp: true,
            );
            longWhenWide = SliderRowInteractive.labelFitsBeside(
              context,
              label: 'Settle threshold',
              rowWidth: 600,
              hasHelp: true,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(shortInPanel, isTrue);
    expect(longInPanel, isFalse);
    expect(longWhenWide, isTrue);
  });
}

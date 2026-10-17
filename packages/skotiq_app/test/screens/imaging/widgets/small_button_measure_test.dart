// SmallButton.measureWidth is what AdaptiveColumns asks before it decides
// whether the Camera panel's Cool down / Warm up pair can share a row. If the
// measurement drifts from the button's own metrics the answer is a guess, and
// a guess is how "Cool D…" shipped.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../golden/surface_golden_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(SurfaceGoldenHarness.ensureFonts);

  testWidgets('the measurement is the width the button lays itself out at',
      (tester) async {
    const label = 'Cancel warm-up';
    late double measured;

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Align(
          alignment: Alignment.topLeft,
          // A Row hands its child unbounded width, so the button reports its
          // own size instead of filling the slot it was given.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Builder(
                builder: (BuildContext context) {
                  measured = SmallButton.measureWidth(context, label: label);
                  return const SmallButton(
                    label: label,
                    icon: Icons.check,
                    colors: SkotiqColors.dark,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(SmallButton)).width,
      closeTo(measured, 1),
    );
  });
}

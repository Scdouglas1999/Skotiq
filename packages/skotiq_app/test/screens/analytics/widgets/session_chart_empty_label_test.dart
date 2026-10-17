// A chart with nothing to plot has to say what is missing in words.
//
// The four Session-tab charts composed their empty state from the y-AXIS
// label, which carries units: "No HFR (px) recorded for these frames",
// "No RMS (arcsec) recorded for these frames" and — for the temperature chart,
// whose axis label is just the unit — "No °C recorded for these frames".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/session_chart.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host(Widget child) => MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the temperature chart names the measurement, not the unit',
      (tester) async {
    await tester.pumpWidget(_host(const TemperatureChart(images: [])));
    await tester.pump();

    expect(
      find.text('No sensor temperature recorded for these frames'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No °C'),
      findsNothing,
      reason: 'a bare degree sign is not a noun',
    );
  });

  testWidgets('the other three charts read as sentences too', (tester) async {
    await tester.pumpWidget(_host(const Column(
      children: [
        HfrChart(images: []),
        GuidingRmsChart(images: []),
        FocuserPositionChart(images: []),
      ],
    )));
    await tester.pump();

    expect(
      find.text('No half-flux radius recorded for these frames'),
      findsOneWidget,
    );
    expect(
      find.text('No guiding RMS recorded for these frames'),
      findsOneWidget,
    );
    expect(
      find.text('No focuser position recorded for these frames'),
      findsOneWidget,
    );
    // The unit-bearing axis captions are still on the cards; they just no
    // longer get spliced into the sentence.
    expect(find.textContaining('(px)'), findsWidgets);
    expect(find.textContaining('No HFR (px) recorded'), findsNothing);
  });
}

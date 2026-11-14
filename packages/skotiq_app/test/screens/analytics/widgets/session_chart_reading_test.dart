// UX walk 2, F34: the sensor temperature card read "20.000 °C" for its
// median, P90 and range, the precision of the axis step rather than of the
// sensor.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/session_chart.dart';
import 'package:skotiq_core/database.dart' show DbCapturedImage;
import 'package:skotiq_ui/skotiq_ui.dart';

DbCapturedImage _frame(int id, DateTime at) => DbCapturedImage(
      id: id,
      filePath: '/captures/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 4,
      binX: 1,
      binY: 1,
      sensorTemp: 20.0,
      focuserPosition: 25000,
      isPlateSolved: false,
      capturedAt: at,
      createdAt: at,
      isAccepted: true,
    );

void main() {
  testWidgets('summary values carry the precision of the quantity',
      (tester) async {
    final start = DateTime(2026, 11, 11, 8, 21);
    final frames = [
      for (var i = 0; i < 8; i++)
        _frame(i, start.add(Duration(seconds: 5 * i))),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 640,
            child: Column(children: [
              TemperatureChart(images: frames),
              FocuserPositionChart(images: frames),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('20.0°C'), findsNWidgets(2));
    expect(find.text('20.0°C to 20.0°C'), findsOneWidget);
    expect(find.textContaining('20.000'), findsNothing);
    expect(find.text('25,000'), findsNWidgets(2));
  });
}

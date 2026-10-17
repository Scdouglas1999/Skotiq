// Axis behaviour of the session charts.
//
// Two defects were visible in the running app and are guarded here:
//   * y-axis boundary labels drew on top of the outermost tick ("2.83" over
//     "2.75"), because the bounds were data +/- 10% while ticks were range/4;
//   * a descending series (what `watchStandaloneImages` returns) produced a
//     negative x axis, which silently removed every x-axis label and drew the
//     night backwards.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/session_chart.dart';

/// Only the labels the chart itself draws — the card's median/p90/n summary
/// legitimately repeats values that also appear as ticks.
List<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: find.byType(LineChart), matching: find.byType(Text)),
    )
    .map((t) => t.data)
    .whereType<String>()
    .toList();

Future<void> _pump(WidgetTester tester, List<ChartDataPoint> points) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        height: 320,
        child: SessionChart(
          title: 'Probe',
          yAxisLabel: 'HFR (px)',
          measurementName: 'half-flux radius',
          dataPoints: points,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Fails if two different labels on the SAME axis overlap.
///
/// Value labels (y) and elapsed-time labels (x) are compared separately: the
/// bottom-most y label and the leftmost x label share the axis corner by
/// fl_chart's own layout, which is not the defect this file guards.
void _expectNoOverlappingLabels(WidgetTester tester) {
  final finder =
      find.descendant(of: find.byType(LineChart), matching: find.byType(Text));
  final yLabels = <(String, Rect)>[];
  final xLabels = <(String, Rect)>[];
  for (var i = 0; i < finder.evaluate().length; i++) {
    final element = finder.at(i);
    final text = tester.widget<Text>(element).data;
    if (text == null) continue;
    final entry = (text, tester.getRect(element));
    (double.tryParse(text) != null ? yLabels : xLabels).add(entry);
  }
  expect(yLabels.length, greaterThan(2));

  for (final axis in [yLabels, xLabels]) {
    for (var i = 0; i < axis.length; i++) {
      for (var j = i + 1; j < axis.length; j++) {
        final (textA, rectA) = axis[i];
        final (textB, rectB) = axis[j];
        if (textA == textB) continue; // same label drawn twice is invisible
        expect(rectA.overlaps(rectB), isFalse,
            reason: '"$textA" ($rectA) overlaps "$textB" ($rectB)');
      }
    }
  }
}

void main() {
  final start = DateTime(2026, 7, 28, 21, 40);
  // 4.2 h run, the HFR range that used to collide on the axis.
  final ascending = List.generate(
    24,
    (i) => ChartDataPoint(
      timestamp: start.add(Duration(seconds: i * 630)),
      value: 2.26 + (i / 23) * 0.50,
    ),
  );

  testWidgets('no two different axis labels overlap on either axis',
      (tester) async {
    await _pump(tester, ascending);
    _expectNoOverlappingLabels(tester);
  });

  // A series with no variation takes the degenerate branch of NiceAxis, which
  // used to build its window from the centre without snapping to ticks: three
  // frames all guiding at 0.70" gave min = 0.70 - 2 x 0.25 = 0.20 against ticks
  // at multiples of 0.25, and "0.20" printed on top of "0.25".
  for (final flatValue in <double>[0.70, 0.60, 15220.0]) {
    testWidgets('a flat $flatValue series draws no overlapping axis labels',
        (tester) async {
      await _pump(
        tester,
        List.generate(
          3,
          (i) => ChartDataPoint(
            timestamp: start.add(Duration(seconds: i * 600)),
            value: flatValue,
          ),
        ),
      );
      _expectNoOverlappingLabels(tester);
    });
  }

  testWidgets('x axis survives descending input', (tester) async {
    await _pump(tester, ascending.reversed.toList());
    final labels = _texts(tester);
    expect(labels.any((t) => t.endsWith('m') || t.endsWith('h')), isTrue,
        reason: 'elapsed-time labels missing: $labels');
  });

  testWidgets('ordering does not change the rendered axes', (tester) async {
    await _pump(tester, ascending);
    final forward = _texts(tester)..sort();
    await _pump(tester, ascending.reversed.toList());
    final reversed = _texts(tester)..sort();
    expect(reversed, forward);
  });

  testWidgets('a constant series still gets a readable axis', (tester) async {
    final flat = List.generate(
      12,
      (i) => ChartDataPoint(
        timestamp: start.add(Duration(seconds: i * 600)),
        value: 20.0,
      ),
    );
    await _pump(tester, flat);
    final numeric = _texts(tester)
        .where((t) => double.tryParse(t) != null)
        .toList(growable: false);
    expect(numeric.map(double.parse), contains(20.0));
    // A zero-range series must not invent a spread it never measured.
    final parsed = numeric.map(double.parse).toList()..sort();
    expect(parsed.first, lessThanOrEqualTo(20.0));
    expect(parsed.last, greaterThanOrEqualTo(20.0));
  });

  testWidgets('empty series explains itself', (tester) async {
    await _pump(tester, const []);
    // The measurement as a noun, not the axis label: composing the sentence
    // from the axis gave "No HFR (px) recorded for these frames" and, on the
    // temperature chart, "No °C recorded for these frames".
    expect(
      find.textContaining('No half-flux radius recorded'),
      findsOneWidget,
    );
    expect(find.textContaining('No HFR (px) recorded'), findsNothing);
    expect(find.byType(LineChart), findsNothing);
  });
}

// The center charts' scales: value labels on the left (and right for a
// second-axis line), clock labels underneath, legends that fit whole at the
// owner's 744 px center, in the 120 px row and the 96 px compact row, at
// 1.0x and 1.3x text.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/chart_axes.dart';
import 'package:skotiq_app/screens/night_control/center/session_charts_row.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_format.dart';

import '../../../golden/surface_golden_harness.dart';
import '../fixtures/night_fixtures.dart';
import 'center_test_support.dart';

/// Pumps the row in a 744 px center: [bodyHeight] 758 gives the 120 px row,
/// 700 the 96 px compact one.
Future<void> _pumpRow(
  WidgetTester tester, {
  required bool ready,
  required double bodyHeight,
  required double textScale,
}) async {
  await pumpCenter(
    tester,
    centerOverrides(
      ready ? NightFixtures.ready() : NightFixtures.running(),
      lastAutofocus: const NightAutofocusCurveVm(
        points: <(int, double)>[
          (45200, 3.4),
          (45300, 2.7),
          (45400, 2.1),
          (45500, 2.0),
          (45600, 2.6),
        ],
        bestPosition: 45484,
        bestHfr: 1.98,
        temperature: 13.1,
      ),
    ),
    size: Size(744, bodyHeight),
    textScale: textScale,
    child: const Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 744, child: SessionChartsRow()),
    ),
  );
  await tester.pump();
}

/// Every text in the row lies inside the row, and no single-line text was
/// cut short except by design (none here).
void _expectEverythingInside(WidgetTester tester, String why) {
  expect(tester.takeException(), isNull, reason: why);
  final row = tester.getRect(find.byType(SessionChartsRow));
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final rect = tester.getRect(find.byWidget(element.widget));
    final text = paragraph.text.toPlainText();
    expect(rect.top, greaterThanOrEqualTo(row.top - 0.5),
        reason: '$why: "$text" starts above the row');
    expect(rect.bottom, lessThanOrEqualTo(row.bottom + 0.5),
        reason: '$why: "$text" runs below the row');
    expect(paragraph.didExceedMaxLines, isFalse,
        reason: '$why: "$text" is cut short');
  }
}

String _texts(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((r) => r.text.toPlainText())
    .join('\n');

void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  group('ticks', () {
    test('round values inside the range, at most the count asked for', () {
      expect(nightAxisTicks(1.98, 3.05, 3), <double>[2.0, 2.5, 3.0]);
      expect(nightAxisTicks(-0.95, 0.95, 3), <double>[-0.5, 0, 0.5]);
      expect(nightAxisTicks(-1.12, 1.12, 3), <double>[-1, 0, 1]);
      // Only two fit: the ends stay, the middle goes.
      expect(nightAxisTicks(-1.12, 1.12, 2), <double>[-1, 1]);
      expect(nightAxisTicks(-10.2, 16, 2), <double>[-10, 10]);
    });

    test('decimals follow the step', () {
      expect(nightAxisDecimals(10), 0);
      expect(nightAxisDecimals(0.5), 1);
      expect(nightAxisDecimals(0.25), 2);
    });

    test('clock ticks fit the span and the room', () {
      final from = DateTime(2026, 10, 19, 19, 48);
      final to = DateTime(2026, 10, 19, 23, 52);
      expect(nightTimeTicks(from, to, 4).map((t) => t.hour), [20, 21, 22, 23]);
      expect(nightTimeTicks(from, to, 2).map((t) => t.hour), [20, 22]);
      final ten = nightTimeTicks(
        DateTime(2026, 10, 19, 23, 42),
        DateTime(2026, 10, 19, 23, 52),
        5,
      );
      expect(ten.map((t) => t.minute), [44, 46, 48, 50, 52]);
    });
  });

  for (final (bodyHeight, row) in const <(double, String)>[
    (758, '120 px row'),
    (700, '96 px row'),
  ]) {
    for (final scale in const <double>[1.0, 1.3]) {
      final why = '744 px, $row, ${scale}x';
      testWidgets('during a run: scales and legends fit at $why',
          (tester) async {
        await _pumpRow(
          tester,
          ready: false,
          bodyHeight: bodyHeight,
          textScale: scale,
        );
        _expectEverythingInside(tester, why);
        final text = _texts(tester);
        // A value scale with its unit on each chart.
        expect(text, contains(' px'), reason: 'HFR and guide units');
        expect(text, contains('°C'), reason: 'temperature unit');
        // The focuser position on the right of the temperature chart.
        expect(text, contains(nightGrouped(45600)));
        // Clock labels under the charts.
        expect(text, contains('22:00'));
        expect(text, contains('23:50'));
        // Every line keeps its key.
        for (final key in <String>[
          'HFR',
          'stars',
          'RA',
          'Dec',
          'focuser',
          'position',
          'sensor',
        ]) {
          expect(text, contains(key), reason: '$why: the $key key');
        }
      });
    }
  }

  testWidgets('at 1.0x in the 120 px row the legends keep their numbers',
      (tester) async {
    await _pumpRow(tester, ready: false, bodyHeight: 758, textScale: 1);
    final text = _texts(tester);
    expect(text, contains('RA 0.23 px'));
    expect(text, contains('Dec 0.21 px'));
    expect(text, contains('rejected'));
    expect(text, contains('HFR 2.13'));
  });

  for (final scale in const <double>[1.0, 1.3]) {
    testWidgets('before a run the focus curve has its scales at ${scale}x',
        (tester) async {
      await _pumpRow(tester, ready: true, bodyHeight: 700, textScale: scale);
      _expectEverythingInside(tester, 'ready, 96 px row, ${scale}x');
      final text = _texts(tester);
      expect(text, contains('3.4'));
      expect(text, contains(nightGrouped(45200)));
      expect(text, contains(nightGrouped(45600)));
    });
  }
}

// A readout gets the width its own words need.
//
// `ReadoutRow` used to be a `Row` of `Flexible` children, and flex splits the
// FREE space equally: three readouts in a 320px side panel took 69px each and
// "INTEGRATION" ellipsized although the three of them fitted together with
// room to spare. A truncated readout label is the one thing 02 rule 3 forbids
// outright — the number is the point of the panel.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Widget host(Widget child, {double width = 320}) => MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );

  /// Whether the paragraph behind [text] is painting all of its words.
  void expectWhole(WidgetTester tester, String text) {
    final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
    expect(
      paragraph.size.width,
      closeTo(paragraph.getMaxIntrinsicWidth(double.infinity), 0.5),
      reason:
          '"$text" is ellipsized: it has ${paragraph.size.width}px and '
          'needs ${paragraph.getMaxIntrinsicWidth(double.infinity)}px',
    );
  }

  testWidgets('three readouts that fit together are all shown whole', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const ReadoutRow(
          gap: 18,
          children: <Readout>[
            Readout(value: '42', label: 'Frames', size: ReadoutSize.sm),
            Readout(value: '3.5', label: 'HFR', size: ReadoutSize.sm),
            Readout(
              value: '2h 14m',
              label: 'Integration',
              size: ReadoutSize.sm,
            ),
          ],
        ),
      ),
    );

    expectWhole(tester, 'INTEGRATION');
    expectWhole(tester, 'FRAMES');
    expectWhole(tester, '2h 14m');
  });

  testWidgets('a readout is not squeezed to its neighbours width', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const ReadoutRow(
          children: <Readout>[
            Readout(value: '1', label: 'N', size: ReadoutSize.sm),
            Readout(
              value: '-10.0',
              label: 'Sensor temperature',
              size: ReadoutSize.sm,
            ),
          ],
        ),
      ),
    );

    final narrow = tester.getSize(find.byType(Readout).first).width;
    final wide = tester.getSize(find.byType(Readout).last).width;
    expect(
      wide,
      greaterThan(narrow),
      reason: 'equal widths mean the run is still splitting the row by flex',
    );
  });

  testWidgets('a run that cannot fit wraps instead of truncating', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        width: 160,
        const ReadoutRow(
          children: <Readout>[
            Readout(value: '42', label: 'Frames', size: ReadoutSize.sm),
            Readout(value: '3.5', label: 'HFR', size: ReadoutSize.sm),
            Readout(
              value: '2h 14m',
              label: 'Integration',
              size: ReadoutSize.sm,
            ),
          ],
        ),
      ),
    );

    expectWhole(tester, 'INTEGRATION');
    expect(
      tester.getSize(find.byType(ReadoutRow)).height,
      greaterThan(tester.getSize(find.byType(Readout).first).height),
      reason: 'the run has to flow onto a second line, not shrink its words',
    );
  });
}

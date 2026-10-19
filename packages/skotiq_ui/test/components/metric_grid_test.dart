import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../golden/golden_harness.dart';

Widget _host(Widget child, {double width = 276}) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

/// The board's "Last frame" grid.
const _frame = <MetricGridItem>[
  MetricGridItem(
    label: 'HFR',
    value: '2.13',
    delta: '−0.04',
    deltaTone: MetricGridTone.good,
  ),
  MetricGridItem(
    label: 'FWHM',
    value: '3.4"',
    delta: '−0.1',
    deltaTone: MetricGridTone.good,
  ),
  MetricGridItem(label: 'Ecc', value: '0.31', delta: '+0.02'),
  MetricGridItem(
    label: 'Stars',
    value: '1184',
    delta: '+36',
    deltaTone: MetricGridTone.good,
  ),
  MetricGridItem(label: 'Median', value: '528', delta: '+4'),
  MetricGridItem(label: 'Bg σ', value: '11.2', delta: '−0.3'),
  MetricGridItem(label: 'SNR', value: null),
  MetricGridItem(label: 'Rejected', value: '3', valueTone: MetricGridTone.bad),
];

Color? _colorOf(WidgetTester tester, String text) {
  final rich = tester.widget<Text>(
    find.byWidgetPredicate(
      (w) => w is Text && (w.data == text || w.textSpan?.toPlainText() == text),
    ),
  );
  return rich.style?.color;
}

void main() {
  const colors = SkotiqColors.dark;

  group('MetricGrid', () {
    testWidgets('a null value renders the em dash, muted', (tester) async {
      await tester.pumpWidget(_host(const MetricGrid(items: _frame)));

      expect(find.text(kReadoutUnknown), findsOneWidget);
      expect(_colorOf(tester, kReadoutUnknown), colors.textMuted);
    });

    testWidgets('value and delta tones resolve to the palette', (tester) async {
      await tester.pumpWidget(_host(const MetricGrid(items: _frame)));

      // Rejected is a bad value.
      final rejected = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.textSpan?.toPlainText() == '3',
        ),
      );
      expect(rejected.style?.color, colors.error);

      // A good delta is success; a neutral delta stays as quiet as its label.
      final hfrLabel = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.textSpan?.toPlainText() == 'HFR −0.04',
        ),
      );
      final hfrSpan = hfrLabel.textSpan! as TextSpan;
      expect(hfrLabel.style?.color, colors.textMuted);
      expect(
        (hfrSpan.children!.single as TextSpan).style?.color,
        colors.success,
      );

      final eccLabel = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.textSpan?.toPlainText() == 'Ecc +0.02',
        ),
      );
      expect(
        ((eccLabel.textSpan! as TextSpan).children!.single as TextSpan)
            .style
            ?.color,
        colors.textMuted,
      );
    });

    testWidgets('a missing delta is left out, not invented', (tester) async {
      await tester.pumpWidget(_host(const MetricGrid(items: _frame)));
      final snr = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.textSpan?.toPlainText() == 'SNR',
        ),
      );
      expect((snr.textSpan! as TextSpan).children, isEmpty);
    });

    testWidgets('items flow into rows of [columns], columns aligned', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const MetricGrid(items: _frame)));

      final first = tester.getTopLeft(find.text('HFR −0.04'));
      final fifth = tester.getTopLeft(find.text('Median +4'));
      final second = tester.getTopLeft(find.text('FWHM −0.1'));
      expect(fifth.dx, first.dx, reason: 'item 5 starts the second row');
      expect(fifth.dy, greaterThan(first.dy));
      expect(second.dy, first.dy);
      expect(second.dx, greaterThan(first.dx));
    });

    testWidgets('a short last row keeps the column widths', (tester) async {
      await tester.pumpWidget(
        _host(
          const MetricGrid(
            columns: 3,
            items: <MetricGridItem>[
              MetricGridItem(label: 'A', value: '1'),
              MetricGridItem(label: 'B', value: '2'),
              MetricGridItem(label: 'C', value: '3'),
              MetricGridItem(label: 'D', value: '4'),
            ],
          ),
        ),
      );
      final a = tester.getTopLeft(find.text('A'));
      final d = tester.getTopLeft(find.text('D'));
      expect(d.dx, a.dx);
      final b = tester.getTopLeft(find.text('B'));
      expect(
        b.dx - a.dx,
        closeTo((276 - 2 * MetricGrid.columnGap) / 3 + MetricGrid.columnGap, 1),
      );
    });

    testWidgets('each cell reads as one node; the group can be named', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const MetricGrid(items: _frame, semanticLabel: 'Last frame')),
      );
      expect(find.bySemanticsLabel('Last frame'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'2\.13\s+HFR −0\.04')), findsOne);
      handle.dispose();
    });

    testWidgets('the board grid fits the 300 px panel in the real fonts', (
      tester,
    ) async {
      await GoldenHarness.ensureFonts();
      await tester.pumpWidget(_host(const MetricGrid(items: _frame)));

      expect(tester.takeException(), isNull);
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byType(MetricGrid),
          matching: find.byType(RichText),
        ),
      )) {
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '"${paragraph.text.toPlainText()}" was cut short',
        );
      }
    });
  });
}

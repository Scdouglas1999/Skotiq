// AdaptiveColumns is the layout that answers "do these actually fit?" with a
// measurement instead of a breakpoint. The Imaging side panel proved why: a
// fixed two-column Row is a perfectly valid layout whose children quietly
// ellipsise, so "Unpark" and "Start tracking" shipped as "U…" and "St…" with
// nothing in the app reporting a problem.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _cell(String key) => SizedBox(key: Key(key), height: 20);

Future<void> _pumpAt(WidgetTester tester, double width) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: AdaptiveColumns(
            spacing: 8,
            cells: <AdaptiveCell>[
              AdaptiveCell(minWidth: 100, child: _cell('a')),
              AdaptiveCell(minWidth: 60, child: _cell('b')),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('columnsThatFit', () {
    test('keeps every column when the row has room for them', () {
      expect(
        AdaptiveColumns.columnsThatFit(
          available: 300,
          cellWidth: 100,
          spacing: 8,
          cellCount: 2,
        ),
        2,
      );
    });

    test('drops a column the moment the gap no longer fits', () {
      // 2 × 100 + 8 = 208: one pixel short is one column.
      expect(
        AdaptiveColumns.columnsThatFit(
          available: 208,
          cellWidth: 100,
          spacing: 8,
          cellCount: 2,
        ),
        2,
      );
      expect(
        AdaptiveColumns.columnsThatFit(
          available: 207,
          cellWidth: 100,
          spacing: 8,
          cellCount: 2,
        ),
        1,
      );
    });

    test('never returns zero columns, however narrow the row', () {
      expect(
        AdaptiveColumns.columnsThatFit(
          available: 10,
          cellWidth: 100,
          spacing: 8,
          cellCount: 3,
        ),
        1,
      );
    });
  });

  testWidgets('cells share a row when both fit and stack when they do not', (
    tester,
  ) async {
    await _pumpAt(tester, 300);
    final wideA = tester.getRect(find.byKey(const Key('a')));
    final wideB = tester.getRect(find.byKey(const Key('b')));
    expect(wideA.top, wideB.top, reason: 'two columns share one line');
    expect(wideB.left, greaterThan(wideA.right));
    // Equal columns: the widest cell sets the width, so neither is the one
    // that has to truncate.
    expect(wideA.width, closeTo(wideB.width, 0.01));

    await _pumpAt(tester, 150);
    final narrowA = tester.getRect(find.byKey(const Key('a')));
    final narrowB = tester.getRect(find.byKey(const Key('b')));
    expect(narrowB.top, greaterThan(narrowA.top), reason: 'stacked');
    expect(narrowA.width, 150);
    expect(narrowB.width, 150);
  });

  testWidgets('an unbounded row lays cells out at the width they measured', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: <Widget>[
            AdaptiveColumns(
              spacing: 8,
              cells: <AdaptiveCell>[
                AdaptiveCell(minWidth: 100, child: _cell('a')),
                AdaptiveCell(minWidth: 60, child: _cell('b')),
              ],
            ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byKey(const Key('a'))).width, 100);
    expect(tester.getRect(find.byKey(const Key('b'))).width, 60);
  });

  testWidgets('measureWidth covers the label, the icon slot and the padding', (
    tester,
  ) async {
    late double withIcon;
    late double withoutIcon;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            withIcon = SkotiqButton.measureWidth(
              context,
              label: 'Start tracking',
              hasIcon: true,
            );
            withoutIcon = SkotiqButton.measureWidth(
              context,
              label: 'Start tracking',
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(withIcon, greaterThan(withoutIcon));

    // The measurement has to be the width the button actually takes, or the
    // layouts built on it are guesses. Lay one out unconstrained and compare.
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          // A Row hands its child unbounded width, which is the only way a
          // button whose box is an aligned Container reports its own size
          // rather than filling the slot it was given.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SkotiqButton(
                label: 'Start tracking',
                icon: Icons.check,
                onPressed: null,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(SkotiqButton)).width,
      closeTo(withIcon, 1),
    );
  });
}

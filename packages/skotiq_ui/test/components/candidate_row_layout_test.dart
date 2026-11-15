import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _candidate({CandidateColumns? columns}) => Candidate(
  score: '96',
  name: 'NGC1333',
  detail: 'Cluster + Nebula · 19.5′ · mag 10.9 · Perseus',
  readouts: const [
    Readout(value: '23:49 · 81°', label: 'Transit', size: ReadoutSize.sm),
    Readout(value: '10h', label: 'Above 30°', size: ReadoutSize.sm),
  ],
  window: const CandidateWindow(start: 0, end: 0.9, now: 0.1),
  action: SkotiqButton(
    label: 'Image tonight',
    size: ButtonSize.small,
    onPressed: () {},
  ),
  columns: columns,
  dense: true,
);

Future<void> _pumpAt(WidgetTester tester, double width, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a phone-width candidate keeps its name and its window bar', (
    tester,
  ) async {
    await _pumpAt(tester, 390, _candidate());

    expect(tester.takeException(), isNull, reason: 'no overflow at 390');
    final name = tester.getRect(find.text('NGC1333'));
    expect(
      name.width,
      greaterThan(60),
      reason: 'the name is the row; it must not be squeezed to nothing',
    );

    final row = tester.getRect(find.byType(SkotiqPanel));
    final bar = tester.getRect(find.byType(CandidateWindowBar));
    expect(
      bar.right,
      lessThanOrEqualTo(row.right),
      reason: 'the window bar stays inside the row',
    );
    expect(
      bar.top,
      greaterThan(name.bottom),
      reason: 'the readouts and window sit on a second line',
    );

    final transit = tester.getRect(find.text('23:49 · 81°'));
    expect(transit.top, greaterThan(name.bottom));
  });

  testWidgets('a wide candidate stays on one line', (tester) async {
    await _pumpAt(tester, 1200, _candidate());

    final name = tester.getRect(find.text('NGC1333'));
    final bar = tester.getRect(find.byType(CandidateWindowBar));
    expect(bar.top, lessThan(name.bottom));
    expect(bar.width, Candidate.windowBarWidth);
  });

  testWidgets('a candidate on fixed columns never stacks', (tester) async {
    await _pumpAt(
      tester,
      900,
      _candidate(
        columns: const CandidateColumns(readoutWidth: 96, actionWidth: 120),
      ),
    );

    final name = tester.getRect(find.text('NGC1333'));
    final bar = tester.getRect(find.byType(CandidateWindowBar));
    expect(bar.top, lessThan(name.bottom));
  });

  testWidgets('a tappable candidate keeps its action reachable by name', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var pressed = 0;
    await _pumpAt(
      tester,
      390,
      Candidate(
        score: '96',
        name: 'NGC1333',
        detail: 'Cluster + Nebula',
        readouts: const [
          Readout(value: '10h', label: 'Above 30°', size: ReadoutSize.sm),
        ],
        onTap: () {},
        selected: true,
        action: SkotiqButton(
          label: 'Image tonight',
          size: ButtonSize.small,
          onPressed: () => pressed++,
        ),
      ),
    );

    expect(find.bySemanticsLabel('NGC1333'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Above 30°'),
      findsNothing,
      reason: 'the row reads as its name; its facts stay out of the tree',
    );
    final action = find.bySemanticsLabel('Image tonight');
    expect(action, findsOneWidget);
    tester.semantics.tap(find.semantics.byLabel('Image tonight'));
    expect(pressed, 1);
    handle.dispose();
  });
}

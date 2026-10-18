// Every control in the Mount section has to say what it does at the width the
// Imaging side panel actually gives it.
//
// The panel is 320px wide including its 44px icon strip, which leaves 244 for
// the content and 216 inside a section card. The old layout put two
// fixed-width buttons per row inside a card of its own inside a 24px inset:
// 80px of the panel went to padding and every label was ellipsised — "U…" for
// Unpark, "St…" for Start tracking, "Three-Point P…", "RA (H…", "Sl…", "S…".
// A Row of Expanded children is a perfectly valid layout, so nothing failed
// and nothing logged; the only thing that noticed was the operator.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/tabs/mount_tab.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../golden/surface_golden_harness.dart';
import '../../../harness/harness.dart';

Future<void> _pumpAt(WidgetTester tester, double width) async {
  // The side panel pins its content width, so the constraint has to come from
  // the tree rather than from the surface size.
  await pumpAppScreen(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: const MountTab()),
    ),
    size: Size(width + 200, 900),
    settle: false,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

/// Every label painted inside a button, with whether it had to be cut short.
List<(String, bool)> _buttonLabels(WidgetTester tester) {
  final paragraphs = tester.renderObjectList<RenderParagraph>(
    find.descendant(
      of: find.byType(SkotiqButton),
      matching: find.byType(Text),
    ),
  );
  return <(String, bool)>[
    for (final paragraph in paragraphs)
      (paragraph.text.toPlainText(), paragraph.didExceedMaxLines),
  ];
}

Offset _topLeftOf(WidgetTester tester, String label) =>
    tester.getTopLeft(find.widgetWithText(SkotiqButton, label));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Measured widths are the whole point of this file, and the test font is not
  // the shipped one: every glyph in it is a full em square, which makes a
  // fourteen-character label half again as wide as HankenGrotesk draws it. The
  // real typefaces are what the panel is laid out with.
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  // 160 is the panel at its narrowest measured on screen, 220 the tablet
  // split's floor, 320 the panel's own width — every real host sits inside
  // this range.
  for (final width in <double>[160, 220, 320]) {
    testWidgets('no button label is cut short at ${width.toInt()} px',
        (tester) async {
      await _pumpAt(tester, width);
      expect(tester.takeException(), isNull);

      final labels = _buttonLabels(tester);
      expect(labels, isNotEmpty, reason: 'the section has buttons to check');
      for (final (text, truncated) in labels) {
        expect(
          truncated,
          isFalse,
          reason: '"$text" is ellipsised at ${width.toInt()} px',
        );
      }
    });

    testWidgets('button copy is sentence case at ${width.toInt()} px',
        (tester) async {
      await _pumpAt(tester, width);

      for (final (text, _) in _buttonLabels(tester)) {
        expect(
          text,
          isNot(equals(text.toUpperCase())),
          reason: '"$text" shouts; button copy is sentence case (06 §Copy)',
        );
      }
      // The three labels the old panel could not fit, in full.
      expect(find.text('Abort slew'), findsOneWidget);
      expect(find.text('Polar alignment'), findsOneWidget);
      // A mount reports itself parked until something says otherwise, so the
      // first action is the one that frees it.
      expect(find.text('Unpark'), findsOneWidget);
    });
  }

  testWidgets('the status chip states the mount state in sentence case',
      (tester) async {
    await _pumpAt(tester, 320);

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('DISCONNECTED'), findsNothing);
    expect(
      tester.widget<SkotiqChip>(find.byType(SkotiqChip)).tone,
      ChipTone.error,
    );
  });

  testWidgets(
      'the stop actions lead and Park comes last, never in the first slot',
      (tester) async {
    await _pumpAt(tester, 320);

    // Reading order: top to bottom, then left to right.
    final order = <String>[
      'Start tracking',
      'Abort slew',
      'Unpark',
      'Polar alignment',
    ]..sort((a, b) {
        final pa = _topLeftOf(tester, a);
        final pb = _topLeftOf(tester, b);
        final byRow = pa.dy.compareTo(pb.dy);
        return byRow != 0 ? byRow : pa.dx.compareTo(pb.dx);
      });
    expect(order, <String>[
      'Start tracking',
      'Abort slew',
      'Unpark',
      'Polar alignment',
    ]);
    // Polar alignment is an action in this grid now, not a card of its own.
    expect(find.text('Alignment'), findsNothing);
  });

  testWidgets('the stop actions share one row at the side panel width',
      (tester) async {
    // 244 is the content width the 320 px side panel gives the section.
    await _pumpAt(tester, 244);

    final tracking = _topLeftOf(tester, 'Start tracking');
    final abort = _topLeftOf(tester, 'Abort slew');
    expect(abort.dy, tracking.dy, reason: 'two columns share one line');
    expect(abort.dx, greaterThan(tracking.dx));
    final park = _topLeftOf(tester, 'Unpark');
    final polar = _topLeftOf(tester, 'Polar alignment');
    expect(polar.dy, park.dy);
    expect(park.dy, greaterThan(tracking.dy));
    expect(_buttonLabels(tester).every(((String, bool) e) => !e.$2), isTrue);
  });

  testWidgets('a pair stacks while its two labels do not fit side by side',
      (tester) async {
    await _pumpAt(tester, 160);

    final tracking = _topLeftOf(tester, 'Start tracking');
    final abort = _topLeftOf(tester, 'Abort slew');
    expect(abort.dy, greaterThan(tracking.dy),
        reason: 'the two actions stack rather than share a cut-off row');
    expect(abort.dx, tracking.dx);
  });

  testWidgets('a coordinate readout never wraps or truncates', (tester) async {
    await _pumpAt(tester, 160);

    final paragraphs = tester.renderObjectList<RenderParagraph>(
      find.descendant(of: find.byType(Readout), matching: find.byType(Text)),
    );
    for (final paragraph in paragraphs) {
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '"${paragraph.text.toPlainText()}" does not fit its column',
      );
    }
  });
}

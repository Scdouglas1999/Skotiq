// The mosaic project header's "target region" claim must be TRUE.
//
// It derives the mosaic centre from the panel centres. RA was averaged
// arithmetically, which is invalid for an angle: a mosaic straddling RA 0h has
// panels at (e.g.) 23.97h and 0.03h, whose arithmetic mean is 12.0h. The header
// therefore stated, with full confidence and to the second, a centre on the
// exact opposite side of the sky from the grid it was describing — and the
// operator has nothing else on that screen to check it against.
//
// The Observatory overhaul turned the middot-joined subtitle into a ReadoutRow
// (Grid / Panels / Integrated / Centre), so the facts are now separate Texts
// instead of one sentence. The CLAIMS are unchanged and so are the assertions
// about them; the helper below reads the whole header rather than one string.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_controller.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  MosaicProject project({int rows = 2, int cols = 2}) {
    final now = DateTime.utc(2026, 7, 29);
    return MosaicProject(
      id: 1,
      name: 'Seam Mosaic',
      rows: rows,
      cols: cols,
      createdAt: now,
      updatedAt: now,
    );
  }

  List<MosaicProjectPanel> panels(List<(double ra, double dec)> centers) {
    return [
      for (var i = 0; i < centers.length; i++)
        MosaicProjectPanel(
          projectId: 1,
          panelIndex: i,
          centerRa: centers[i].$1,
          centerDec: centers[i].$2,
        ),
    ];
  }

  /// Everything the header renders, joined. It used to be one subtitle string;
  /// it is four readouts now, and every assertion below is about the facts, not
  /// about which widget carries them.
  Future<String> pumpHeaderFacts(
    WidgetTester tester, {
    required MosaicProject mosaicProject,
    required List<MosaicProjectPanel> mosaicPanels,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: MosaicProjectHeader(
            project: mosaicProject,
            state: MosaicProjectState(
              project: mosaicProject,
              panels: mosaicPanels,
              isLoading: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // `Text.rich`, not `Text`, is what a Readout paints its value with — the
    // unit is a child span so it can scale WITH the number — so `text.data` is
    // null there and only the labels would be read.
    final facts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .join(' | ');
    expect(
      facts,
      contains(' wide '),
      // The axis-labelled grid dimensions ("3 wide x 2 high"); see
      // mosaic_format.dart.
      reason: 'the header did not render its grid readout',
    );
    return facts;
  }

  testWidgets(
    'a mosaic straddling RA 0h reports a centre near 0h, not 12h',
    (tester) async {
      final facts = await pumpHeaderFacts(
        tester,
        mosaicProject: project(),
        mosaicPanels: panels(const [
          (23.97, 40.0),
          (0.03, 40.0),
          (23.97, 41.0),
          (0.03, 41.0),
        ]),
      );

      // The arithmetic-mean bug rendered "12:00:00.00".
      expect(facts, isNot(contains('12:00:00')));
      // Circular mean puts the centre back on the RA 0h seam — either side of
      // it is the same place on the sky.
      expect(
        facts.contains('00:00:00') || facts.contains('23:59:5'),
        isTrue,
        reason: 'expected a centre at the RA 0h seam, got: $facts',
      );
    },
  );

  testWidgets('a mosaic well away from the seam is unchanged', (tester) async {
    final facts = await pumpHeaderFacts(
      tester,
      mosaicProject: project(rows: 1, cols: 2),
      mosaicPanels: panels(const [
        (5.55, -5.0),
        (5.65, -5.0),
      ]),
    );

    // 5.55h and 5.65h average to 5.60h = 05:36:00. Field-wise rounding renders
    // this same value as the impossible '05:35:60.00'.
    expect(facts, contains('05:36:00.00'));
    // One convention, axis-labelled, shared with the Collaborate card.
    expect(facts, contains('2 wide × 1 high'));
  });

  testWidgets(
      'a project with no panels omits the centre rather than '
      'inventing 00h00m00s', (tester) async {
    final facts = await pumpHeaderFacts(
      tester,
      mosaicProject: project(rows: 1, cols: 1),
      mosaicPanels: const [],
    );

    // No centre segment at all. Matched on the sexagesimal colons rather than
    // a bare 'h', which the axis-labelled grid ("1 wide × 1 high") also carries.
    // No centre at all: the Readout renders an em dash for a value it does not
    // have, never an invented 00h00m00s. Matched on the sexagesimal colons
    // rather than a bare 'h', which the axis-labelled grid also carries.
    expect(facts, isNot(contains(':')));
    expect(facts, contains('—'));
    expect(facts, contains('0 / 1'));
  });

  testWidgets(
      'a sparse grid (cells disabled in the wizard) reports the '
      'panels that exist, not rows x cols', (tester) async {
    // A 3x3 project created with one corner disabled persists 8 panels, so the
    // header must not say "9 panels" above a grid of 8 and an action row
    // reading "… of 8 panels integrated".
    final facts = await pumpHeaderFacts(
      tester,
      mosaicProject: project(rows: 3, cols: 3),
      mosaicPanels: panels(const [
        (5.0, 10.0),
        (5.1, 10.0),
        (5.2, 10.0),
        (5.0, 10.5),
        (5.1, 10.5),
        (5.2, 10.5),
        (5.0, 11.0),
        (5.1, 11.0),
      ]),
    );

    expect(facts, contains('3 wide × 3 high'));
    expect(facts, contains('8 / 9'));
    // The bare "9" claim (rows x cols with nothing beside it) must be gone: the
    // readout has to carry BOTH numbers or it is the old lie in a new widget.
    expect(facts, isNot(contains('| 9 |')));
  });

  testWidgets('a complete grid still reads as a plain panel count',
      (tester) async {
    final facts = await pumpHeaderFacts(
      tester,
      mosaicProject: project(rows: 1, cols: 2),
      mosaicPanels: panels(const [
        (5.0, 10.0),
        (5.1, 10.0),
      ]),
    );

    // A complete grid needs no fraction: the two numbers are the same number.
    expect(facts, contains('| 2 |'));
    expect(facts, isNot(contains('2 / 2')));
  });
}

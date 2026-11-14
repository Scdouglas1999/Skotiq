// The project's panel grid draws each panel in the cell Framing drew it in.
// It wrapped the tiles in index order, so a serpentine 2x2 showed panel 3
// bottom-left where Framing (and the sky) had it bottom-right, and a project
// started in another corner was numbered differently from its canvas.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/discover/mosaic/widgets/mosaic_panel_grid.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show MosaicStartCorner;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<Map<int, Offset>> _pump(
  WidgetTester tester,
  MosaicStartCorner corner, {
  required bool serpentine,
  List<int> indices = const [0, 1, 2, 3],
  double width = 1200,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final now = DateTime.utc(2026, 11, 13);
  final project = MosaicProject(
    id: 1,
    name: 'M31',
    rows: 2,
    cols: 2,
    startCorner: corner,
    serpentine: serpentine,
    createdAt: now,
    updatedAt: now,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          child: MosaicPanelGrid(
            project: project,
            panelMasters: const {},
            panels: [
              for (final i in indices)
                MosaicProjectPanel(
                  id: i + 1,
                  projectId: 1,
                  panelIndex: i,
                  centerRa: 0.7,
                  centerDec: 41.0,
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return {
    for (final i in indices)
      i + 1: tester.getTopLeft(find.text('Panel ${i + 1}')),
  };
}

void main() {
  testWidgets('a serpentine grid from the top left snakes back on row two',
      (tester) async {
    final at = await _pump(tester, MosaicStartCorner.topLeft, serpentine: true);
    expect(at[1]!.dy, at[2]!.dy);
    expect(at[2]!.dx, greaterThan(at[1]!.dx));
    expect(at[3]!.dy, greaterThan(at[1]!.dy));
    expect(at[3]!.dx, at[2]!.dx, reason: 'panel 3 is below panel 2');
    expect(at[4]!.dx, at[1]!.dx);
  });

  testWidgets('a grid started bottom right is drawn from the bottom right',
      (tester) async {
    final at =
        await _pump(tester, MosaicStartCorner.bottomRight, serpentine: false);
    expect(at[1]!.dy, greaterThan(at[3]!.dy), reason: 'panel 1 is on row two');
    expect(at[1]!.dx, greaterThan(at[2]!.dx),
        reason: 'panel 1 is on the right');
    expect(at[3]!.dx, at[1]!.dx);
    expect(at[4]!.dx, at[2]!.dx);
  });

  testWidgets('disabled cells keep their row and phone grids keep their columns',
      (tester) async {
    final at = await _pump(
      tester,
      MosaicStartCorner.topLeft,
      serpentine: true,
      indices: const [2, 3],
      width: 240,
    );
    expect(at[3]!.dy, greaterThan(120), reason: 'the empty first row keeps space');
    expect(at[3]!.dy, at[4]!.dy);
    expect(at[3]!.dx, greaterThan(at[4]!.dx));
    expect(find.byType(SingleChildScrollView), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

}

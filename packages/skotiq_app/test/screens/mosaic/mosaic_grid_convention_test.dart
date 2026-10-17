// Regression guard for: "The same mosaic is described as '3x2 grid' on one
// screen and '2x3 grid' on the other".
//
// mosaic_project_screen and mosaic_projects_list_screen emitted
// '${cols}x${rows} grid' while collaborative_sky/widgets/collab_mosaic_card
// emitted '${rows}×${cols} grid', so a project stored rows=2, cols=3 read
// "3x2 grid" on the mosaic screens and "2x3 grid" on the Collaborate card —
// and neither string said which number was which axis.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/widgets/collab_mosaic_card.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_format.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_controller.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The audit's mosaic: stored rows=2, cols=3.
const _rows = 2;
const _cols = 3;

Widget _host(Widget child) => MaterialApp(
      theme: SkotiqTheme.dark,
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Every string rendered anywhere in the pumped tree.
List<String> _renderedText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the grid formatter names its axes', () {
    expect(formatMosaicGrid(cols: _cols, rows: _rows), '3 wide × 2 high');
    expect(formatMosaicGrid(cols: 1, rows: 1), '1 wide × 1 high');
  });

  testWidgets('the mosaic project header and the Collaborate card agree',
      (tester) async {
    final now = DateTime.utc(2026, 8, 3);
    final project = MosaicProject(
      id: 1,
      name: 'Veil',
      rows: _rows,
      cols: _cols,
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(_host(MosaicProjectHeader(
      project: project,
      state: MosaicProjectState(
        project: project,
        panels: const [],
        isLoading: false,
      ),
    )));
    await tester.pumpAndSettle();
    final headerText = _renderedText(tester).join(' | ');

    await tester.pumpWidget(_host(CollabMosaicCard(
      mosaic: const CollabMosaic(
        mosaicId: 'm1',
        ownerAccountId: 'owner',
        ownerDisplayName: 'Ada',
        name: 'Veil',
        rows: _rows,
        cols: _cols,
        overlapPct: 10,
        positionAngleDeg: 0,
        centerRaDeg: 311.0,
        centerDecDeg: 30.7,
        status: 'open',
        outputPresent: false,
        panels: [],
      ),
      onView: () {},
    )));
    await tester.pumpAndSettle();
    final cardText = _renderedText(tester).join(' | ');

    const expected = '3 wide × 2 high';
    expect(headerText, contains(expected));
    expect(cardText, contains(expected),
        reason: 'the Collaborate card described the same mosaic transposed');
    for (final transposed in ['3x2', '2x3', '3×2', '2×3']) {
      expect(headerText, isNot(contains(transposed)));
      expect(cardText, isNot(contains(transposed)));
    }
  });
}

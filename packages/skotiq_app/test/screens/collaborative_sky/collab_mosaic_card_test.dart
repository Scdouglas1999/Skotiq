import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/widgets/collab_mosaic_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  CollabMosaicPanel panel(int index,
          {required bool uploaded, String? credit}) =>
      CollabMosaicPanel(
        panelIndex: index,
        centerRaDeg: 10.0 + index,
        centerDecDeg: 41.0,
        status: uploaded ? 'uploaded' : 'pending',
        assignedAccountId: credit == null ? null : 'a-$credit',
        assignedRigId: credit == null ? null : 'rig-$credit',
        assignedDisplayName: credit,
        uploaded: uploaded,
      );

  CollabMosaic mosaic({
    String status = 'open',
    List<CollabMosaicPanel> panels = const [],
  }) =>
      CollabMosaic(
        mosaicId: 'm1',
        ownerAccountId: 'owner',
        ownerDisplayName: 'Ada',
        name: 'Veil Nebula',
        rows: 2,
        cols: 2,
        overlapPct: 10,
        positionAngleDeg: 0,
        centerRaDeg: 311.0,
        centerDecDeg: 30.7,
        status: status,
        outputPresent: status == 'complete',
        panels: panels,
      );

  testWidgets('an open mosaic shows combined panel progress + View panels',
      (tester) async {
    await tester.pumpWidget(host(CollabMosaicCard(
      mosaic: mosaic(panels: [
        panel(0, uploaded: true, credit: 'Ada'),
        panel(1, uploaded: true, credit: 'Carl'),
        panel(2, uploaded: false),
        panel(3, uploaded: false),
      ]),
      onView: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Veil Nebula'), findsOneWidget);
    expect(find.text('Open for panels'), findsOneWidget);
    expect(find.text('2 of 4 panels'), findsOneWidget);
    expect(find.text('Ada & Carl'), findsOneWidget);
    expect(find.text('View panels'), findsOneWidget);
  });

  testWidgets('credits only delivered panels, not mere claimants',
      (tester) async {
    await tester.pumpWidget(host(CollabMosaicCard(
      mosaic: mosaic(panels: [
        panel(0, uploaded: true, credit: 'Ada'),
        // Claimed but never delivered: must NOT appear in attribution.
        panel(1, uploaded: false, credit: 'Mallory'),
        panel(2, uploaded: false),
        panel(3, uploaded: false),
      ]),
      onView: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('1 of 4 panels'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.textContaining('Mallory'), findsNothing);
  });

  testWidgets('an assembling mosaic surfaces the stitching line',
      (tester) async {
    await tester.pumpWidget(host(CollabMosaicCard(
      mosaic: mosaic(status: 'assembling', panels: [
        panel(0, uploaded: true, credit: 'Ada'),
        panel(1, uploaded: true, credit: 'Carl'),
        panel(2, uploaded: true, credit: 'Priya'),
        panel(3, uploaded: true, credit: 'Bo'),
      ]),
      onView: () {},
    )));
    // The assembling card runs an indeterminate progress animation, so pump a
    // couple of frames rather than settling (which would never complete).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Assembling'), findsOneWidget);
    expect(
      find.text('All panels in — the owner is stitching the mosaic'),
      findsOneWidget,
    );
  });

  testWidgets('a complete mosaic reads full progress + View mosaic',
      (tester) async {
    await tester.pumpWidget(host(CollabMosaicCard(
      mosaic: mosaic(status: 'complete', panels: [
        panel(0, uploaded: true, credit: 'Ada'),
        panel(1, uploaded: true, credit: 'Carl'),
        panel(2, uploaded: true, credit: 'Priya'),
        panel(3, uploaded: true, credit: 'Bo'),
      ]),
      onView: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Complete'), findsOneWidget);
    expect(find.text('4 of 4 panels'), findsOneWidget);
    expect(find.text('View mosaic'), findsOneWidget);
  });

  testWidgets('degrades to grid dimensions when panels are not populated',
      (tester) async {
    // The list payload omits panels: total falls back to rows*cols, uploaded 0.
    await tester.pumpWidget(host(CollabMosaicCard(
      mosaic: mosaic(),
      onView: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('0 of 4 panels'), findsOneWidget);
  });

  testWidgets('tapping View fires the callback', (tester) async {
    var viewed = false;
    await tester.pumpWidget(host(CollabMosaicCard(
      mosaic: mosaic(),
      onView: () => viewed = true,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('View panels'));
    expect(viewed, isTrue);
  });
}

// Every surface that captions a frame or an exposure step says what a
// calibration frame is: a flat step reads "Flat Ha" in Tonight's steps and the
// Ledger as it does under its thumbnails, and a dark in the Analytics strip
// reads "Dark", not the wheel's filter.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_thumbnail_strip.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

DbCapturedImage _frame(String frameType) => DbCapturedImage(
      id: 7,
      filePath: '/frames/f7.fits',
      fileName: 'f7.fits',
      fileFormat: 'fits',
      frameType: frameType,
      filter: 'G',
      exposureDuration: 55,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 11, 26),
      createdAt: DateTime.utc(2026, 11, 26),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  ExposureNode step(FrameType type) => ExposureNode(
        durationSecs: 2,
        count: 10,
        filter: 'Ha',
        frameType: type,
      );

  String ledgerFilterExp(ExposureNode node) => ledgerColumnsFor(
        node,
        Sequence.create(
          name: 'T',
          nodes: {node.id: node},
          rootNodeId: node.id,
        ),
        rollup: const Duration(seconds: 20),
      ).filterExp;

  test('a flat step reads as a flat in Tonight and the Ledger', () {
    expect(nightStepLabel(step(FrameType.flat)), startsWith('Flat Ha 10 × '));
    expect(ledgerFilterExp(step(FrameType.flat)), 'Flat Ha 2s');
    expect(ledgerFilterExp(step(FrameType.light)), 'Ha 2s');
  });

  testWidgets('a dark in the Analytics strip reads as a dark', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ImageThumbnailStrip(images: [_frame('dark')]),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('G'), findsNothing);
  });
}

// The Live Frame tile must lay out at a FINITE height when the dashboard gives
// it none.
//
// Found live, not by reading: ticking Dashboard > Widgets > "Live Frame" made
// the dashboard's whole primary column render blank while the picker still
// reported the tile enabled, and the app log filled with
//   [ERROR:flutter/flow/layers/transform_layer.cc(15)]
//   TransformLayer is constructed with an invalid matrix.
// Dashboard zones are vertical scroll views, so the tile builds with
// maxHeight == infinity; nothing inside supplied a bound, the infinity reached
// InteractiveViewer's transform and the engine dropped the layer subtree.
//
// A plain `pumpWidget` gives tight screen constraints and would never see it,
// so the tile is deliberately pumped inside an unbounded-height Column.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/live_frame_panel.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('lays out at a finite height inside an unbounded scroll zone',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            // Exactly the shape of a dashboard zone: a scrolling Column, so
            // every tile is offered an infinite height.
            body: ListView(
              children: const [RunDashboardLiveFrame()],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);

    final size = tester.getSize(find.byType(RunDashboardLiveFrame));
    expect(size.height.isFinite, isTrue,
        reason: 'an infinite height is what produced the invalid transform '
            'matrix that blanked the dashboard column');
    expect(size.height, greaterThan(0));
  });
}

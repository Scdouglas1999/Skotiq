// Tonight's row of panels at the rig's size, with the rig's evening state:
// everything connected, PHD2 looping, nothing loaded in the Sequencer, and the
// camera's latest 4:3 frame in the preview.
//
// Live at 1920x1080 the preview card was twice as wide as its frame, the
// Guiding card said "Idle" while the Safety card logged "Guider looping", the
// Progress card drew a 0% ring over a row of em dashes for a run that did not
// exist, and the Equipment values started at different x on every row.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_equipment_panel.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_grid.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_guiding_panel.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_preview_panel.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_progress_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// A 4:3 frame, the ASI1600's shape.
CapturedImageData _frame() {
  const width = 64, height = 48;
  return CapturedImageData(
    width: width,
    height: height,
    displayData: Uint8List(width * height * 4),
    histogram: List<int>.filled(256, 0),
    stats: const ImageStats(
      hfr: 0,
      eccentricity: 0,
      starCount: 0,
      median: 0,
      mean: 0,
      stdDev: 0,
      min: 0,
      max: 0,
      mad: 0,
    ),
    capturedAt: DateTime(2026, 10, 17, 21, 52),
    settings: const ExposureSettings(exposureTime: 2, gain: 139, offset: 21),
    isColor: false,
  );
}

class _LoopingGuider extends GuiderStateNotifier {
  _LoopingGuider(super.ref) {
    setConnecting('phd2', 'PHD2 Guiding');
    setConnected();
  }
}

class _Wheel extends FilterWheelStateNotifier {
  _Wheel(super.ref) {
    setConnecting('efw', 'EFW');
    setConnected(filterNames: const ['L', 'R', 'G', 'B']);
    updatePosition(0);
  }
}

final _rigOverrides = [
  guiderStateProvider.overrideWith((ref) => _LoopingGuider(ref)),
  phd2StateProvider.overrideWith((ref) => Phd2State.looping),
  filterWheelStateProvider.overrideWith((ref) => _Wheel(ref)),
];

Future<void> _pumpPanel(WidgetTester tester, Widget panel) async {
  await pumpAppScreen(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 520, child: panel),
    ),
    size: const Size(1648, 1080),
    settle: false,
    extraOverrides: _rigOverrides,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a looping guider reads Looping, in one line', (tester) async {
    await _pumpPanel(tester, const TonightGuidingPanel());

    expect(find.text('Looping'), findsOneWidget);
    expect(find.text('Idle'), findsNothing);
    expect(find.text('Looping exposures, not guiding'), findsOneWidget);
    expect(
      find.text('RA RMS'),
      findsNothing,
      reason: 'four em dashes under an empty chart said nothing new',
    );
    expect(
        tester.getSize(find.byType(TonightGuidingPanel)).height, lessThan(120));
  });

  testWidgets('with nothing loaded Progress is one line and the way to fill it',
      (tester) async {
    await _pumpPanel(tester, const TonightProgressPanel());

    expect(find.text('No sequence loaded'), findsOneWidget);
    expect(find.text('Open Sequencer'), findsOneWidget);
    expect(
        find.text('No per-filter plan in the loaded sequence'), findsNothing);
    expect(find.text('INTEGRATED'), findsNothing);
    expect(tester.getSize(find.byType(TonightProgressPanel)).height,
        lessThan(120));
  });

  testWidgets('equipment values share one right edge down the column',
      (tester) async {
    await _pumpPanel(tester, const TonightEquipmentPanel());

    final filterValue = tester.getRect(find.text('L'));
    final filterLabel = tester.getRect(find.text('FILTER'));
    final rmsLabel = tester.getRect(find.text('TOTAL RMS'));
    final rmsValue = tester.getRect(
      find
          .descendant(
            of: find.ancestor(
              of: find.text('TOTAL RMS'),
              matching: find.byType(Readout),
            ),
            matching: find.byType(RichText),
          )
          .first,
    );

    expect(filterValue.right, closeTo(filterLabel.right, 0.5));
    expect(rmsValue.right, closeTo(rmsLabel.right, 0.5));
    expect(filterLabel.right, closeTo(rmsLabel.right, 0.5));
  });

  testWidgets(
      'the preview is as wide as its frame and Equipment takes the rest',
      (tester) async {
    final controller = AnimationController(vsync: const TestVSync());
    addTearDown(controller.dispose);
    const gridWidth = 1600.0;
    final tiles = [
      for (final tile in DashboardLayout.defaultLayout().tiles)
        tile.copyWith(
          enabled: tile.widgetId == DashboardWidgetId.tonightPreview ||
              tile.widgetId == DashboardWidgetId.tonightEquipment,
        ),
    ];

    await pumpAppScreen(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: gridWidth,
          child: TonightGrid(
            tiles: tiles,
            colors: SkotiqColors.dark,
            pulseController: controller,
            isEditing: false,
            onReorder: (_, __) {},
            onResize: (_) {},
            onToggleEnabled: (_, __) {},
          ),
        ),
      ),
      size: const Size(1648, 1080),
      settle: false,
      extraOverrides: [
        ..._rigOverrides,
        currentImageProvider.overrideWith((ref) => _frame()),
      ],
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final preview = tester.getSize(find.byType(TonightPreviewPanel));
    final equipment = tester.getSize(find.byType(TonightEquipmentPanel));
    // The frame's width at the preview's 300 px height.
    expect(preview.width, closeTo(300 * 4 / 3, 1));
    expect(
      preview.width + kTonightGridGap + equipment.width,
      closeTo(gridWidth, 1),
      reason: 'what the preview does not use goes to its neighbour',
    );
  });
}

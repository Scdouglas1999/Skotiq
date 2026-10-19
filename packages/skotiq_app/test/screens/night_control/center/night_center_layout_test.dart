// The center column at the sizes that matter: the owner's window (744x758
// center slot), the plan-drawer width on a short window (600x700), a short
// window that folds the charts, and a phone's single column. Each board, at
// 1x and 1.3x text, in the three themes, with no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';
import 'package:skotiq_app/screens/night_control/center/frame_strip.dart';
import 'package:skotiq_app/screens/night_control/center/manual_action_bar.dart';
import 'package:skotiq_app/screens/night_control/center/night_center.dart';
import 'package:skotiq_app/screens/night_control/center/session_charts_row.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import 'center_test_support.dart';

final _boards = <String, NightBoard Function()>{
  'ready': NightFixtures.ready,
  'running': NightFixtures.running,
  'autofocus': NightFixtures.autofocus,
};

void main() {
  for (final MapEntry(key: name, value: board) in _boards.entries) {
    for (final scale in <double>[1, 1.3]) {
      for (final size in <Size>[const Size(744, 758), const Size(600, 700)]) {
        testWidgets(
            '$name at ${size.width.toInt()}x${size.height.toInt()}, '
            '${scale}x text', (tester) async {
          final b = board();
          await pumpCenter(
            tester,
            centerOverrides(
              b,
              image: b.phase == NightRunPhase.ready ? null : testFrame(),
              frames: stripWithPaths(b.frames),
              autofocus: name == 'autofocus'
                  ? const NightAutofocusVm(point: 6, points: 9, hfr: 2.08)
                  : null,
            ),
            size: size,
            mode: size.width < NightControlLayout.drawerMinWidth
                ? NightControlMode.planDrawer
                : NightControlMode.threeColumn,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(ManualActionBar), findsOneWidget);
          expect(find.byType(FrameStrip), findsOneWidget);
          expect(find.byType(SessionChartsRow), findsOneWidget);
          final frame = tester.getSize(find.byType(FrameStage));
          expect(frame.height,
              greaterThanOrEqualTo(NightControlLayout.minFrameHeight));
          final charts = tester.getSize(find.byType(SessionChartsRow));
          expect(
            charts.height,
            size.height < NightControlLayout.compactBodyHeight
                ? NightControlLayout.compactChartRowHeight
                : NightControlLayout.chartRowHeight,
          );
        });
      }
    }
  }

  testWidgets(
      'a short window folds the charts before the frame drops below '
      '280', (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), image: testFrame()),
      size: const Size(744, 470),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SessionChartsRow), findsNothing);
    expect(
      tester.getSize(find.byType(FrameStage)).height,
      greaterThanOrEqualTo(NightControlLayout.minFrameHeight),
    );
    await tester.tap(find.text('Show charts'));
    await tester.pump();
    expect(find.byType(SessionChartsRow), findsOneWidget);
    expect(find.text('Hide charts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in <double>[1, 1.3]) {
    testWidgets('a phone column sizes the frame by its aspect, ${scale}x text',
        (tester) async {
      await pumpCenter(
        tester,
        centerOverrides(NightFixtures.running(), image: testFrame()),
        size: const Size(390, 844),
        mode: NightControlMode.singleColumn,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      final frame = tester.getSize(find.byType(FrameStage));
      expect(frame.height, inInclusiveRange(240, 360));
      expect(find.byType(PageView), findsOneWidget);
    });
  }

  for (final (name, theme) in <(String, ThemeData)>[
    ('light', SkotiqTheme.light),
    ('red night', SkotiqTheme.redNight),
  ]) {
    testWidgets('the running board renders in $name', (tester) async {
      final b = NightFixtures.running();
      await pumpCenter(
        tester,
        centerOverrides(
          b,
          image: testFrame(),
          frames: stripWithPaths(b.frames),
          exposure: const NightExposureVm(elapsed: 72, total: 180),
        ),
        theme: theme,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('#44 exposing'), findsOneWidget);
    });
  }

  testWidgets('the center column fills the 744 slot of the owner window',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), image: testFrame()),
    );
    expect(tester.getSize(find.byType(NightCenter)), const Size(744, 758));
    expect(
      tester.getSize(find.byType(FrameStage)).height,
      758 -
          ManualActionBar.height -
          FrameStrip.height -
          NightControlLayout.chartRowHeight,
    );
  });
}

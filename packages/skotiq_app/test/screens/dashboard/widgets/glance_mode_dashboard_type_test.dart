// Regression guard for: "Glance mode toggle on the Dashboard changes nothing on
// the Dashboard".
//
// The eye icon in the dashboard command bar promises to bump "the dashboard's
// secondary-status type up so the run can be read from across the room", but
// SkotiqTypography.glanceStyle had exactly two callers repo-wide, both
// run-scoped sequencer panels that render nothing outside an active run. A
// full-res pixel diff of the dashboard with the toggle on vs off differed in
// 0.005% of pixels — none of it text. These tests drive the real
// glanceModeProvider (the one the toggle drives) and assert the rendered type
// on the always-visible dashboard readouts actually changes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_now_imaging.dart';
import 'package:skotiq_app/screens/dashboard/widgets/quick_stats_card.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

const _sky = RunDashboardSkyStats(
  altitudeDeg: 62.0,
  azimuthDeg: 180.0,
  timeToSet: Duration(hours: 3),
  timeToTransit: Duration(minutes: 10),
  horizonDeg: 20.0,
);

double _fontSizeOf(WidgetTester tester, String text) {
  return tester.widget<Text>(find.text(text)).style!.fontSize!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('glance mode enlarges the Now Imaging strip', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const CockpitNowImaging(),
      extraOverrides: [
        runDashboardActiveTargetProvider.overrideWithValue(
          TargetHeaderNode(targetName: 'M31', raHours: 0.71, decDegrees: 41.27),
        ),
        runDashboardSkyStatsProvider.overrideWithValue(_sky),
      ],
      settle: false,
    );
    await tester.pump();
    addTearDown(() async => handle.database.close());

    // Resting layout: the label sits well under the legibility floor.
    expect(_fontSizeOf(tester, 'Altitude'),
        lessThan(SkotiqTypography.glanceMinFontSize));

    await handle.container.read(glanceModeProvider.notifier).setEnabled(true);
    await tester.pump();

    expect(_fontSizeOf(tester, 'Altitude'),
        greaterThanOrEqualTo(SkotiqTypography.glanceMinFontSize),
        reason: 'the toggle claims to bump the dashboard status type');
    expect(_fontSizeOf(tester, 'To meridian'),
        greaterThanOrEqualTo(SkotiqTypography.glanceMinFontSize));

    await handle.container.read(glanceModeProvider.notifier).setEnabled(false);
    await tester.pump();

    expect(_fontSizeOf(tester, 'Altitude'),
        lessThan(SkotiqTypography.glanceMinFontSize),
        reason: 'turning it back off must restore the dense layout');
  });

  testWidgets('glance mode enlarges the Quick Stats readouts', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const QuickStatsCard(colors: SkotiqColors.dark),
      settle: false,
    );
    await tester.pump();
    addTearDown(() async => handle.database.close());

    expect(_fontSizeOf(tester, 'Sensor'),
        lessThan(SkotiqTypography.glanceMinFontSize));

    await handle.container.read(glanceModeProvider.notifier).setEnabled(true);
    await tester.pump();

    for (final label in ['Sensor', 'Focus', 'HFR', 'RMS']) {
      expect(_fontSizeOf(tester, label),
          greaterThanOrEqualTo(SkotiqTypography.glanceMinFontSize),
          reason: '$label is one of the readouts the toggle names');
    }
  });
}

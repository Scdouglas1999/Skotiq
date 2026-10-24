import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/sequencer_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

void main() {
  testWidgets('unsupported trigger explains and disables standalone monitoring',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SequencerSettings(),
      size: const Size(1400, 1000),
    );
    await handle.container
        .read(globalMeridianFlipSettingsProvider.notifier)
        .updateSettings(
          const MeridianFlipSettings(
            standaloneMonitoringEnabled: true,
            triggerMethod: MeridianTriggerMethod.minutesBeforeLimit,
          ),
        );
    await tester.pumpAndSettle();

    final row = find.ancestor(
      of: find.text('Standalone monitoring'),
      matching: find.byType(SettingRow),
    );
    final toggle = tester.widget<SettingsSwitch>(
      find.descendant(of: row, matching: find.byType(SettingsSwitch)),
    );

    expect(toggle.enabled, isFalse);
    expect(toggle.value, isFalse);
    expect(
      find.textContaining(
        'Mount tracking-limit time is only reported to an active sequence.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'stop tracking before meridian is offered only with minutes past meridian',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SequencerSettings(),
      size: const Size(1400, 1000),
    );
    final notifier =
        handle.container.read(globalMeridianFlipSettingsProvider.notifier);
    await notifier.updateSettings(
      const MeridianFlipSettings(
        minutesPastMeridian: 20,
        pauseBeforeMeridianMinutes: 20,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stop tracking before meridian'), findsOneWidget);
    expect(
      find.text(
        '0 = off. Tracking stops this many minutes before the meridian and '
        'the flip runs at Minutes Past Meridian.',
      ),
      findsOneWidget,
    );

    await notifier.setTriggerMethod(MeridianTriggerMethod.hourAngleThreshold);
    await tester.pumpAndSettle();
    expect(find.text('Stop tracking before meridian'), findsNothing);
  });

  testWidgets('the tracking-limit choice defaults to flipping right away',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SequencerSettings(),
      size: const Size(1400, 1000),
    );
    await tester.pumpAndSettle();

    expect(find.text('When the mount stops at its limit'), findsOneWidget);
    expect(find.text('Flip right away'), findsOneWidget);
    expect(
      find.text(TrackingLimitPolicy.flipEarly.description),
      findsOneWidget,
    );

    await handle.container
        .read(globalMeridianFlipSettingsProvider.notifier)
        .setTrackingLimitPolicy(TrackingLimitPolicy.waitForFlipWindow);
    await tester.pumpAndSettle();
    expect(find.text('Wait for the flip window'), findsOneWidget);
    expect(
      find.text(TrackingLimitPolicy.waitForFlipWindow.description),
      findsOneWidget,
    );
  });

  testWidgets('the tracking-limit row fits a phone-width settings page',
      (tester) async {
    await pumpAppScreen(
      tester,
      const SequencerSettings(isMobile: true),
      size: const Size(360, 2400),
    );
    await tester.pumpAndSettle();
    expect(find.text('When the mount stops at its limit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

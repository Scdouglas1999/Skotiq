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
}

// A refused toggle must not keep drawing itself as ON.
//
// Live on the release bundle (2026-08-09): with no MQTT broker host set,
// tapping "Publish to Home Assistant" left the switch drawn ON and the
// subtitle still reading "Configure the MQTT broker above first". Pressing
// "Save Home Assistant config" then reported "Home Assistant config saved".
// Coming back to the page later, the toggle was OFF again — the app had said
// it saved something it discarded.
//
// The cause is that SettingsSwitch flips optimistically and only re-adopts the
// parent `value` while a write is in flight; a handler that refuses by simply
// returning never triggers that re-adoption.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_routing_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('refusing the Home Assistant publish toggle leaves it drawn OFF',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: NotificationRoutingSettings()),
      extraOverrides: [
        secretsStoreProvider
            .overrideWithValue(SecretsStore(InMemorySecureKeyValueStore())),
      ],
      settle: false,
    );
    await Future.wait([
      handle.container.read(notificationRoutingMatrixProvider.future),
      handle.container.read(mqttTransportConfigProvider.future),
      handle.container.read(homeAssistantConfigProvider.future),
    ]);
    await tester.pump();

    // No broker host has been configured, so discovery cannot be enabled.
    expect(handle.container.read(mqttTransportConfigProvider).value?.host, '');

    final title = find.text('Publish to Home Assistant');
    await tester.scrollUntilVisible(
      title,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final toggle = find.descendant(
      of: find.ancestor(of: title, matching: find.byType(SettingRow)),
      matching: find.byType(SkotiqSwitch),
    );
    expect(tester.widget<SkotiqSwitch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pump();
    // Past SettingsSwitch's 300ms write debounce, so a real write would have
    // landed by now.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('Set an MQTT broker host above'), findsOneWidget,
        reason: 'the refusal has to be explained');
    expect(
      tester.widget<SkotiqSwitch>(toggle).value,
      isFalse,
      reason: 'a refused toggle must snap back, not keep claiming it is on',
    );
    expect(
      handle.container.read(homeAssistantConfigProvider).value?.enabled,
      isFalse,
    );
  });
}

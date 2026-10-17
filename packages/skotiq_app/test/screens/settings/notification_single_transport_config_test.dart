// The Notifications page exposes exactly ONE Discord configuration and ONE
// Pushover configuration.
//
// Two sections — an `app_settings`-backed "Discord" near the top and a
// keyring-backed "Discord (routing matrix)" far below — contradict each other:
// saving a webhook into the routing-matrix one leaves the top section's field
// empty, and its "Test Discord" answers "Please enter a Discord webhook URL".
// Same for Pushover.
//
// The keyring-backed section is the single local configuration, and it adopts
// (and keeps in step) the legacy plaintext keys the pre-router
// `NotificationService` still sends from.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _legacyWebhook = 'https://discord.com/api/webhooks/111/LEGACY';
const _legacyPushoverToken = 'legacy-pushover-token';
const _legacyPushoverUser = 'legacy-pushover-user';

class _LegacyAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        discordWebhook: _legacyWebhook,
        pushoverKey: _legacyPushoverToken,
        pushoverUser: _legacyPushoverUser,
      );
}

Future<HarnessHandle> _pumpNotifications(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const NotificationSettings(),
    size: const Size(1200, 2400),
    extraOverrides: [
      secretsStoreProvider.overrideWithValue(
        SecretsStore(InMemorySecureKeyValueStore()),
      ),
      appSettingsProvider.overrideWith(_LegacyAppSettings.new),
    ],
    settle: false,
  );
  await Future.wait([
    handle.container.read(appSettingsProvider.future),
    handle.container.read(notificationRoutingMatrixProvider.future),
    handle.container.read(discordTransportConfigProvider.future),
    handle.container.read(pushoverTransportConfigProvider.future),
  ]);
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the Notifications page carries one Discord and one Pushover section',
    (tester) async {
      final handle = await _pumpNotifications(tester);
      addTearDown(handle.container.dispose);

      // Section headings. `find.text` is exact, so the "Test Discord" /
      // "Save Discord config" row titles do not count here.
      expect(find.text('Discord'.toUpperCase()), findsOneWidget);
      expect(find.text('Pushover'.toUpperCase()), findsOneWidget);
      expect(find.text('Discord (routing matrix)'), findsNothing);
      expect(find.text('Pushover (routing matrix)'), findsNothing);

      // One credential field per transport, not two.
      expect(find.text('Webhook URL'), findsOneWidget);
      expect(find.text('API token'), findsOneWidget);
      expect(find.text('User key'), findsOneWidget);
      // The legacy routing-matrix rows used to be told apart from these by
      // their Title Case ('API key', 'User key'); both spellings are sentence
      // case now, so absence is no longer expressible as text. The
      // findsOneWidget above is the same claim and a stronger one: exactly one
      // credential field per transport, so no legacy row is duplicating them.

      // One test action per transport.
      expect(find.text('Test Discord'), findsOneWidget);
      expect(find.text('Test Pushover'), findsOneWidget);
    },
  );

  testWidgets(
    'a legacy plaintext webhook is adopted, so the one section never claims '
    'Discord is unconfigured',
    (tester) async {
      final handle = await _pumpNotifications(tester);
      addTearDown(handle.container.dispose);

      // The surviving section reports the transport as configured…
      expect(find.text('•••••••• (stored securely)'), findsNWidgets(3));

      // …because the legacy value really was moved into the keyring-backed
      // config the router sends from — not merely rendered as if it had been.
      final discord = handle.container.read(discordTransportConfigProvider);
      expect(discord.value?.webhookUrl, _legacyWebhook);
      final pushover = handle.container.read(pushoverTransportConfigProvider);
      expect(pushover.value?.apiToken, _legacyPushoverToken);
      expect(pushover.value?.userKey, _legacyPushoverUser);

      final secrets = handle.container.read(secretsStoreProvider);
      expect(await secrets.read(SecretField.discordWebhookUrl), _legacyWebhook);
      expect(
        await secrets.read(SecretField.pushoverApiToken),
        _legacyPushoverToken,
      );
    },
  );
}

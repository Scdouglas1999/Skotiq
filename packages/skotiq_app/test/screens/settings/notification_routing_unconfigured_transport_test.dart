// Per-event routing must not promise a transport the router would drop.
//
// NotificationRouter._eligibleTransports skips any transport whose
// isConfigured is false, silently. Before this test the editor offered every
// transport as an equal choice and the saved row read "-> In-app banner +
// Email (SMTP) + Telegram + MQTT" on a rig with no SMTP host, no bot token and
// no broker.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_routing_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(
  WidgetTester tester, {
  SkotiqDatabase? database,
  SecretsStore? secrets,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const SingleChildScrollView(child: NotificationRoutingSettings()),
    database: database,
    extraOverrides: [
      secretsStoreProvider.overrideWithValue(
        secrets ?? SecretsStore(InMemorySecureKeyValueStore()),
      ),
    ],
    settle: false,
  );
  await Future.wait([
    handle.container.read(notificationRoutingMatrixProvider.future),
    handle.container.read(emailTransportConfigProvider.future),
    handle.container.read(webhookTransportConfigProvider.future),
    handle.container.read(pushoverTransportConfigProvider.future),
    handle.container.read(telegramTransportConfigProvider.future),
    handle.container.read(discordTransportConfigProvider.future),
    handle.container.read(mqttTransportConfigProvider.future),
  ]);
  await tester.pump();
  return handle;
}

Future<void> _openEditor(WidgetTester tester, String category) async {
  final row = find.ancestor(
    of: find.text(category),
    matching: find.byType(SettingRow),
  );
  final edit = find.descendant(of: row, matching: find.text('Edit'));
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.scrollUntilVisible(
    edit,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  await tester.tap(edit);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the transport picker names channels that cannot deliver',
      (tester) async {
    final handle = await _pump(tester);
    addTearDown(handle.container.dispose);

    await _openEditor(tester, 'Sequence Paused');

    expect(find.text('Email (SMTP) (not configured)'), findsOneWidget);
    expect(find.text('Telegram (not configured)'), findsOneWidget);
    expect(find.text('MQTT (not configured)'), findsOneWidget);
    // In-app needs no credentials, so it must not be smeared with the warning.
    expect(find.text('In-app banner'), findsOneWidget);
  });

  testWidgets('selecting an unconfigured transport says it will not reach you',
      (tester) async {
    final handle = await _pump(tester);
    addTearDown(handle.container.dispose);

    await _openEditor(tester, 'Sequence Paused');
    await tester.tap(find.text('Telegram (not configured)'));
    await tester.pump();

    expect(
      find.textContaining('not configured, so this rule will not reach you'),
      findsOneWidget,
    );
  });

  testWidgets('the saved summary row marks the transports that will not fire',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    await database.settingsDao.setSetting(
      'notification_routing_matrix',
      jsonEncode(
        NotificationRoutingMatrix.defaults()
            .withRule(
              NotificationCategory.sequencePaused,
              const NotificationRoutingRule(
                transports: [
                  NotificationTransportKind.inApp,
                  NotificationTransportKind.email,
                  NotificationTransportKind.telegram,
                ],
                minSeverity: EventSeverity.info,
              ),
            )
            .toJson(),
      ),
    );

    final handle = await _pump(tester, database: database);
    addTearDown(handle.container.dispose);

    expect(
      find.text(
        '→ In-app banner + Email (SMTP) (not configured) + '
        'Telegram (not configured)',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a configured transport is presented plainly', (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    final secrets = SecretsStore(InMemorySecureKeyValueStore());
    await secrets.write(SecretField.telegramBotToken, 'bot-token');
    await database.settingsDao.setSetting(
      'notification_secrets_migrated_v2',
      'true',
    );
    await database.settingsDao.setSetting(
      'notification_transport_telegram',
      jsonEncode(const TelegramTransportConfig(chatId: '4242').toJson()),
    );
    await database.settingsDao.setSetting(
      'notification_routing_matrix',
      jsonEncode(
        NotificationRoutingMatrix.defaults()
            .withRule(
              NotificationCategory.sequencePaused,
              const NotificationRoutingRule(
                transports: [NotificationTransportKind.telegram],
                minSeverity: EventSeverity.info,
              ),
            )
            .toJson(),
      ),
    );

    final handle = await _pump(tester, database: database, secrets: secrets);
    addTearDown(handle.container.dispose);

    expect(find.text('→ Telegram'), findsOneWidget);
    expect(find.text('→ Telegram (not configured)'), findsNothing);
  });
}

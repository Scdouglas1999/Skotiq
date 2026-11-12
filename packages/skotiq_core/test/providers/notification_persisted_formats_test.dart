// Values exactly as the build at c04d55c8d wrote them to a user's settings
// table and keyring must still load.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

const _matrix =
    '{"enabled":true,"rules":{'
    '"sequenceFailed":{"transports":["inApp","systemPush","discord"],'
    '"minSeverity":"error","maxPerHour":4,"debounceSeconds":30,'
    '"titleTemplate":"Run failed","bodyTemplate":null,"enabled":true},'
    '"custom":{"transports":["inApp","pushover"],"minSeverity":"info",'
    '"maxPerHour":0,"debounceSeconds":0,"titleTemplate":null,'
    '"bodyTemplate":null,"enabled":false},'
    '"guidingLost":{"transports":["telegram","mqtt","email","webhookGeneric"],'
    '"minSeverity":"critical","maxPerHour":0,"debounceSeconds":0,'
    '"titleTemplate":null,"bodyTemplate":null,"enabled":true}}}';

const _discord =
    '{"webhookUrl":"","username":"Rig","avatarUrl":"https://example.com/a.png"}';
const _pushover = '{"apiToken":"","userKey":"","device":"phone","priority":1}';
const _push =
    '{"enabled":true,"notifySequenceCompleted":false,'
    '"notifySequenceFailed":true,"notifyMeridianFlip":false,'
    '"notifyWeatherUnsafe":true,"notifyGuidingLost":true,'
    '"notifyExposureFailed":true,"notifyAutofocusFailed":false,'
    '"notifyEquipmentDisconnected":true}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a routing matrix, transport configs and push toggles written by the '
      'earlier build load unchanged', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final keyring = InMemorySecureKeyValueStore();
    final secrets = SecretsStore(keyring);
    await db.settingsDao.setSetting('notification_routing_matrix', _matrix);
    await db.settingsDao.setSetting('notification_transport_discord', _discord);
    await db.settingsDao.setSetting(
      'notification_transport_pushover',
      _pushover,
    );
    await db.settingsDao.setSetting('push_notification_config', _push);
    await db.settingsDao.setSetting('notification_secrets_migrated_v2', 'true');
    await secrets.write(
      SecretField.discordWebhookUrl,
      'https://discord.com/api/webhooks/1/abc',
    );
    await secrets.write(SecretField.pushoverApiToken, 'token');
    await secrets.write(SecretField.pushoverUserKey, 'user');

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secretsStoreProvider.overrideWithValue(secrets),
      ],
    );
    addTearDown(container.dispose);

    final matrix = await container.read(
      notificationRoutingMatrixProvider.future,
    );
    expect(matrix.enabled, isTrue);
    expect(
      matrix.rules[NotificationCategory.sequenceFailed],
      const NotificationRoutingRule(
        transports: [
          NotificationTransportKind.inApp,
          NotificationTransportKind.systemPush,
          NotificationTransportKind.discord,
        ],
        minSeverity: EventSeverity.error,
        maxPerHour: 4,
        debounceSeconds: 30,
        titleTemplate: 'Run failed',
      ),
    );
    expect(
      matrix.rules[NotificationCategory.custom],
      const NotificationRoutingRule(
        transports: [
          NotificationTransportKind.inApp,
          NotificationTransportKind.pushover,
        ],
        enabled: false,
      ),
      reason: 'no earlier credential in app settings, so no row is touched',
    );
    expect(matrix.rules[NotificationCategory.guidingLost]!.transports, const [
      NotificationTransportKind.telegram,
      NotificationTransportKind.mqtt,
      NotificationTransportKind.email,
      NotificationTransportKind.webhookGeneric,
    ]);
    expect(
      matrix.rules[NotificationCategory.guidingLost]!.minSeverity,
      EventSeverity.critical,
    );

    expect(
      await container.read(discordTransportConfigProvider.future),
      const DiscordTransportConfig(
        webhookUrl: 'https://discord.com/api/webhooks/1/abc',
        username: 'Rig',
        avatarUrl: 'https://example.com/a.png',
      ),
    );
    expect(
      await container.read(pushoverTransportConfigProvider.future),
      const PushoverTransportConfig(
        apiToken: 'token',
        userKey: 'user',
        device: 'phone',
        priority: 1,
      ),
    );

    final push = await container.read(pushNotificationConfigProvider.future);
    expect(push.allows(PushToggle.sequenceCompleted), isFalse);
    expect(push.allows(PushToggle.sequenceFailed), isTrue);
    expect(push.allows(PushToggle.meridianFlip), isFalse);
    expect(push.allows(PushToggle.autofocusFailed), isFalse);
    expect(push.allows(PushToggle.equipmentDisconnected), isTrue);
  });

  test('every category has one presentation and the phone feed escalates '
      'exactly the categories it did', () {
    final pushed = {
      for (final c in NotificationCategory.values)
        if (NotificationPresentation.of(c).push != null) c.name,
    };
    expect(pushed, {
      'sequenceCompleted',
      'sequenceFailed',
      'sequenceStopped',
      'targetCompleted',
      'meridianFlipPerformed',
      'autofocusContinued',
      'autofocusFailed',
      'problemNoticed',
      'exposureFailed',
      'recoveryGaveUp',
      'guidingLost',
      'weatherUnsafe',
      'mountFault',
      'transientDiscovered',
      'darkroomDraftReady',
      'diskSpaceLow',
      'equipmentDisconnected',
      'custom',
    });
    for (final c in NotificationCategory.values) {
      final p = NotificationPresentation.of(c);
      if (c.isCritical) {
        expect(
          p.push!.priority,
          PushNotificationPriority.critical,
          reason: c.name,
        );
      }
    }
  });
}

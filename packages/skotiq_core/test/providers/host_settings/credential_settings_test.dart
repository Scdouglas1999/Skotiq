// A linked client changes the host's settings, but not the rows that hold a
// credential or say where the host sends one. The host decides that per row
// from these declarations.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/providers/host_settings/credential_settings.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart'
    show AppSettingsNotifier;
import 'package:skotiq_core/src/services/sync/sync_service.dart';

void main() {
  test('the settings declared as credentials are credentials', () {
    for (final key in const [
      'discord_webhook',
      'pushover_key',
      'pushover_user',
    ]) {
      expect(isCredentialSettingKey(key), isTrue, reason: key);
    }
    expect(AppSettingsNotifier.credentialWireKeys, {
      'discordWebhook',
      'pushoverKey',
      'pushoverUser',
    });
  });

  test('every notification server and the cloud backup target count too', () {
    for (final kind in NotificationTransportKind.values) {
      expect(
        isCredentialSettingKey(kind.settingKey),
        isTrue,
        reason: kind.name,
      );
    }
    for (final key in const [
      SyncSettingsKeys.serverUrl,
      SyncSettingsKeys.username,
      SyncSettingsKeys.s3Endpoint,
      SyncSettingsKeys.s3AccessKey,
    ]) {
      expect(isCredentialSettingKey(key), isTrue, reason: key);
    }
  });

  group('a link without admin access', () {
    test('reads a set credential as the marker and an unset one as empty', () {
      expect(
        withCredentialsHidden({
          'discordWebhook': 'https://discord.com/api/webhooks/1/secret',
          'pushoverKey': '',
          'ditherEnabled': true,
          'imageOutputPath': '/captures',
        }),
        {
          'discordWebhook': credentialSetMarker,
          'pushoverKey': '',
          'ditherEnabled': true,
          'imageOutputPath': '/captures',
        },
      );
    });

    test('reads the credential rows the same way', () {
      expect(
        rowsWithCredentialsHidden({
          'discord_webhook': 'https://discord.com/api/webhooks/1/secret',
          'pushover_user': '',
          'dither_enabled': 'true',
        }),
        {
          'discord_webhook': credentialSetMarker,
          'pushover_user': '',
          'dither_enabled': 'true',
        },
      );
    });

    SkotiqEvent settingsChanged(String key, Object? value) => SkotiqEvent(
      timestamp: 1,
      severity: EventSeverity.info,
      category: EventCategory.system,
      eventType: settingsChangedEventType,
      data: {'key': key, 'value': value, 'changedAt': 'now'},
      seq: 7,
      correlatingCommandId: 'cmd-1',
    );

    test('sees a credential change as the marker, with the rest of the '
        'event as it was', () {
      final hidden = eventWithCredentialsHidden(
        settingsChanged('pushoverKey', 'app-token'),
      );
      expect(hidden.data, {
        'key': 'pushoverKey',
        'value': credentialSetMarker,
        'changedAt': 'now',
      });
      expect(hidden.seq, 7);
      expect(hidden.correlatingCommandId, 'cmd-1');
      expect(
        eventWithCredentialsHidden(settingsChanged('pushoverKey', '')).data,
        containsPair('value', ''),
        reason: 'clearing a credential is not a secret',
      );
    });

    test('sees a full settings snapshot with its credentials hidden', () {
      final hidden = eventWithCredentialsHidden(
        settingsChanged('__snapshot__', {
          'discordWebhook': 'https://discord.com/api/webhooks/1/secret',
          'ditherEnabled': false,
        }),
      );
      expect(hidden.data['value'], {
        'discordWebhook': credentialSetMarker,
        'ditherEnabled': false,
      });
    });

    test('gets every other event untouched', () {
      final ordinary = settingsChanged('ditherEnabled', false);
      expect(identical(eventWithCredentialsHidden(ordinary), ordinary), isTrue);
      const other = SkotiqEvent(
        timestamp: 1,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: 'MountPositionChanged',
        data: {'key': 'discordWebhook', 'value': 'not a setting'},
      );
      expect(identical(eventWithCredentialsHidden(other), other), isTrue);
    });
  });

  test('ordinary settings a user changes mid-session are not', () {
    for (final key in const [
      'image_output_path',
      'observer_latitude',
      'dither_enabled',
      'sequencer_dither_pixels',
      'notification_routing_matrix',
      'home_assistant_discovery',
    ]) {
      expect(isCredentialSettingKey(key), isFalse, reason: key);
    }
  });
}

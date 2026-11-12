// A linked client changes the host's settings, but not the ones the settings
// catalog keeps for admin links. The host decides that per row from these
// declarations.

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
      expect(adminOnlyRow(key), AdminOnly.credential, reason: key);
    }
  });

  test('every notification server, the cloud backup target and the Home '
      'Assistant row say where the host sends a credential', () {
    for (final key in [
      for (final kind in NotificationTransportKind.values)
        'notification_transport_${kind.name}',
      SyncSettingsKeys.serverUrl,
      SyncSettingsKeys.username,
      SyncSettingsKeys.s3Endpoint,
      SyncSettingsKeys.s3AccessKey,
      'home_assistant_discovery',
    ]) {
      expect(adminOnlyRow(key), AdminOnly.credentialTarget, reason: key);
    }
  });

  test('the rows that decide which programs the host runs are declared', () {
    for (final key in const [
      'astap_path',
      'astrometry_path',
      'phd2_path',
      'plugin_enablement',
    ]) {
      expect(adminOnlyRow(key), AdminOnly.hostProgram, reason: key);
    }
  });

  test('the host\'s backups, its catalog source and how it is reached stay '
      'with admin links', () {
    for (final key in const [
      'backup.directory',
      'autosave.backup_enabled',
      'autosave.backup_interval_hours',
      'autosave.max_backups',
      'autosave.last_backup_at',
      'catalog_base_url',
      'web_server_enabled',
      'web_server_port',
    ]) {
      expect(adminOnlyRow(key), AdminOnly.administration, reason: key);
    }
  });

  // The catalog source travels in the key/value store, not this document.
  test('the typed settings document names the same fields', () {
    expect(AppSettingsNotifier.adminOnlyWireFields, {
      'discordWebhook': AdminOnly.credential,
      'pushoverKey': AdminOnly.credential,
      'pushoverUser': AdminOnly.credential,
      'astapPath': AdminOnly.hostProgram,
      'astrometryPath': AdminOnly.hostProgram,
      'phd2Path': AdminOnly.hostProgram,
      'webServerEnabled': AdminOnly.administration,
      'webServerPort': AdminOnly.administration,
    });
  });

  test('a row saying where the host sends a credential is not hidden', () {
    expect(
      rowsWithCredentialsHidden({
        'notification_transport_email': '{"host":"smtp.example.org"}',
      }),
      {'notification_transport_email': '{"host":"smtp.example.org"}'},
    );
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
      'phd2_host',
      'sequencer_dither_pixels',
      'notification_routing_matrix',
      'autosave.sequence_enabled',
      'autosave.sequence_interval_minutes',
      'a_row_declared_nowhere',
    ]) {
      expect(adminOnlyRow(key), isNull, reason: key);
    }
  });
}

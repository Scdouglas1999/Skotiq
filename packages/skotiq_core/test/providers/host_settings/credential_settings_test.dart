// A linked client changes the host's settings, but not the rows that hold a
// credential or say where the host sends one. The host decides that per row
// from these declarations.

import 'package:flutter_test/flutter_test.dart';
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

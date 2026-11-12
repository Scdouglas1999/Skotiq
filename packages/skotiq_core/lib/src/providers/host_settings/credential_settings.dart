/// Which `app_settings` rows hold a credential.
///
/// A linked client may change the imaging host's settings, but a row that
/// holds a credential, or says where the host sends one, changes only from a
/// link with admin access. The host refuses the change from any lesser link.
library;

import '../../models/notification/notification_categories.dart'
    show NotificationTransportKind;
import '../../services/sync/sync_service.dart' show SyncSettingsKeys;
import '../../settings/app_settings_codec.dart';

/// Key prefixes of host-owned rows that say where the host sends a credential
/// it keeps in its keyring: a notification transport's server and the cloud
/// backup target. Pointing one elsewhere hands the credential to whoever runs
/// that server, so these rows count as credentials themselves.
const List<String> credentialSettingKeyPrefixes = [
  NotificationTransportKind.settingKeyPrefix,
  SyncSettingsKeys.prefix,
];

/// True when the row under [key] holds a credential or says where the host
/// sends one.
bool isCredentialSettingKey(String key) {
  if (AppSettingsCodec.credentialKeys.contains(key)) return true;
  for (final prefix in credentialSettingKeyPrefixes) {
    if (key.startsWith(prefix)) return true;
  }
  return false;
}

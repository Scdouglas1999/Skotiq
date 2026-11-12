/// Which `app_settings` rows hold a credential, and how a link without admin
/// access sees them.
///
/// A linked client may change the imaging host's settings, but a row that
/// holds a credential, or says where the host sends one, changes only from a
/// link with admin access. The host refuses the change from any lesser link,
/// and tells such a link whether a credential is set, never its value.
library;

import '../../models/backend/event_types.dart';
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

/// What a link without admin access reads in place of a credential that is
/// set. A credential that is not set reads as empty for every link. Posted
/// back to the host, the marker leaves the credential as it is.
const String credentialSetMarker = '(set on the imaging host)';

String _hidden(String value) => value.isEmpty ? '' : credentialSetMarker;

/// The host's typed [settings], keyed by wire field, as a link without admin
/// access reads them: each credential that is set reads as
/// [credentialSetMarker].
Map<String, dynamic> withCredentialsHidden(Map<String, dynamic> settings) => {
  for (final MapEntry(:key, :value) in settings.entries)
    key: value is String && AppSettingsCodec.credentialWireKeys.contains(key)
        ? _hidden(value)
        : value,
};

/// [settings] posted to the host without the credentials that came back as
/// [credentialSetMarker], so the host keeps those as they are.
Map<String, dynamic> withoutCredentialMarkers(Map<String, dynamic> settings) =>
    {
      for (final MapEntry(:key, :value) in settings.entries)
        if (value != credentialSetMarker ||
            !AppSettingsCodec.credentialWireKeys.contains(key))
          key: value,
    };

/// The host's key/value [rows] as a link without admin access reads them.
Map<String, String> rowsWithCredentialsHidden(Map<String, String> rows) => {
  for (final MapEntry(:key, :value) in rows.entries)
    key: AppSettingsCodec.credentialKeys.contains(key) ? _hidden(value) : value,
};

/// [event] as a link without admin access receives it: a `settings.changed`
/// event carries a credential's marker in place of its value. Every other
/// event is returned as it is.
SkotiqEvent eventWithCredentialsHidden(SkotiqEvent event) {
  if (event.eventType != settingsChangedEventType) return event;
  final key = event.data['key'];
  final value = event.data['value'];
  final Object hidden;
  if (key == settingsSnapshotKey && value is Map<String, dynamic>) {
    hidden = withCredentialsHidden(value);
  } else if (value is String &&
      AppSettingsCodec.credentialWireKeys.contains(key)) {
    hidden = _hidden(value);
  } else {
    return event;
  }
  return event.copyWith(data: {...event.data, 'value': hidden});
}

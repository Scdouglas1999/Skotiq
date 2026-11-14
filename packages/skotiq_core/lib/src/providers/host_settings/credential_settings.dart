/// Which `app_settings` rows only a link with admin access changes, and how
/// a link without it sees the credentials among them.
///
/// A linked client may change the imaging host's settings, except the ones
/// declared [AdminOnly] where they are declared (`app_settings_table.dart`,
/// `store_settings.dart`). The host refuses a change to one from any lesser
/// link, and tells such a link whether a credential is set, never its value.
library;

import '../../models/backend/event_types.dart';
import '../../settings/app_settings_codec.dart';
import '../../settings/app_settings_table.dart';
import '../../settings/setting.dart';
import '../../settings/store_settings.dart';

const List<Setting<Object?>> _declared = [
  ...kAppSettingsTable,
  ...StoreSettings.all,
];

final Map<String, AdminOnly> _adminOnlyRows = {
  for (final setting in _declared)
    if (setting.adminOnly != null)
      for (final key in setting.keys) key: setting.adminOnly!,
};

/// Why only a link with admin access changes the row under [key], or null
/// when any link that may change settings changes it.
AdminOnly? adminOnlyRow(String key) {
  final declared = _adminOnlyRows[key];
  if (declared != null) return declared;
  for (final family in StoreSettings.families) {
    if (family.adminOnly != null && family.holds(key)) return family.adminOnly;
  }
  return null;
}

final Set<String> _credentialWireFields = {
  for (final MapEntry(:key, :value)
      in AppSettingsCodec.adminOnlyWireFields.entries)
    if (value == AdminOnly.credential) key,
};

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
    key: value is String && _credentialWireFields.contains(key)
        ? _hidden(value)
        : value,
};

/// [settings] posted to the host without the credentials that came back as
/// [credentialSetMarker], so the host keeps those as they are.
Map<String, dynamic> withoutCredentialMarkers(
  Map<String, dynamic> settings,
) => {
  for (final MapEntry(:key, :value) in settings.entries)
    if (value != credentialSetMarker || !_credentialWireFields.contains(key))
      key: value,
};

/// The host's key/value [rows] as a link without admin access reads them.
Map<String, String> rowsWithCredentialsHidden(Map<String, String> rows) => {
  for (final MapEntry(:key, :value) in rows.entries)
    key: adminOnlyRow(key) == AdminOnly.credential ? _hidden(value) : value,
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
  } else if (value is String && _credentialWireFields.contains(key)) {
    hidden = _hidden(value);
  } else {
    return event;
  }
  return event.copyWith(data: {...event.data, 'value': hidden});
}

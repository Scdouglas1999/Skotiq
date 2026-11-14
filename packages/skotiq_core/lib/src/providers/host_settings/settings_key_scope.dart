/// Which machine owns a row of the `app_settings` key/value store.
///
/// A linked client mirrors the imaging host: every setting that changes what
/// the rig does, what it captures, where frames go or how the night is run is
/// read from and written to the host. Only the preferences that describe how
/// THIS screen presents the app stay on the device that renders it. Each
/// setting says which it is where it is declared (`app_settings_table.dart`,
/// `store_settings.dart`). A key declared nowhere is host-owned, so a new rig
/// setting is mirrored by default and a new presentation preference has to be
/// declared as this computer's on purpose.
library;

import '../../settings/app_settings_codec.dart';
import '../../settings/setting.dart';
import '../../settings/store_settings.dart';

final Set<String> _deviceLocalKeys = {
  ...AppSettingsCodec.thisComputerKeys,
  for (final setting in StoreSettings.all)
    if (setting.sync == SettingSync.thisComputer) ...setting.keys,
};

final List<SettingFamily> _deviceLocalFamilies = [
  for (final family in StoreSettings.families)
    if (family.sync == SettingSync.thisComputer) family,
];

/// True when [key] is a presentation preference of the device rendering the
/// UI and must never be read from or written to the imaging host.
bool isDeviceLocalSettingKey(String key) =>
    _deviceLocalKeys.contains(key) ||
    _deviceLocalFamilies.any((family) => family.holds(key));

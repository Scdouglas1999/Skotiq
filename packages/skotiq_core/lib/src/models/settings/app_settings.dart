/// The host/client settings document ([AppSettings], generated from the
/// settings table) and the values it carries.
library;

import 'app_settings_wire.g.dart';

export 'app_settings_values.dart';
export 'app_settings_wire.g.dart';

extension AppSettingsExtension on AppSettings {
  double get effectiveLatitude => location?.latitude ?? latitude;

  double get effectiveLongitude => location?.longitude ?? longitude;

  double get effectiveElevation => location?.elevation ?? elevation;
}

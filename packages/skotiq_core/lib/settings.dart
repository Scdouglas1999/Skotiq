/// The settings table of skotiq_core: every setting, its kind and its stored form.
///
/// Exports only files under `src/settings/`.
library;

export 'src/settings/app_settings_state.g.dart';
export 'src/settings/capture_format.dart';
export 'src/settings/device_retries.dart';
export 'src/settings/guide_settle.dart';
export 'src/settings/preflight_strictness.dart';
export 'src/settings/setting.dart'
    show AdminOnly, Setting, SettingFamily, SettingSync, SettingValue;
export 'src/settings/store_settings.dart'
    show StoreSettings, defaultSkyAtlasLimitGb;

import '../database/database.dart';
import '../models/settings/app_settings.dart';
import '../models/weather/weather_settings.dart';
import '../providers/settings_provider.dart' show AppSettingsState;

/// Canonical, in-memory view of the ONE logical safety configuration.
///
/// "Is it safe to image, and what do we do when it isn't" is one logical
/// config split across THREE persistence stores:
///
///   1. [WeatherSettings] table (via `weatherSettingsDao`) — the weather
///      *threshold* values and the weather-safety park/resume toggles.
///   2. `app_settings` key/value (via `AppSettingsNotifier`) — the fail-mode
///      policy and the park-on-unsafe / park-before-dawn policy flags.
///   3. `settings` key/value (via `settingsDao`) — the safety-monitor cadence
///      knobs (check interval, warning delay, required-safe duration) and the
///      auto-stop / auto-close-roof toggles plus the last acknowledgement.
///
/// [SafetyConfig] is the single read shape that stitches those three together.
/// It is a plain value object and owns no persistence; the owning store for
/// each field is documented inline so the write path ([SafetyConfigStore])
/// routes each field back to the column/key it lives in.
class SafetyConfig {
  // Weather thresholds (owned by WeatherSettings table)
  /// Max safe relative humidity (%) before hardware-weather is judged unsafe.
  final double maxHumidityPercent;

  /// Max safe wind speed (kph) before hardware-weather is judged unsafe.
  final double maxWindSpeedKph;

  /// Max safe cloud cover (%) before hardware-weather is judged unsafe.
  final double maxCloudCoverPercent;

  /// Cloud-density alert threshold (%) used by the radar alert path.
  final double cloudDensityThreshold;

  /// Radar alert trigger distance (km).
  final double triggerDistanceKm;

  /// Radar alert lead time (minutes).
  final int leadTimeMinutes;

  /// Radar refresh cadence (seconds).
  final int refreshIntervalSeconds;

  /// Preferred radar provider.
  final RadarProviderType preferredProvider;

  // Weather-safety toggles (owned by WeatherSettings table)
  /// Master enable for weather-safety monitoring. Also the default backing the
  /// safety-monitor `autoStopOnUnsafe` / `autoCloseRoofOnUnsafe` flags.
  final bool weatherSafetyEnabled;

  /// Auto-park the mount when weather threatens (weather-side toggle).
  final bool autoParkEnabled;

  /// Auto-resume imaging when weather clears.
  final bool autoResumeEnabled;

  // Policy flags (owned by app_settings key/value)
  /// Fail-mode policy for when no usable safety/weather data is available.
  final SafetyFailMode safetyFailMode;

  /// Policy: park (not just pause) when weather turns unsafe. Combined with
  /// [autoParkEnabled] to derive the wire `autoParkOnUnsafe`.
  final bool parkOnUnsafeWeather;

  /// Policy: park before astronomical dawn at end of night.
  final bool parkBeforeDawn;

  // Safety-monitor cadence (owned by settings key/value)
  /// Safety-monitor poll interval (seconds).
  final int checkIntervalSeconds;

  /// Delay before a transient unsafe reading is acted on (seconds).
  final int warningDelaySeconds;

  /// Continuous-safe duration required before auto-resume (seconds).
  final int requiredSafeDurationSeconds;

  /// Auto-stop the sequence on unsafe (safety-monitor toggle). Defaults to
  /// [weatherSafetyEnabled] when not explicitly persisted.
  final bool autoStopOnUnsafe;

  /// Auto-close the roof on unsafe (safety-monitor toggle). Defaults to
  /// [weatherSafetyEnabled] when not explicitly persisted.
  final bool autoCloseRoofOnUnsafe;

  const SafetyConfig({
    required this.maxHumidityPercent,
    required this.maxWindSpeedKph,
    required this.maxCloudCoverPercent,
    required this.cloudDensityThreshold,
    required this.triggerDistanceKm,
    required this.leadTimeMinutes,
    required this.refreshIntervalSeconds,
    required this.preferredProvider,
    required this.weatherSafetyEnabled,
    required this.autoParkEnabled,
    required this.autoResumeEnabled,
    required this.safetyFailMode,
    required this.parkOnUnsafeWeather,
    required this.parkBeforeDawn,
    required this.checkIntervalSeconds,
    required this.warningDelaySeconds,
    required this.requiredSafeDurationSeconds,
    required this.autoStopOnUnsafe,
    required this.autoCloseRoofOnUnsafe,
  });

  /// Derived: auto-park-on-unsafe as the safety-monitor endpoint reports it,
  /// `parkOnUnsafeWeather && weatherSettings.autoParkEnabled`. One definition,
  /// so the two endpoints cannot compute it differently.
  bool get autoParkOnUnsafe => parkOnUnsafeWeather && autoParkEnabled;
}

/// The ONE read/write path for [SafetyConfig].
///
/// Read: [load] aggregates the three stores into a single [SafetyConfig].
/// Write: the `set*` methods route each field back to its owning store, so
/// there is a single place that knows the field→store routing. Callers (the
/// headless weather / safety handlers, future UI) delegate here instead of
/// fanning writes across stores themselves; this is what removes the drift —
/// e.g. the `autoParkOnUnsafe` fan-out to BOTH `parkOnUnsafeWeather` and
/// `autoParkEnabled` now happens in exactly one method.
///
/// Persistence keys are intentionally identical to the pre-consolidation
/// code paths so already-stored data round-trips unchanged.
class SafetyConfigStore {
  final SkotiqDatabase _db;

  SafetyConfigStore(this._db);

  // settings key/value keys. These strings are on-disk contract: changing one
  // orphans every persisted row that uses it.
  static const String kCheckIntervalKey = 'safety_check_interval_seconds';
  static const String kWarningDelayKey = 'safety_warning_delay_seconds';
  static const String kRequiredSafeDurationKey =
      'safety_required_safe_duration_seconds';
  static const String kAutoStopKey = 'safety_auto_stop_on_unsafe';
  static const String kAutoCloseRoofKey = 'safety_auto_close_roof_on_unsafe';

  static int _parseIntSetting(
    Map<String, String> settings,
    String key,
    int fallback,
  ) {
    final raw = settings[key];
    if (raw == null) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  static bool _parseBoolSetting(
    Map<String, String> settings,
    String key,
    bool fallback,
  ) {
    final raw = settings[key];
    if (raw == null) return fallback;
    return raw.toLowerCase() == 'true' || raw == '1';
  }

  static RadarProviderType _parseProviderType(String providerString) {
    switch (providerString.toLowerCase()) {
      case 'goessatellite':
        return RadarProviderType.goesSatellite;
      case 'noaa':
        return RadarProviderType.noaa;
      case 'rainviewer':
        return RadarProviderType.rainviewer;
      case 'openmeteo':
        return RadarProviderType.openmeteo;
      case 'metno':
        return RadarProviderType.metno;
      case 'auto':
      default:
        return RadarProviderType.auto;
    }
  }

  /// Aggregate the three stores into the canonical [SafetyConfig].
  ///
  /// [appSettings] is the already-resolved app-settings state (so callers can
  /// pass the value they already hold from `appSettingsProvider` instead of
  /// forcing a second read). When null the policy fields fall back to the same
  /// defaults the handlers used (`failClosed`, park flags true).
  Future<SafetyConfig> load({AppSettingsState? appSettings}) async {
    final weatherRow = await _db.weatherSettingsDao.getOrCreateSettings();
    final stored = await _db.settingsDao.getAllSettings();

    final safetyFailMode =
        appSettings?.safetyFailMode ?? SafetyFailMode.failClosed;
    final parkOnUnsafeWeather = appSettings?.parkOnUnsafeWeather ?? true;
    final parkBeforeDawn = appSettings?.parkBeforeDawn ?? true;

    return SafetyConfig(
      maxHumidityPercent: weatherRow.maxHumidityPercent,
      maxWindSpeedKph: weatherRow.maxWindSpeedKph,
      maxCloudCoverPercent: weatherRow.maxCloudCoverPercent,
      cloudDensityThreshold: weatherRow.cloudDensityThreshold,
      triggerDistanceKm: weatherRow.triggerDistanceKm,
      leadTimeMinutes: weatherRow.leadTimeMinutes,
      refreshIntervalSeconds: weatherRow.refreshIntervalSeconds,
      preferredProvider: _parseProviderType(weatherRow.preferredProvider),
      weatherSafetyEnabled: weatherRow.weatherSafetyEnabled,
      autoParkEnabled: weatherRow.autoParkEnabled,
      autoResumeEnabled: weatherRow.autoResumeEnabled,
      safetyFailMode: safetyFailMode,
      parkOnUnsafeWeather: parkOnUnsafeWeather,
      parkBeforeDawn: parkBeforeDawn,
      checkIntervalSeconds: _parseIntSetting(stored, kCheckIntervalKey, 300),
      warningDelaySeconds: _parseIntSetting(stored, kWarningDelayKey, 60),
      requiredSafeDurationSeconds: _parseIntSetting(
        stored,
        kRequiredSafeDurationKey,
        300,
      ),
      autoStopOnUnsafe: _parseBoolSetting(
        stored,
        kAutoStopKey,
        weatherRow.weatherSafetyEnabled,
      ),
      autoCloseRoofOnUnsafe: _parseBoolSetting(
        stored,
        kAutoCloseRoofKey,
        weatherRow.weatherSafetyEnabled,
      ),
    );
  }

  // Write path: each setter routes to the field's owning store

  /// Persist the weather-side half of the auto-park-on-unsafe policy
  /// (`autoParkEnabled` in the WeatherSettings table).
  ///
  /// NOT the whole fan-out: the derived [SafetyConfig.autoParkOnUnsafe] is
  /// `parkOnUnsafeWeather && autoParkEnabled`, and the app-settings
  /// `park_on_unsafe_weather` half is notifier-owned — the safety endpoint
  /// (safety_monitor_handlers) writes it via
  /// `AppSettingsNotifier.setParkOnUnsafeWeather` alongside this call. A
  /// caller that writes only this half can leave the derived flag off even
  /// after "enabling" it.
  Future<void> setAutoParkOnUnsafe(bool value) async {
    await _db.weatherSettingsDao.updateSettings(autoParkEnabled: value);
  }

  Future<void> setAutoStopOnUnsafe(bool value) async {
    await _db.weatherSettingsDao.updateSettings(weatherSafetyEnabled: value);
    await _db.settingsDao.setSetting(kAutoStopKey, value.toString());
  }

  Future<void> setAutoCloseRoofOnUnsafe(bool value) async {
    await _db.settingsDao.setSetting(kAutoCloseRoofKey, value.toString());
  }

  Future<void> setCheckIntervalSeconds(int value) async {
    await _db.settingsDao.setSetting(kCheckIntervalKey, value.toString());
  }

  Future<void> setWarningDelaySeconds(int value) async {
    await _db.settingsDao.setSetting(kWarningDelayKey, value.toString());
  }

  Future<void> setRequiredSafeDurationSeconds(int value) async {
    await _db.settingsDao.setSetting(
      kRequiredSafeDurationKey,
      value.toString(),
    );
  }
}

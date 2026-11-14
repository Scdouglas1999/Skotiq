// Where catalog downloads come from, surfaced in Settings > Catalogs.
//
// Owns:
//   * catalogBaseUrl (a self-hoster's mirror of the catalog release)
part of '../settings_provider.dart';

extension CatalogSettingsSection on AppSettingsNotifier {
  /// Empty [url] goes back to the Skotiq release. Callers check the address
  /// with `catalogBaseUrlProblem` first.
  Future<void> setCatalogBaseUrl(String url) =>
      _set(AppSettingDefs.catalogBaseUrl, url.trim());
}

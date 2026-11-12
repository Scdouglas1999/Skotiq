import '../../database/daos/settings_dao.dart';
import '../../settings/store_settings.dart';
import 'constellation_service.dart' show ConstellationCredentials;

/// Resolve the persisted hub account id (the id the hub records the baton
/// `holder` against), or null when the user has not registered yet.
///
/// It is recorded at registration so follow-the-night can tell whether the
/// baton's `holder` is *this* user (drives the "Release" affordance on held
/// cards).
Future<String?> resolveConstellationAccountId(SettingsDao settings) async {
  final id = await settings.read(StoreSettings.constellationAccountId);
  return id.isEmpty ? null : id;
}

/// Resolve the configured hub credentials from settings, or null when the user
/// has not signed in to any hub yet.
Future<ConstellationCredentials?> resolveConstellationCredentials(
  SettingsDao settings,
) async {
  final url = await settings.read(StoreSettings.constellationHubUrl);
  final token = await settings.read(StoreSettings.constellationHubToken);
  if (url.isEmpty || token.isEmpty) {
    return null;
  }
  final parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.hasScheme) return null;
  return ConstellationCredentials(hubBaseUrl: parsed, bearerToken: token);
}

import 'dart:async';

import '../../models/equipment_profile.dart';
import '../../models/settings/app_settings.dart' as models;

/// Role interface covering persistent user/equipment data.
///
/// What this role owns:
///   * Equipment-profile CRUD + active-profile selection.
///   * App settings get / update (the user-visible preferences blob).
///   * Persisted observer location get / set.
///
/// What this role deliberately does NOT own:
///   * Live device commands — see [DeviceBackend].
///   * Sequencer runtime configuration (which uses some of the same fields
///     such as location) — see [SequencerBackend.sequencerUpdateLocation].
///     Persistent settings vs. in-flight executor state are deliberately
///     separate writers; the bridge is responsible for keeping them in sync
///     when the user edits one or the other.
///   * Internet-based location lookup — see
///     [DiagnosticsBackend.getLocationFromInternet], which is a network
///     fetch, not a persistence operation.
abstract class ProfileSettingsBackend {
  // Equipment profiles

  /// Get all profiles
  Future<List<EquipmentProfile>> getProfiles();

  /// Save profile
  Future<void> saveProfile(EquipmentProfile profile);

  /// Delete profile
  Future<void> deleteProfile(String profileId);

  /// Load profile and set as active
  Future<void> loadProfile(String profileId);

  /// Get active profile
  Future<EquipmentProfile?> getActiveProfile();

  // Settings & Location

  Future<models.AppSettings> getSettings();
  Future<void> updateSettings(models.AppSettings settings);
  Future<models.ObserverLocation?> getLocation();
  Future<void> setLocation(models.ObserverLocation? location);
}

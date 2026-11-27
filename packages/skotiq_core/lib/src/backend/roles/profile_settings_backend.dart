import 'dart:async';

import '../../models/equipment_profile.dart';
import '../../models/settings/app_settings.dart' as models;

/// Role interface covering persistent user/equipment data.
///
/// What this role owns:
///   * Equipment-profile CRUD + active-profile selection.
///   * Persisted observer location get / set.
///
/// The app settings document is not here: this process keeps its own in
/// `appSettingsProvider`, and a linked client reads and writes the host's
/// through [HostRigSettings].
///
/// What this role deliberately does NOT own:
///   * Live device commands — see [DeviceBackend].
///   * Sequencer runtime configuration (which uses some of the same fields
///     such as location) — see [SequencerBackend.sequencerApplyRunConfig].
///     Persistent settings vs. in-flight executor state are deliberately
///     separate writers; the bridge is responsible for keeping them in sync
///     when the user edits one or the other.
///   * Internet-based location lookup — see
///     [DiagnosticsBackend.getLocationFromInternet], which is a network
///     fetch, not a persistence operation.
abstract class ProfileSettingsBackend {
  Future<List<EquipmentProfile>> getProfiles();

  Future<void> saveProfile(EquipmentProfile profile);

  Future<void> deleteProfile(String profileId);

  /// Load profile and set as active
  Future<void> loadProfile(String profileId);

  Future<EquipmentProfile?> getActiveProfile();

  Future<models.ObserverLocation?> getLocation();
  Future<void> setLocation(models.ObserverLocation? location);
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/network_backend.dart';
import '../services/profile_service.dart';
import 'async_scope.dart';
import 'database_provider.dart';
import 'device_service_providers.dart';
import 'equipment_provider.dart';
import 'linked_host.dart';
import 'profiles_provider.dart';
import 'settings_provider.dart';

final profileServiceProvider = Provider<ProfileService>((ref) {
  return profileServiceFor(
    ref,
    hostProfiles: ref.watch(linkedHostProfilesProvider),
  );
});

/// A [ProfileService] that reads its collaborators through [ref]. Each
/// operation is scoped to the backend through the container, not [ref], so a
/// continuation that outlives a backend swap never touches [ref].
ProfileService profileServiceFor(Ref ref, {HostProfiles? hostProfiles}) =>
    ProfileService(
      hostProfiles: hostProfiles,
      beginAuthority: () => ref.container.backendScopes().begin(),
      profiles: () => ref.read(equipmentProfilesProvider.notifier),
      onHostProfilesChanged: () => ref.invalidate(equipmentProfilesProvider),
      profilesDao: () => ref.read(equipmentProfilesDaoProvider),
      activeProfile: () => ref.read(activeEquipmentProfileProvider),
      autoConnectOnStartup: () => ref.read(autoConnectSettingsProvider.future),
      filterWheel: () => ref.read(filterWheelStateProvider),
      deviceService: () => ref.read(deviceServiceProvider),
    );

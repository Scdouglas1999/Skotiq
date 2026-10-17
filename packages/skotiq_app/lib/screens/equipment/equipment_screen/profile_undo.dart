// Undo for a deleted equipment profile.
part of '../equipment_screen.dart';

/// Restore a profile the user just deleted, from the snackbar's Undo action.
///
/// Deliberately a free function over a [ProviderContainer] and a captured
/// [ScaffoldMessengerState], NOT a method on [_EquipmentScreenState].
///
/// The Undo offer lives in the app-level ScaffoldMessenger, so it stays on
/// screen after the operator navigates away from Equipment — and navigating
/// away DISPOSES the screen's state. As a State method every path here was
/// guarded by `mounted`, so pressing Undo from any other screen aborted
/// silently: no restore, no error, and the dialog had just promised the delete
/// "cannot be undone". The container and the messenger both outlive the route,
/// so the restore now runs wherever the operator happens to be standing.
Future<void> restoreDeletedProfile(
  EquipmentProfileModel deletedProfile, {
  required ProviderContainer container,
  required ScaffoldMessengerState messenger,
  required SkotiqColors colors,
  required SkotiqLocalizations l10n,
  required String? localExportJson,
  required int epochAtDelete,
  required BackendNotifier backendOwner,
  required SkotiqBackend backendAtDelete,
}) async {
  void report(String message, Color background) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: background,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  if (container.read(profileMutationEpochProvider) != epochAtDelete) {
    report('Undo expired — profiles changed after the delete.', colors.warning);
    return;
  }

  if (!backendOwner.isCurrentBackend(backendAtDelete)) {
    report(
      'Undo expired — the connected imaging host changed.',
      colors.warning,
    );
    return;
  }

  try {
    final int restoredId;
    if (backendAtDelete is NetworkBackend) {
      final notifier = container.read(equipmentProfilesProvider.notifier);
      restoredId = await notifier.updateProfile(
        deletedProfile.toInsertionCopy(name: deletedProfile.name),
      );
      if (!backendOwner.isCurrentBackend(backendAtDelete)) return;
      if (deletedProfile.isDefault) {
        await notifier.setDefaultProfile(restoredId, makeActive: true);
      } else if (deletedProfile.isActive) {
        await notifier.setActiveProfile(restoredId);
      }
    } else {
      if (localExportJson == null) {
        throw StateError('The local profile undo payload is missing.');
      }
      restoredId = await container
          .read(profileServiceProvider)
          .importProfileFromJson(localExportJson);
      if (!backendOwner.isCurrentBackend(backendAtDelete)) return;
      if (deletedProfile.isActive) {
        await container
            .read(equipmentProfilesProvider.notifier)
            .setActiveProfile(restoredId);
      }
    }
    container.read(profileMutationEpochProvider.notifier).state++;
    container.read(selectedEquipmentProfileIdProvider.notifier).state =
        restoredId;
    report(l10n.text('equipmentProfileRestored'), colors.success);
  } catch (e) {
    report(
      l10n.text('equipmentRestoreFailed', params: {'error': '$e'}),
      colors.error,
    );
  }
}

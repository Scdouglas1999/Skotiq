import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

import '../../localization/skotiq_localizations.dart';
import '../../utils/cooled_camera_guard.dart';
import '../../utils/exported_file_reveal.dart';
import '../../utils/snackbar_helper.dart';
import 'dialogs/profile_editor_dialog.dart';
import 'utils/connect_all_action.dart';
import 'utils/profile_mutation_epoch.dart';

typedef EquipmentProfileImportPicker = Future<XFile?> Function();
typedef EquipmentProfileExportPicker =
    Future<ExportTarget?> Function(String suggestedName);

/// Picks the file to import profiles from.
final equipmentProfileImportPickerProvider =
    Provider<EquipmentProfileImportPicker>(
      (ref) =>
          () => openFile(
            acceptedTypeGroups: const [
              XTypeGroup(label: 'JSON files', extensions: ['json']),
            ],
          ),
    );

/// Picks where an exported profile goes. On a phone there is no save dialog,
/// so the target is a sandbox path and the export ends in the share sheet.
final equipmentProfileExportPickerProvider =
    Provider<EquipmentProfileExportPicker>(
      (ref) =>
          (suggestedName) => chooseExportTarget(
            suggestedName: suggestedName,
            acceptedTypeGroups: const [
              XTypeGroup(label: 'JSON files', extensions: ['json']),
            ],
          ),
    );

/// [base] when no profile has that name, otherwise `base (1)`, `base (2)`, …
/// Names are compared the way profile validation compares them: trimmed,
/// case-insensitive.
String uniqueProfileName(String base, Iterable<String> taken) {
  final names = taken.map((name) => name.trim().toLowerCase()).toSet();
  if (!names.contains(base.trim().toLowerCase())) return base;
  var suffix = 1;
  while (names.contains('$base ($suffix)'.trim().toLowerCase())) {
    suffix++;
  }
  return '$base ($suffix)';
}

/// What the operator is told when an import does not go through:
/// [ProfileImportException] carries its own wording; anything else is kept
/// verbatim so an unexpected failure stays legible.
String describeProfileImportFailure(Object error, {String? fileName}) {
  final subject = fileName == null ? 'that file' : '"$fileName"';
  if (error is ProfileImportException) {
    return error.message.replaceFirst('That file', subject);
  }
  return failureText('Could not import $subject', error);
}

/// The profile the profile list has selected; starts on the active one.
final selectedEquipmentProfileIdProvider = StateProvider<int?>((ref) {
  final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
  return activeProfile?.id;
});

/// Everything a screen can do to an equipment profile: create, edit, use,
/// make the startup default, duplicate, delete (with undo), reorder, and
/// connect or disconnect its devices. The Equipment screen and Settings >
/// Equipment profiles both get it from here.
mixin ProfileActions<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// Profile operations sent to the host. Each one supersedes the one before
  /// it, and a host change drops them all.
  late final _profileOperations = ref.backendScopes(alive: () => mounted);

  void bumpProfileMutationEpoch() {
    ref.read(profileMutationEpochProvider.notifier).state++;
  }

  /// Call from `build`: an operation started against one imaging host must
  /// not report against the next.
  void watchProfileAuthority() {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      _profileOperations.cancelAll();
      bumpProfileMutationEpoch();
    });
  }

  Future<void> showProfileEditor(
      BuildContext context, EquipmentProfileModel? profile) async {
    final saved = await ProfileEditorDialog.show(context, profile: profile);
    if (saved == true) bumpProfileMutationEpoch();
  }

  Future<void> createEmptyProfile() async {
    final operation = _profileOperations.beginLatest();
    try {
      final profileId = await ref
          .read(equipmentProfilesProvider.notifier)
          .createProfile(
            name: uniqueProfileName(
              'My Equipment',
              ref.read(sortedProfilesProvider).map((profile) => profile.name),
            ),
          );
      if (operation.isStale) return;
      bumpProfileMutationEpoch();
      ref.read(selectedEquipmentProfileIdProvider.notifier).state = profileId;
    } catch (e) {
      if (operation.isStale) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        context.l10n
            .text('equipmentCreateProfileFailed', params: {'error': userFacingError(e)}),
      );
    }
  }

  /// Point the app at [profile] for this session without touching which
  /// profile loads at startup.
  ///
  /// `setActiveProfile` is the app's single, remote-aware activation authority:
  /// it pushes the row into the native executor before committing SQLite.
  Future<void> activateProfile(EquipmentProfileModel profile) async {
    final profileId = profile.id;
    if (profileId == null) return;
    final operation = _profileOperations.beginLatest();
    try {
      await ref
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfile(profileId);
      if (operation.isStale) return;
      if (!mounted) return;
      bumpProfileMutationEpoch();
      context.showSuccessSnackBar('Now using "${profile.name}"');
    } catch (e) {
      if (operation.isStale) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        failureText('Could not switch to "${profile.name}"', e),
      );
    }
  }

  Future<void> setDefaultProfile(EquipmentProfileModel profile) async {
    final operation = _profileOperations.beginLatest();
    try {
      // makeActive: false — the star means "Make Startup Default" and nothing
      // else. Switching which rig is in use is its own action now ("Use This
      // Profile" / [activateProfile]), so starring a profile you are not
      // imaging with must not yank the session onto it and re-push its devices
      // to the Rust executor mid-run. Settings > Equipment Profiles has always
      // treated the same action this way (screen_shell.dart setDefaultProfile);
      // this is the Equipment screen catching up rather than two surfaces
      // disagreeing about what one label does.
      await ref
          .read(equipmentProfilesProvider.notifier)
          .setDefaultProfile(profile.id, makeActive: false);
      if (operation.isStale) return;
      if (!mounted) return;
      bumpProfileMutationEpoch();
      context.showSuccessSnackBar(
        context.l10n.text('equipmentDefaultProfileSet'),
      );
    } catch (e) {
      if (operation.isStale) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        context.l10n.text('equipmentSetDefaultFailed', params: {'error': userFacingError(e)}),
      );
    }
  }

  Future<void> duplicateProfile(int profileId) async {
    final operation = _profileOperations.beginLatest();
    try {
      final profiles = ref.read(sortedProfilesProvider);
      final sourceProfile =
          profiles.where((profile) => profile.id == profileId).firstOrNull;
      if (sourceProfile == null) {
        throw StateError('Profile $profileId no longer exists');
      }
      final newName = uniqueProfileName(
        '${sourceProfile.name} (Copy)',
        profiles.map((profile) => profile.name),
      );
      final newId = await ref
          .read(equipmentProfilesProvider.notifier)
          .duplicateProfile(profileId, newName);
      if (operation.isStale) return;
      bumpProfileMutationEpoch();
      ref.read(selectedEquipmentProfileIdProvider.notifier).state = newId;
      if (!mounted) return;
      context.showSuccessSnackBar(
        context.l10n.text('equipmentProfileDuplicated'),
      );
    } catch (e) {
      if (operation.isStale) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        context.l10n.text('equipmentDuplicateFailed', params: {'error': userFacingError(e)}),
      );
    }
  }

  Future<void> deleteProfile(int profileId) async {
    final operation = _profileOperations.beginLatest();
    try {
      // Resolve the row-to-delete from the remote-aware in-memory list, not the
      // local-only DAO: on a slave (NetworkBackend) the local SQLite is empty,
      // so a direct DAO read would return null and abort the delete. The model
      // from this list already carries name/isActive for the undo snackbar.
      final deletedProfile = ref
          .read(sortedProfilesProvider)
          .where((p) => p.id == profileId)
          .firstOrNull;
      if (deletedProfile == null) {
        throw StateError('Profile $profileId no longer exists');
      }

      // Keep the undo payload in the authority that owns it. A remote profile
      // is already fully represented by [deletedProfile], while a local
      // profile retains the service's versioned JSON for an exact restore.
      final deletedProfileJson = operation.value.remoteHost != null
          ? null
          : await ref.read(profileServiceProvider).exportProfileToJson(
                profileId,
              );
      if (operation.isStale) return;
      await ref
          .read(equipmentProfilesProvider.notifier)
          .deleteProfile(profileId);
      if (operation.isStale) return;
      bumpProfileMutationEpoch();
      final epochAtDelete = ref.read(profileMutationEpochProvider);

      final selectedId = ref.read(selectedEquipmentProfileIdProvider);
      if (selectedId == profileId) {
        final profiles = ref.read(sortedProfilesProvider);
        final remainingProfiles =
            profiles.where((p) => p.id != profileId).toList();
        if (remainingProfiles.isNotEmpty) {
          ref.read(selectedEquipmentProfileIdProvider.notifier).state =
              remainingProfiles.first.id;
        } else {
          ref.read(selectedEquipmentProfileIdProvider.notifier).state = null;
        }
      }

      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        // Everything the Undo needs is captured HERE, while the screen is
        // alive: the messenger and the container both outlive this route, so
        // the offer still works after the operator navigates away.
        final container = ProviderScope.containerOf(context, listen: false);
        final deletedOn = AsyncScopes(container.read, backendProvider).begin();
        final l10n = context.l10n;
        messenger.hideCurrentSnackBar();
        messenger.showInfoSnackBar(
          context.l10n.text('equipmentProfileDeleted',
              params: {'name': deletedProfile.name}),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: context.l10n.text('commonUndo'),
            onPressed: () {
              unawaited(restoreDeletedProfile(
                deletedProfile,
                container: container,
                messenger: messenger,
                l10n: l10n,
                localExportJson: deletedProfileJson,
                epochAtDelete: epochAtDelete,
                deletedOn: deletedOn,
              ));
            },
          ),
        );
      }
    } catch (e) {
      if (operation.isStale) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        context.l10n.text('equipmentDeleteFailed', params: {'error': userFacingError(e)}),
      );
    }
  }

  Future<void> reorderProfiles(int oldIndex, int newIndex) async {
    final operation = _profileOperations.beginLatest();
    try {
      final profiles = ref.read(sortedProfilesProvider);
      if (oldIndex < 0 || oldIndex >= profiles.length) {
        throw StateError('The profile list changed before reordering.');
      }

      final reordered = [...profiles];
      final item = reordered.removeAt(oldIndex);
      if (newIndex < 0 || newIndex > reordered.length) {
        throw StateError('The profile destination is no longer available.');
      }
      // ProfileSidebar uses ReorderableListView.onReorderItem, whose
      // destination index is already adjusted for removal of the source.
      reordered.insert(newIndex, item);

      // Single notifier passthrough for both modes. On a slave this POSTs the
      // ordered id list to the host's dedicated reorder endpoint (writing the
      // slave's own empty DB would create phantom rows the host-poll erases);
      // locally it writes the DAO in one transaction. Only persisted profiles
      // carry an id, so a null filter keeps this safe.
      final orderedIds =
          reordered.map((m) => m.id).whereType<int>().toList(growable: false);
      await ref
          .read(equipmentProfilesProvider.notifier)
          .reorderProfiles(orderedIds);
      if (operation.isCurrent) {
        bumpProfileMutationEpoch();
      }
    } catch (e) {
      if (operation.isStale) return;
      if (!mounted) return;
      context.showErrorSnackBar(failureText('Failed to reorder', e));
    }
  }

  bool _importingProfiles = false;
  bool _exportingProfile = false;

  /// Read every profile in a file the user picks, then select the first one
  /// that came in.
  Future<void> importProfiles() async {
    if (_importingProfiles) return;
    _importingProfiles = true;
    final operation = _profileOperations.beginLatest();
    String? fileName;
    try {
      final file = await ref.read(equipmentProfileImportPickerProvider)();
      if (file == null || operation.isStale) {
        return;
      }
      fileName = file.name.isNotEmpty ? file.name : file.path;
      final json = await file.readAsString();
      if (operation.isStale) return;
      final ids = await ref
          .read(equipmentProfilesProvider.notifier)
          .importProfiles(json);
      if (operation.isStale) return;
      bumpProfileMutationEpoch();
      if (ids.isNotEmpty) {
        ref.read(selectedEquipmentProfileIdProvider.notifier).state =
            ids.first;
      }
      if (!mounted) return;
      context.showSuccessSnackBar(
        'Imported ${ids.length} profile${ids.length == 1 ? '' : 's'}',
      );
    } catch (e) {
      if (operation.isStale) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        describeProfileImportFailure(e, fileName: fileName),
      );
    } finally {
      _importingProfiles = false;
    }
  }

  /// Save [profile] to a file the user picks.
  Future<void> exportProfile(EquipmentProfileModel profile) async {
    final profileId = profile.id;
    if (_exportingProfile || profileId == null) return;
    _exportingProfile = true;
    final export = _profileOperations.begin();
    try {
      final fileName =
          '${profile.name.replaceAll(RegExp(r'[^\w\s-]'), '_')}_profile.json';
      final target = await ref.read(equipmentProfileExportPickerProvider)(
        fileName,
      );
      if (target == null || !mounted || export.isStale) return;
      final json = await ref
          .read(equipmentProfilesProvider.notifier)
          .exportProfile(profileId);
      if (!mounted || export.isStale) return;
      await XFile.fromData(
        utf8.encode(json),
        mimeType: 'application/json',
        name: fileName,
      ).saveTo(target.path);
      if (!mounted || export.isStale) return;
      await revealExportedFile(
        context,
        target.path,
        subject: 'Skotiq equipment profile',
        desktopMessage: 'Profile exported to ${target.path}',
      );
    } catch (e) {
      if (!mounted || export.isStale) return;
      context.showErrorSnackBar(failureText('Export failed', e));
    } finally {
      _exportingProfile = false;
    }
  }

  /// Delegates to the shared sweep so the command palette's "Connect all"
  /// and this button cannot drift apart about which slots the sweep covers.
  Future<void> connectAllDevices(EquipmentProfileModel profile) =>
      runConnectAllForProfile(context, ref, profile);

  Future<void> disconnectAllDevices() async {
    // Disconnect All includes the camera: gate on an active cooler so the TEC
    // is never cut abruptly without an explicit confirm (same guard as the
    // per-device card).
    final proceed = await confirmDisconnectCooledCamera(context, ref);
    if (!proceed || !mounted) return;

    final summary = await ref.read(deviceServiceProvider).disconnectAll();

    if (!mounted) return;

    for (final failure in summary.failures) {
      context.showErrorSnackBar(
        context.l10n
            .text('equipmentDisconnectFailed', params: {'device': failure}),
      );
    }

    if (summary.disconnected > 0 && summary.failures.isEmpty) {
      context.showSuccessSnackBar(
        context.l10n.text('equipmentAllDevicesDisconnected'),
      );
    }
  }
}

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
  required SkotiqLocalizations l10n,
  required String? localExportJson,
  required int epochAtDelete,
  required AsyncScope<SkotiqBackend> deletedOn,
}) async {
  if (container.read(profileMutationEpochProvider) != epochAtDelete) {
    messenger
      ..hideCurrentSnackBar()
      ..showWarningSnackBar(
          'Undo expired — profiles changed after the delete.');
    return;
  }

  if (deletedOn.isStale) {
    messenger
      ..hideCurrentSnackBar()
      ..showWarningSnackBar(
          'Undo expired — the connected imaging host changed.');
    return;
  }

  try {
    final int restoredId;
    if (deletedOn.value.remoteHost != null) {
      final notifier = container.read(equipmentProfilesProvider.notifier);
      restoredId = await notifier.updateProfile(
        deletedProfile.toInsertionCopy(name: deletedProfile.name),
      );
      if (deletedOn.isStale) return;
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
      if (deletedOn.isStale) return;
      if (deletedProfile.isActive) {
        await container
            .read(equipmentProfilesProvider.notifier)
            .setActiveProfile(restoredId);
      }
    }
    container.read(profileMutationEpochProvider.notifier).state++;
    container.read(selectedEquipmentProfileIdProvider.notifier).state =
        restoredId;
    messenger
      ..hideCurrentSnackBar()
      ..showSuccessSnackBar(l10n.text('equipmentProfileRestored'));
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showErrorSnackBar(l10n.text('equipmentRestoreFailed',
          params: {'error': userFacingError(e)}));
  }
}

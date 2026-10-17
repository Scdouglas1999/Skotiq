import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'widgets/profile_sidebar.dart';
import 'widgets/connected_device_card.dart';
import 'widgets/device_tile_width.dart';
import 'widgets/discovery_panel.dart';
import 'widgets/equipment_health_panel.dart';
import 'widgets/equipment_readiness_panel.dart';
import 'widgets/switch_control_card.dart';
import 'dialogs/profile_editor_dialog.dart';
import 'tabs/settings_tab.dart';
import 'utils/connect_all_action.dart';
import 'utils/equipment_disconnect.dart';
import 'utils/profile_mutation_epoch.dart';
import 'utils/session_device_save.dart';
import '../../localization/skotiq_localizations.dart';
import '../../utils/cooled_camera_guard.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/tutorial_keys/equipment_keys.dart';
import '../sequencer/widgets/run_dashboard/recovery_banner.dart';

part 'equipment_screen/layout_rail.dart';
part 'equipment_screen/profile_undo.dart';
part 'equipment_screen/progress_dashboard.dart';
part 'equipment_screen/sidebar_onboarding.dart';

// Providers for equipment screen state

/// Provider for currently selected profile in the equipment screen
final selectedEquipmentProfileIdProvider = StateProvider<int?>((ref) {
  // Default to the active profile
  final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
  return activeProfile?.id;
});

/// Which page-header tab the Equipment screen is showing: 0 Devices,
/// 1 Profiles, 2 Optical train.
final equipmentTabIndexProvider = StateProvider<int>((ref) => 0);

/// Whether the profile sidebar is collapsed (icon-only mode)
final equipmentSidebarCollapsedProvider = StateProvider<bool>((ref) => false);

/// Whether the right-hand side panel (profile, readiness, system health) is
/// collapsed. Desktop-only; below [ShellChromeMetrics.shellLayoutBreakpoint]
/// its content scrolls under the device grid instead.
final equipmentStatusRailCollapsedProvider =
    StateProvider<bool>((ref) => false);

/// Signature of the device-mismatch set the user last dismissed (✕). The
/// banner re-appears only when the *set* of mismatched devices changes (so a
/// genuinely new mismatch is never silently hidden). Session-scoped: cleared on
/// app restart, matching the "dismiss for this session" contract.
final dismissedMismatchSignatureProvider =
    StateProvider<String?>((ref) => null);

/// Body gutters, from the mockup: 20 px top/bottom, 24 px sides.
const EdgeInsets _bodyPadding = EdgeInsets.symmetric(
  horizontal: SkotiqTokens.space2xl,
  vertical: SkotiqTokens.spaceXl,
);

// Equipment screen

class EquipmentScreen extends ConsumerStatefulWidget {
  const EquipmentScreen({super.key});

  @override
  ConsumerState<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends ConsumerState<EquipmentScreen> {
  int _profileOperationGeneration = 0;

  void _bumpProfileMutationEpoch() {
    ref.read(profileMutationEpochProvider.notifier).state++;
  }

  bool _isCurrentProfileOperation(
    int generation,
    SkotiqBackend authority,
  ) {
    return mounted &&
        generation == _profileOperationGeneration &&
        identical(ref.read(backendProvider), authority);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      _profileOperationGeneration++;
      _bumpProfileMutationEpoch();
    });
    final colors = SkotiqColors.of(context);
    final profilesAsync = ref.watch(equipmentProfilesProvider);
    if (profilesAsync.hasError) {
      return _EquipmentProfilesUnavailable(
        error: profilesAsync.error!,
        onRetry: () => _retryProfiles(ref),
      );
    }
    final profilesState = profilesAsync.valueOrNull;
    if (profilesState == null) {
      return const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
    }
    if (profilesState.error != null) {
      return _EquipmentProfilesUnavailable(
        error: profilesState.error!,
        onRetry: () => _retryProfiles(ref),
      );
    }
    final profiles = List<EquipmentProfileModel>.from(profilesState.profiles)
      ..sort((a, b) {
        final orderCompare = a.sortOrder.compareTo(b.sortOrder);
        if (orderCompare != 0) return orderCompare;
        return a.name.compareTo(b.name);
      });
    final selectedProfileId = ref.watch(selectedEquipmentProfileIdProvider);
    final isRemoteMode = ref.watch(isRemoteModeProvider);

    // Check for first-time user (no profiles).
    //
    // REMOTE (slave) mode: never show the local first-run onboarding. A slave
    // controls the master's hardware and its profiles hydrate from the host's
    // SQLite over /api/profiles; before they arrive (or if the host genuinely
    // has none yet) the slave still renders the dashboard + discovery so the
    // operator can see connected devices and act — not a "create your first
    // profile" wizard that would write the slave's own empty DB. Local/host and
    // mobile first-run onboarding is unchanged (isRemoteMode false there).
    final firstRun = profiles.isEmpty && !isRemoteMode;

    // Get selected profile
    final selectedProfile = selectedProfileId != null
        ? profiles.where((p) => p.id == selectedProfileId).firstOrNull
        : null;

    // NOT clamped to 0 during first run: Profiles and Optical train are
    // reachable before a profile exists, which is when someone most wants to
    // look at them.
    final tabIndex = ref.watch(equipmentTabIndexProvider);
    // Drives whether "Disconnect all" exists at all (see the header actions).
    final anythingConnected = equipmentConnectedCount(ref) > 0;
    // Below DESKTOP width, not the shell breakpoint: this header seats a
    // title, three tabs, a chip and two actions, and measured at 800 px the
    // labelled buttons overflow the row by 7.7 px — which shows up as a
    // truncated screen name, or a yellow overflow stripe in a test. The verbs
    // move into tooltips there.
    final headerWidth = MediaQuery.sizeOf(context).width;
    final narrowHeader = headerWidth < SkotiqTokens.breakpointDesktop;
    final phoneHeader = headerWidth < BreakpointTokens.breakpointPhone;

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Equipment',
            icon: LucideIcons.plug,
            tabs: AdaptiveTabBar(
              horizontalPadding: 0,
              selectedIndex: tabIndex,
              onSelected: (index) =>
                  ref.read(equipmentTabIndexProvider.notifier).state = index,
              tabs: [
                const AdaptiveTab(label: 'Devices'),
                AdaptiveTab(
                  label: 'Profiles',
                  count: profiles.isEmpty ? null : '${profiles.length}',
                ),
                const AdaptiveTab(label: 'Optical train'),
              ],
            ),
            actions: [
              // The chip goes below phone width: "4 connected · 1 unsaved" is
              // 150 px the 360 dp header does not have, and the instrument bar
              // plus the side panel's profile block both already say it.
              if (!phoneHeader) const _ConnectionStatusSummary(),
              // Below the shell breakpoint the two labels cost ~200 px the
              // 700 px header does not have, and the TITLE was the thing that
              // gave way ("Equi…"). The verbs move into the tooltips instead:
              // a truncated screen name is a worse trade than an icon.
              // On a PHONE the header carries the title and the tabs and
              // nothing else. A 32 px icon button is under Android's 48 dp tap
              // target, and there is nowhere in a 360 dp row to put two
              // 48 px ones beside a title and a chip — so both actions move to
              // where they already exist: "Scan for devices" is the drawer's
              // own "Scan all" (the same code path), and "Disconnect all" is in
              // the profile menu.
              if (!phoneHeader) ...[
                // Only when there IS something to disconnect. On a fresh
                // profile this offered to disconnect nothing, which reads as a
                // broken control rather than an empty rig.
                if (anythingConnected)
                  if (narrowHeader)
                    SkotiqIconButton(
                      icon: LucideIcons.unplug,
                      tooltip: 'Disconnect all',
                      onPressed: _disconnectAllDevices,
                    )
                  else
                    SkotiqButton(
                      label: 'Disconnect all',
                      icon: LucideIcons.unplug,
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      onPressed: _disconnectAllDevices,
                    ),
                if (narrowHeader)
                  SkotiqIconButton(
                    icon: LucideIcons.search,
                    tooltip: 'Scan for devices',
                    selected: true,
                    onPressed: () =>
                        ref.read(discoveryScanRequestProvider.notifier).state++,
                  )
                else
                  SkotiqButton(
                    label: 'Scan for devices',
                    icon: LucideIcons.search,
                    size: ButtonSize.small,
                    onPressed: () =>
                        ref.read(discoveryScanRequestProvider.notifier).state++,
                  ),
              ],
            ],
          ),
          Expanded(
            child: switch (tabIndex) {
              1 => _ProfilesTab(
                  selectedProfileId: selectedProfileId,
                  onProfileSelected: (id) => ref
                      .read(selectedEquipmentProfileIdProvider.notifier)
                      .state = id,
                  onCreateProfile: () => _showProfileEditor(context, null),
                  onEditProfile: (profile) =>
                      _showProfileEditor(context, profile),
                  onConnectAll: _connectAllDevices,
                  onDisconnectAll: _disconnectAllDevices,
                  onSetDefault: _setDefaultProfile,
                  onActivateProfile: _activateProfile,
                  onDuplicateProfile: _duplicateProfile,
                  onDeleteProfile: _deleteProfile,
                  onReorderProfiles: _reorderProfiles,
                ),
              2 => const _OpticalTrainTab(),
              // First run owns the Devices tab only. The discovery drawer
              // is mounted BENEATH the empty state so the header's "Scan
              // for devices" has something to expand: before this it
              // bumped a provider no mounted widget was listening to, and
              // the primary action of the first screen did nothing at all.
              _ => firstRun
                  ? Column(
                      children: [
                        Expanded(
                          child: _FirstTimeOnboarding(
                            colors: colors,
                            onStartSetup: () => ref
                                .read(discoveryScanRequestProvider.notifier)
                                .state++,
                            onManualSetup: _createEmptyProfile,
                          ),
                        ),
                        const DiscoveryPanel(),
                      ],
                    )
                  : _EquipmentMainColumn(
                      selectedProfile: selectedProfile,
                      onSettings: () => _showSettings(context),
                      onConnectAll: _connectAllDevices,
                      onEditProfile: (profile) =>
                          _showProfileEditor(context, profile),
                      onDisconnectAll: _disconnectAllDevices,
                    ),
            },
          ),
        ],
      ),
    );
  }

  void _retryProfiles(WidgetRef ref) {
    ref.invalidate(allProfilesProvider);
    ref.invalidate(activeProfileProvider);
    ref.invalidate(equipmentProfilesProvider);
  }

  // Profile operations

  Future<void> _showProfileEditor(
      BuildContext context, EquipmentProfileModel? profile) async {
    final saved = await ProfileEditorDialog.show(context, profile: profile);
    if (saved == true) _bumpProfileMutationEpoch();
  }

  Future<void> _createEmptyProfile() async {
    final authority = ref.read(backendProvider);
    final generation = ++_profileOperationGeneration;
    try {
      final profileId = await ref
          .read(equipmentProfilesProvider.notifier)
          .createProfile(name: 'My Equipment');
      if (!_isCurrentProfileOperation(generation, authority)) return;
      _bumpProfileMutationEpoch();
      ref.read(selectedEquipmentProfileIdProvider.notifier).state = profileId;
    } catch (e) {
      if (!_isCurrentProfileOperation(generation, authority)) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        context.l10n
            .text('equipmentCreateProfileFailed', params: {'error': '$e'}),
      );
    }
  }

  /// Point the app at [profile] for this session without touching which
  /// profile loads at startup.
  ///
  /// `setActiveProfile` is the app's single, remote-aware activation authority:
  /// it pushes the row into the native executor before committing SQLite.
  Future<void> _activateProfile(EquipmentProfileModel profile) async {
    final profileId = profile.id;
    if (profileId == null) return;
    final authority = ref.read(backendProvider);
    final generation = ++_profileOperationGeneration;
    try {
      await ref
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfile(profileId);
      if (!_isCurrentProfileOperation(generation, authority)) return;
      if (!mounted) return;
      _bumpProfileMutationEpoch();
      context.showSuccessSnackBar('Now using "${profile.name}"');
    } catch (e) {
      if (!_isCurrentProfileOperation(generation, authority)) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        'Could not switch to "${profile.name}": $e',
      );
    }
  }

  Future<void> _setDefaultProfile(EquipmentProfileModel profile) async {
    final authority = ref.read(backendProvider);
    final generation = ++_profileOperationGeneration;
    try {
      // makeActive: false — the star means "Make Startup Default" and nothing
      // else. Switching which rig is in use is its own action now ("Use This
      // Profile" / [_activateProfile]), so starring a profile you are not
      // imaging with must not yank the session onto it and re-push its devices
      // to the Rust executor mid-run. Settings > Equipment Profiles has always
      // treated the same action this way (screen_shell.dart _setDefaultProfile);
      // this is the Equipment screen catching up rather than two surfaces
      // disagreeing about what one label does.
      await ref
          .read(equipmentProfilesProvider.notifier)
          .setDefaultProfile(profile.id, makeActive: false);
      if (!_isCurrentProfileOperation(generation, authority)) return;
      if (!mounted) return;
      _bumpProfileMutationEpoch();
      context.showSuccessSnackBar(
        context.l10n.text('equipmentDefaultProfileSet'),
      );
    } catch (e) {
      if (!_isCurrentProfileOperation(generation, authority)) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        context.l10n.text('equipmentSetDefaultFailed', params: {'error': '$e'}),
      );
    }
  }

  Future<void> _duplicateProfile(int profileId) async {
    final authority = ref.read(backendProvider);
    final generation = ++_profileOperationGeneration;
    try {
      // Get the source profile to derive a name for the copy
      final profiles = ref.read(sortedProfilesProvider);
      final sourceProfile =
          profiles.where((profile) => profile.id == profileId).firstOrNull;
      if (sourceProfile == null) {
        throw StateError('Profile $profileId no longer exists');
      }
      final newName = '${sourceProfile.name} (Copy)';
      final newId = await ref
          .read(equipmentProfilesProvider.notifier)
          .duplicateProfile(profileId, newName);
      if (!_isCurrentProfileOperation(generation, authority)) return;
      _bumpProfileMutationEpoch();
      // Select the newly duplicated profile
      ref.read(selectedEquipmentProfileIdProvider.notifier).state = newId;
      if (!mounted) return;
      context.showSuccessSnackBar(
        context.l10n.text('equipmentProfileDuplicated'),
      );
    } catch (e) {
      if (!_isCurrentProfileOperation(generation, authority)) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        context.l10n.text('equipmentDuplicateFailed', params: {'error': '$e'}),
      );
    }
  }

  Future<void> _deleteProfile(int profileId) async {
    final backendOwner = ref.read(backendProvider.notifier);
    final backendAtDelete = backendOwner.currentBackend;
    final generation = ++_profileOperationGeneration;
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
      final deletedProfileJson = backendAtDelete is NetworkBackend
          ? null
          : await ref.read(profileServiceProvider).exportProfileToJson(
                profileId,
              );
      if (!_isCurrentProfileOperation(generation, backendAtDelete)) return;
      await ref
          .read(equipmentProfilesProvider.notifier)
          .deleteProfile(profileId);
      if (!_isCurrentProfileOperation(generation, backendAtDelete)) return;
      _bumpProfileMutationEpoch();
      final epochAtDelete = ref.read(profileMutationEpochProvider);

      // If we deleted the selected profile, select another one
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
        final colors = SkotiqColors.of(context);
        final l10n = context.l10n;
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(context.l10n.text('equipmentProfileDeleted',
                params: {'name': deletedProfile.name})),
            duration: const Duration(seconds: 6),
            // `persist` defaults to `action != null` in Flutter 3.44
            // (SnackBar's constructor), and ScaffoldMessenger's timer returns
            // without hiding when it is set — so `duration` was inert and this
            // bar sat over the status bar (profile, device states, focuser
            // position, temperature, clock, LST) until the app was restarted.
            // An undo offer is not a modal: honour the 6 s window and give the
            // operator an explicit ✕ as well.
            persist: false,
            showCloseIcon: true,
            action: SnackBarAction(
              label: context.l10n.text('commonUndo'),
              onPressed: () {
                unawaited(restoreDeletedProfile(
                  deletedProfile,
                  container: container,
                  messenger: messenger,
                  colors: colors,
                  l10n: l10n,
                  localExportJson: deletedProfileJson,
                  epochAtDelete: epochAtDelete,
                  backendOwner: backendOwner,
                  backendAtDelete: backendAtDelete,
                ));
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (!_isCurrentProfileOperation(generation, backendAtDelete)) return;
      if (!mounted) return;
      context.showErrorSnackBar(
        context.l10n.text('equipmentDeleteFailed', params: {'error': '$e'}),
      );
    }
  }

  Future<void> _reorderProfiles(int oldIndex, int newIndex) async {
    final authority = ref.read(backendProvider);
    final generation = ++_profileOperationGeneration;
    try {
      final profiles = ref.read(sortedProfilesProvider);
      if (oldIndex < 0 || oldIndex >= profiles.length) {
        throw StateError('The profile list changed before reordering.');
      }

      // Build reordered list
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
      if (_isCurrentProfileOperation(generation, authority)) {
        _bumpProfileMutationEpoch();
      }
    } catch (e) {
      if (!_isCurrentProfileOperation(generation, authority)) return;
      if (!mounted) return;
      context.showErrorSnackBar('Failed to reorder: $e');
    }
  }

  // Device connection operations

  /// Delegates to the shared sweep so the command palette's "Connect all"
  /// and this button cannot drift apart about which slots the sweep covers.
  Future<void> _connectAllDevices(EquipmentProfileModel profile) =>
      runConnectAllForProfile(context, ref, profile);

  Future<void> _disconnectAllDevices() async {
    // Disconnect All includes the camera: gate on an active cooler so the TEC
    // is never cut abruptly without an explicit confirm (same guard as the
    // per-device card).
    final proceed = await confirmDisconnectCooledCamera(context, ref);
    if (!proceed || !mounted) return;

    final summary = await runEquipmentDisconnectAll(ref);

    if (!mounted) return;

    for (final failure in summary.failures) {
      context.showErrorSnackBar(
        context.l10n
            .text('equipmentDisconnectFailed', params: {'device': failure}),
      );
    }

    if (summary.successCount > 0 && summary.failures.isEmpty) {
      context.showSuccessSnackBar(
        context.l10n.text('equipmentAllDevicesDisconnected'),
      );
    }
  }

  // Settings

  void _showSettings(BuildContext context) {
    // On a phone this becomes a full-screen route (settings is content-heavy);
    // on tablet/desktop it stays the familiar 700×500 dialog. The body manages
    // its own per-section scrolling, so the scaffold must not double-wrap it.
    if (Responsive.isPhone(context)) {
      showAdaptiveModal<void>(
        context: context,
        designWidth: 700,
        designHeight: 500,
        phoneMode: PhoneModalMode.fullScreen,
        builder: (modalContext) {
          final colors = SkotiqColors.of(modalContext);
          return Scaffold(
            backgroundColor: colors.background,
            appBar: AppBar(
              backgroundColor: colors.surface,
              title: Text(modalContext.l10n.text('equipmentSettingsTitle')),
              leading: SkotiqIconButton(
                icon: LucideIcons.x,
                tooltip: modalContext.l10n.text('commonClose'),
                onPressed: () => Navigator.of(modalContext).pop(),
              ),
            ),
            body: const SafeArea(child: EquipmentSettingsTab()),
          );
        },
      );
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) => SkotiqDialog(
        title: dialogContext.l10n.text('equipmentSettingsTitle'),
        icon: LucideIcons.settings,
        width: 700,
        height: 500,
        // EquipmentSettingsTab manages its own scrolling per-section, so the
        // dialog scaffold must not double-wrap it in a SingleChildScrollView.
        scrollableBody: false,
        bodyPadding: EdgeInsets.zero,
        child: const EquipmentSettingsTab(),
      ),
    );
  }
}

/// The Profiles tab: the profile list that used to be a permanent left column,
/// now a page of its own so the Devices tab keeps the full width for cards.
///
/// The list keeps its 360 px column and the rest of the row is the selected
/// profile's editor ([ProfileEditorMode.profilePage]). Before that the tab WAS
/// the 360 px column and nothing else — `Align(topLeft)` around a `SizedBox`,
/// which left ~1340 of 1920 px of bare background beside it and gave a click
/// on a profile row nothing to populate.
class _ProfilesTab extends ConsumerWidget {
  final int? selectedProfileId;
  final ValueChanged<int?> onProfileSelected;
  final VoidCallback onCreateProfile;
  final void Function(EquipmentProfileModel) onEditProfile;
  final void Function(EquipmentProfileModel) onConnectAll;
  final VoidCallback onDisconnectAll;
  final void Function(EquipmentProfileModel) onSetDefault;
  final void Function(EquipmentProfileModel) onActivateProfile;
  final void Function(int) onDuplicateProfile;
  final void Function(int) onDeleteProfile;
  final void Function(int, int) onReorderProfiles;

  const _ProfilesTab({
    required this.selectedProfileId,
    required this.onProfileSelected,
    required this.onCreateProfile,
    required this.onEditProfile,
    required this.onConnectAll,
    required this.onDisconnectAll,
    required this.onSetDefault,
    required this.onActivateProfile,
    required this.onDuplicateProfile,
    required this.onDeleteProfile,
    required this.onReorderProfiles,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ProfileSidebar(
      // Spotlight target for the Equipment Setup tour's first step.
      key: EquipmentTutorialKeys.profileSelector,
      selectedProfileId: selectedProfileId,
      onProfileSelected: onProfileSelected,
      onCreateProfile: onCreateProfile,
      onEditProfile: onEditProfile,
      onConnectAll: onConnectAll,
      onDisconnectAll: onDisconnectAll,
      onSetDefault: onSetDefault,
      onActivateProfile: onActivateProfile,
      onDuplicateProfile: onDuplicateProfile,
      onDeleteProfile: onDeleteProfile,
      onReorderProfiles: onReorderProfiles,
    );

    final profiles = ref.watch(sortedProfilesProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        // One column when there is nothing to inspect, or no room to inspect
        // it in:
        //
        // * No profiles — the list's own empty state already invites creating
        //   one and says what a profile saves, so splitting the tab would put
        //   that invitation on screen twice, side by side. It gets the width
        //   instead.
        // * Below [_profilesTwoPaneMinWidth] the editor's 120 px labels plus
        //   their controls do not fit in what is left beside the list, so the
        //   tab stays the single column it has always been and editing goes
        //   through the list footer's "Edit profile" dialog.
        if (profiles.isEmpty ||
            constraints.maxWidth < _profilesTwoPaneMinWidth) {
          return list;
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: _profilesColumnWidth, child: list),
            Expanded(
              child: _ProfileInspector(
                profile: profiles
                    .where((p) => p.id == selectedProfileId)
                    .firstOrNull,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Width the profile list keeps as a tab body. Wider than the old 240 px
/// sidebar because it no longer has to share the row with the device grid.
const double _profilesColumnWidth = 360.0;

/// Narrowest tab body that seats the list and the editor side by side.
///
/// [_profilesColumnWidth] plus the editor's minimum useful measure: its
/// [profileEditorLabelWidth] label column, a control wide enough for a device
/// name, and the page's own 24 px gutters.
const double _profilesTwoPaneMinWidth = _profilesColumnWidth + 520.0;

/// The Profiles tab's right-hand pane: the selected profile's editor, or the
/// reason there isn't one.
///
/// The editor is keyed on the profile id so switching rows rebuilds its
/// controllers from the new profile instead of leaving the previous row's text
/// in the fields, and the swap cross-fades rather than cutting.
class _ProfileInspector extends StatelessWidget {
  const _ProfileInspector({required this.profile});

  final EquipmentProfileModel? profile;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final selected = profile;

    return DecoratedBox(
      decoration: BoxDecoration(color: colors.background),
      child: AnimatedSwitcher(
        duration: animationDuration(context, SkotiqTokens.durationQuick),
        switchInCurve: SkotiqTokens.curveStandard,
        switchOutCurve: SkotiqTokens.curveStandard,
        // Top-left rather than the default centred stack: the two forms are
        // different heights, and centring them slides the incoming one's
        // heading up the pane as it fades in.
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, if (current != null) current],
        ),
        child: selected == null
            ? const _NoProfileSelected(key: ValueKey('profiles.none'))
            : ProfileEditorDialog(
                key: ValueKey<int?>(selected.id),
                profile: selected,
                mode: ProfileEditorMode.profilePage,
              ),
      ),
    );
  }
}

/// The pane with no profile to show.
///
/// Only reachable while there ARE profiles but none is selected — the moment
/// between deleting the selected row and the list settling on another. With no
/// profiles at all the tab is one column and the list's own empty state does
/// the inviting, so this never has to repeat it.
class _NoProfileSelected extends StatelessWidget {
  const _NoProfileSelected({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: EmptyState(
        icon: LucideIcons.aperture,
        title: 'Pick a profile',
        body: 'Choose a profile on the left to see and edit its optics, '
            'devices, filters and capture defaults.',
      ),
    );
  }
}

/// The Optical train tab: the profile editor's optical-train section, hosted
/// as a page instead of a dialog section.
class _OpticalTrainTab extends ConsumerWidget {
  const _OpticalTrainTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    if (profile == null) {
      return Center(
        child: EmptyState(
          icon: LucideIcons.aperture,
          title: 'No profile is active',
          body: 'Activate a profile in the Profiles tab to edit its telescope, '
              'focal length and aperture.',
          action: SkotiqButton(
            label: 'Open profiles',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () =>
                ref.read(equipmentTabIndexProvider.notifier).state = 1,
          ),
        ),
      );
    }
    return ProfileEditorDialog(
      key: ValueKey<int?>(profile.id),
      profile: profile,
      mode: ProfileEditorMode.opticalTrainPage,
    );
  }
}

class _EquipmentProfilesUnavailable extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _EquipmentProfilesUnavailable({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EmptyState.compact(
        icon: LucideIcons.alertTriangle,
        title: 'Could not load equipment profiles',
        body: 'Skotiq could not read the equipment configuration. '
            'No profiles or setup actions are shown until it can be loaded.\n\n'
            '$error',
        action: SkotiqButton(
          label: 'Retry',
          icon: LucideIcons.refreshCw,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: onRetry,
        ),
      ),
    );
  }
}

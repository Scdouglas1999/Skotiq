import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/tutorial_keys/equipment_keys.dart';
import '../dialogs/profile_editor_dialog.dart';
import '../profile_actions.dart';
import 'profile_sidebar.dart';

/// Every equipment profile and the editor for the selected one: the body of
/// Equipment > Profiles and of Settings > Equipment profiles.
///
/// The list keeps a 360 px column and the rest of the row is the selected
/// profile's editor ([ProfileEditorMode.profilePage]). Too narrow for both,
/// it is the list alone and editing opens the same editor as a dialog.
class ProfilesManager extends ConsumerStatefulWidget {
  const ProfilesManager({super.key, this.tutorialTargets = false});

  /// True on the Equipment screen, whose tour points at this list.
  final bool tutorialTargets;

  @override
  ConsumerState<ProfilesManager> createState() => _ProfilesManagerState();
}

class _ProfilesManagerState extends ConsumerState<ProfilesManager>
    with ProfileActions<ProfilesManager> {
  @override
  Widget build(BuildContext context) {
    watchProfileAuthority();
    final selectedProfileId = ref.watch(selectedEquipmentProfileIdProvider);
    final list = ProfileSidebar(
      key: widget.tutorialTargets
          ? EquipmentTutorialKeys.profileSelector
          : null,
      tutorialTargets: widget.tutorialTargets,
      selectedProfileId: selectedProfileId,
      onProfileSelected: (id) =>
          ref.read(selectedEquipmentProfileIdProvider.notifier).state = id,
      onCreateProfile: () => showProfileEditor(context, null),
      onEditProfile: (profile) => showProfileEditor(context, profile),
      onConnectAll: connectAllDevices,
      onDisconnectAll: disconnectAllDevices,
      onSetDefault: setDefaultProfile,
      onActivateProfile: activateProfile,
      onDuplicateProfile: duplicateProfile,
      onDeleteProfile: deleteProfile,
      onReorderProfiles: reorderProfiles,
      onImportProfiles: importProfiles,
      onExportProfile: exportProfile,
    );

    final profiles = ref.watch(sortedProfilesProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        // One column when there is nothing to inspect (the list's own empty
        // state does the inviting) or no room for the editor's label column
        // and controls beside the list.
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

/// Width the profile list keeps beside the editor.
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


// Devices-tab layout: the device column, the discovery drawer and the
// right-hand side panel (profile, readiness, system health).
part of '../equipment_screen.dart';

/// Height the device grid keeps before the discovery drawer is allowed to sit
/// under it as a sibling rather than scrolling with the cards.
const double _minPinnedDashboardHeight = 200.0;

/// Working estimate of the COLLAPSED discovery drawer's height (its 44 px head
/// row plus the hairline and padding). Used only to decide whether the drawer
/// fits as a sibling.
const double _discoveryPeekHeight = 60.0;

/// The drawer never takes more than 44% of the device column, per 06 §Equipment.
const double _discoveryMaxFraction = 0.44;

class _EquipmentMainColumn extends ConsumerWidget {
  final EquipmentProfileModel? selectedProfile;
  final VoidCallback onSettings;
  final void Function(EquipmentProfileModel) onConnectAll;
  final void Function(EquipmentProfileModel) onEditProfile;
  final VoidCallback onDisconnectAll;

  const _EquipmentMainColumn({
    required this.selectedProfile,
    required this.onSettings,
    required this.onConnectAll,
    required this.onEditProfile,
    required this.onDisconnectAll,
  });

  /// The device grid with the discovery drawer beneath it, in ONE column.
  ///
  /// The drawer is a plain (non-flex) child so the grid's [Expanded] absorbs
  /// every remaining pixel: the drawer PUSHES the grid up and can never overlay
  /// it. On a viewport too short to seat both, the drawer scrolls with the
  /// cards instead — always reachable, never overflowing.
  Widget _cardsAndDiscovery({Widget? header, Widget? status}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canPin = !constraints.hasBoundedHeight ||
            constraints.maxHeight >=
                _minPinnedDashboardHeight + _discoveryPeekHeight;

        if (!canPin) {
          return _DeviceDashboard(
            profile: selectedProfile,
            onConnectAll: onConnectAll,
            onEditProfile: onEditProfile,
            header: header,
            status: status,
            footer: const DiscoveryPanel(),
          );
        }

        final drawerCap = constraints.hasBoundedHeight
            ? constraints.maxHeight * _discoveryMaxFraction
            : double.infinity;
        return Column(
          children: [
            Expanded(
              child: _DeviceDashboard(
                profile: selectedProfile,
                onConnectAll: onConnectAll,
                onEditProfile: onEditProfile,
                header: header,
                status: status,
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: drawerCap),
              child: const DiscoveryPanel(),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= ShellChromeMetrics.shellLayoutBreakpoint;

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _cardsAndDiscovery()),
              _EquipmentSidePanel(
                selectedProfile: selectedProfile,
                onSettings: onSettings,
                onEditProfile: onEditProfile,
                onConnectAll: onConnectAll,
                onDisconnectAll: onDisconnectAll,
              ),
            ],
          );
        }

        // Narrow: no second column. The side panel's content rides INSIDE the
        // device column's scroll view so the cards keep the full width: the
        // profile (whose menu carries the header's actions, which a phone
        // header has no room for) above the devices, readiness and health
        // below them, so the devices are the first thing on the screen.
        return _cardsAndDiscovery(
          header: Padding(
            padding: _bodyPadding.copyWith(bottom: 0),
            child: _ProfileSection(
              selectedProfile: selectedProfile,
              onSettings: onSettings,
              onEditProfile: onEditProfile,
              onConnectAll: onConnectAll,
              onDisconnectAll: onDisconnectAll,
            ),
          ),
          status: Padding(
            padding: _bodyPadding.copyWith(top: 0),
            child: const _StatusSections(),
          ),
        );
      },
    );
  }
}

/// The 320 px right column: the profile block, the readiness blockers and
/// system health. No icon strip — 05 §15: a side panel with a single content
/// stream has no strip.
class _EquipmentSidePanel extends ConsumerWidget {
  final EquipmentProfileModel? selectedProfile;
  final VoidCallback onSettings;
  final void Function(EquipmentProfileModel) onEditProfile;
  final void Function(EquipmentProfileModel) onConnectAll;
  final VoidCallback onDisconnectAll;

  const _EquipmentSidePanel({
    required this.selectedProfile,
    required this.onSettings,
    required this.onEditProfile,
    required this.onConnectAll,
    required this.onDisconnectAll,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(equipmentStatusRailCollapsedProvider);
    return SidePanel(
      collapsed: collapsed,
      // SidePanel centers its child on the cross axis, and a scroll view
      // shorter than the panel shrinks to its content, so a short readiness
      // list floated the profile block ~90px down the column. Pin it to the
      // top instead.
      child: Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ProfileSection(
                selectedProfile: selectedProfile,
                onSettings: onSettings,
                onEditProfile: onEditProfile,
                onConnectAll: onConnectAll,
                onDisconnectAll: onDisconnectAll,
              ),
              const SizedBox(height: SidePanel.sectionGap),
              const _StatusSections(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The profile block with what goes with it: saving session-only devices and
/// the scan notice.
class _ProfileSection extends StatelessWidget {
  final EquipmentProfileModel? selectedProfile;
  final VoidCallback onSettings;
  final void Function(EquipmentProfileModel) onEditProfile;
  final void Function(EquipmentProfileModel) onConnectAll;
  final VoidCallback onDisconnectAll;

  const _ProfileSection({
    required this.selectedProfile,
    required this.onSettings,
    required this.onEditProfile,
    required this.onConnectAll,
    required this.onDisconnectAll,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ProfileBlock(
          profile: selectedProfile,
          onSettings: onSettings,
          onEditProfile: onEditProfile,
          onConnectAll: onConnectAll,
          onDisconnectAll: onDisconnectAll,
        ),
        const _SaveSessionDevicesButton(),
        if (selectedProfile case final profile?)
          ProfileScanNotice(
            profile: profile,
            padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
          ),
      ],
    );
  }
}

/// Readiness and system health.
class _StatusSections extends StatelessWidget {
  const _StatusSections();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        EquipmentReadinessPanel(),
        SizedBox(height: SidePanel.sectionGap),
        EquipmentHealthPanel(),
      ],
    );
  }
}

/// `[36 px primary-tinted icon square] [name 14/600 + muted meta] [⋮]`.
class _ProfileBlock extends ConsumerWidget {
  final EquipmentProfileModel? profile;
  final VoidCallback onSettings;
  final void Function(EquipmentProfileModel) onEditProfile;
  final void Function(EquipmentProfileModel) onConnectAll;
  final VoidCallback onDisconnectAll;

  const _ProfileBlock({
    required this.profile,
    required this.onSettings,
    required this.onEditProfile,
    required this.onConnectAll,
    required this.onDisconnectAll,
  });

  static const double squareSize = 36.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final model = profile;
    final rig = ref.watch(rigDevicesProvider);
    final assigned = rig.assigned.length;
    final unsaved = rig.sessionOnly.length;

    final meta = <String>[
      if (model?.isDefault ?? false) 'Default profile',
      '$assigned ${assigned == 1 ? 'device' : 'devices'}',
      if (unsaved > 0) '$unsaved unsaved',
    ].join(' · ');

    return Row(
      children: [
        Container(
          width: squareSize,
          height: squareSize,
          decoration: BoxDecoration(
            color: colors.primary.withValues(
              alpha: SkotiqTokens.opacityAccentTint,
            ),
            borderRadius: SkotiqTokens.borderRadiusLg,
          ),
          child: Icon(
            LucideIcons.aperture,
            size: SkotiqTokens.iconSm,
            color: colors.primary,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                model?.name ?? 'No profile selected',
                style: SkotiqTypography.bodyStrong.copyWith(
                  color: colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                meta,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        _ProfileMenuButton(
          profile: model,
          onSettings: onSettings,
          onEditProfile: onEditProfile,
          onConnectAll: onConnectAll,
          onDisconnectAll: onDisconnectAll,
        ),
      ],
    );
  }
}

enum _ProfileMenuAction {
  connectAll,
  disconnectAll,
  scan,
  edit,
  profiles,
  settings,
}

/// The `⋮` beside the profile name. A [SkotiqIconButton] that opens the
/// menu itself rather than a `PopupMenuButton`, so the control is the sheet's
/// icon button and not Material's.
class _ProfileMenuButton extends ConsumerStatefulWidget {
  final EquipmentProfileModel? profile;
  final VoidCallback onSettings;
  final void Function(EquipmentProfileModel) onEditProfile;
  final void Function(EquipmentProfileModel) onConnectAll;
  final VoidCallback onDisconnectAll;

  const _ProfileMenuButton({
    required this.profile,
    required this.onSettings,
    required this.onEditProfile,
    required this.onConnectAll,
    required this.onDisconnectAll,
  });

  @override
  ConsumerState<_ProfileMenuButton> createState() => _ProfileMenuButtonState();
}

class _ProfileMenuButtonState extends ConsumerState<_ProfileMenuButton> {
  final GlobalKey _anchorKey = GlobalKey();

  Future<void> _openMenu() async {
    final anchor = _anchorKey.currentContext;
    if (anchor == null) return;
    final model = widget.profile;
    final action = await showMenu<_ProfileMenuAction>(
      context: context,
      position: menuPositionBelowWidget(anchor),
      items: <PopupMenuEntry<_ProfileMenuAction>>[
        // The page header drops its actions on a phone (they cannot reach the
        // 48 dp tap target beside a title), so this is where they live there
        // — and a second route to them on desktop costs nothing.
        PopupMenuItem<_ProfileMenuAction>(
          value: _ProfileMenuAction.connectAll,
          enabled: model?.hasAssignedDevices ?? false,
          child: const Text('Connect all'),
        ),
        const PopupMenuItem<_ProfileMenuAction>(
          value: _ProfileMenuAction.disconnectAll,
          child: Text('Disconnect all'),
        ),
        const PopupMenuItem<_ProfileMenuAction>(
          value: _ProfileMenuAction.scan,
          child: Text('Scan for devices'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<_ProfileMenuAction>(
          value: _ProfileMenuAction.edit,
          enabled: model != null,
          child: const Text('Edit profile'),
        ),
        const PopupMenuItem<_ProfileMenuAction>(
          value: _ProfileMenuAction.profiles,
          child: Text('All profiles'),
        ),
        const PopupMenuItem<_ProfileMenuAction>(
          value: _ProfileMenuAction.settings,
          child: Text('Equipment settings'),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ProfileMenuAction.connectAll:
        if (model != null) widget.onConnectAll(model);
      case _ProfileMenuAction.disconnectAll:
        widget.onDisconnectAll();
      case _ProfileMenuAction.scan:
        ref.read(discoveryScanRequestProvider.notifier).state++;
      case _ProfileMenuAction.edit:
        if (model != null) widget.onEditProfile(model);
      case _ProfileMenuAction.profiles:
        ref.read(equipmentTabIndexProvider.notifier).state = 1;
      case _ProfileMenuAction.settings:
        widget.onSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqIconButton(
      key: _anchorKey,
      icon: LucideIcons.moreVertical,
      tooltip: 'Profile actions',
      onPressed: _openMenu,
    );
  }
}

/// "Save N devices to profile" — writes the ad-hoc connections into the active
/// profile so they come back on the next launch. Absent when nothing is unsaved.
class _SaveSessionDevicesButton extends ConsumerStatefulWidget {
  const _SaveSessionDevicesButton();

  @override
  ConsumerState<_SaveSessionDevicesButton> createState() =>
      _SaveSessionDevicesButtonState();
}

class _SaveSessionDevicesButtonState
    extends ConsumerState<_SaveSessionDevicesButton> {
  bool _saving = false;

  Future<void> _save(int profileId, Set<DeviceType> slots) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await saveSessionDevicesToProfile(
        ref,
        profileId: profileId,
        slots: slots,
      );
      if (!mounted) return;
      ref.read(profileMutationEpochProvider.notifier).state++;
      context.showSuccessSnackBar(
        saved.isEmpty
            ? 'Nothing to save.'
            : 'Saved ${saved.length} ${saved.length == 1 ? 'device' : 'devices'} '
                'to the profile.',
      );
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Could not save to the profile: ${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    final slots = ref.watch(rigDevicesProvider).sessionOnly;
    final profileId = profile?.id;
    if (profileId == null || slots.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SkotiqButton(
          label: 'Save ${slots.length} '
              '${slots.length == 1 ? 'device' : 'devices'} to profile',
          icon: LucideIcons.save,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          isLoading: _saving,
          onPressed: _saving ? null : () => _save(profileId, slots),
        ),
      ),
    );
  }
}

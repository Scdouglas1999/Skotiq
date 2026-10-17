import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/tutorial_keys/equipment_keys.dart';

/// Footer action that switches the app to the selected profile for this
/// session. Exposed so tests can assert it is present (and absent on the
/// profile already in use) without matching on copy.
const Key profileSidebarActivateButtonKey =
    Key('profileSidebar.useThisProfile');

/// Per-card overflow button that opens the profile menu. Keyed by profile id
/// so a test can target a specific row.
Key profileCardMenuButtonKey(int? profileId) =>
    Key('profileSidebar.menu.$profileId');

/// Device type enum for ordering dots in profile cards
enum _DeviceType {
  camera,
  mount,
  focuser,
  filterWheel,
  guider,
  rotator,
}

/// A vertical sidebar for profile selection and management
class ProfileSidebar extends ConsumerWidget {
  final int? selectedProfileId;
  final ValueChanged<int> onProfileSelected;
  final VoidCallback onCreateProfile;
  final ValueChanged<EquipmentProfileModel> onEditProfile;
  final ValueChanged<EquipmentProfileModel> onConnectAll;
  final VoidCallback onDisconnectAll;
  final ValueChanged<EquipmentProfileModel> onSetDefault;

  /// Make [profile] the profile the rest of the app is pointed at, WITHOUT
  /// touching which profile launches at startup. Before this existed the only
  /// route to a different active rig was right-click → "Set as Default", which
  /// also rewrote the startup choice — so switching scopes for one night
  /// silently changed every night after it.
  final ValueChanged<EquipmentProfileModel> onActivateProfile;
  final ValueChanged<int> onDuplicateProfile;
  final ValueChanged<int> onDeleteProfile;
  final void Function(int oldIndex, int newIndex) onReorderProfiles;
  final VoidCallback? onCollapse;

  const ProfileSidebar({
    super.key,
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
    this.onCollapse,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final profiles = ref.watch(sortedProfilesProvider);

    // Find selected profile
    final selectedProfile = selectedProfileId != null
        ? profiles.where((p) => p.id == selectedProfileId).firstOrNull
        : null;

    // Determine if there are connected/disconnected devices for the selected
    // profile. The per-device connection matrix is computed once, canonically,
    // by `profileConnectionStatusProvider` (the single source of truth) rather
    // than re-derived here.
    final selectedStatus = selectedProfile != null
        ? ref.watch(profileConnectionStatusProvider(selectedProfile))
        : null;
    final hasConnectedDevices = selectedStatus?.hasConnectedCore ?? false;
    final hasDisconnectedDevices = selectedStatus?.hasDisconnectedCore ?? false;

    // Which profile the app is actually pointed at. Selecting a row in this
    // list only moves the inspector; the header, connected devices and status
    // bar follow the ACTIVE profile, so the two have to be told apart.
    final activeProfileId = ref.watch(activeEquipmentProfileProvider)?.id;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          right: BorderSide(color: colors.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          _buildHeader(context, colors),

          // Profile list or empty state
          Expanded(
            child: profiles.isEmpty
                ? _buildEmptyState(context, colors)
                : _buildProfileList(
                    context,
                    ref,
                    profiles,
                    colors,
                    activeProfileId,
                  ),
          ),

          // Footer actions
          if (selectedProfile != null)
            _buildFooter(
              context,
              colors,
              selectedProfile,
              hasConnectedDevices,
              hasDisconnectedDevices,
              isActive: selectedProfile.id == activeProfileId,
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceSm,
      ),
      child: SectionTitle(
        icon: LucideIcons.layers,
        title: 'Profiles',
        trailing: SkotiqIconButton(
          // Spotlight target for the Equipment Setup tour's "Create a
          // Profile" step; without the key the step had nothing to point at.
          key: EquipmentTutorialKeys.createProfileBtn,
          icon: LucideIcons.plus,
          tooltip: 'Create a profile',
          onPressed: onCreateProfile,
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, SkotiqColors colors) {
    return Center(
      child: EmptyState(
        icon: LucideIcons.layers,
        title: 'No profiles yet',
        body: 'A profile saves which devices your rig uses so one press '
            'reconnects the lot.',
        action: SkotiqButton(
          label: 'Create a profile',
          icon: LucideIcons.plus,
          size: ButtonSize.small,
          onPressed: onCreateProfile,
        ),
      ),
    );
  }

  Widget _buildProfileList(
    BuildContext context,
    WidgetRef ref,
    List<EquipmentProfileModel> profiles,
    SkotiqColors colors,
    int? activeProfileId,
  ) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      buildDefaultDragHandles: false,
      onReorderItem: onReorderProfiles,
      itemCount: profiles.length,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final elevation = Tween<double>(begin: 0, end: 6)
                .animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut))
                .value;
            return Material(
              elevation: elevation,
              color: Colors.transparent,
              shadowColor: colors.primary.withValues(alpha: 0.3),
              child: child,
            );
          },
          child: child,
        );
      },
      itemBuilder: (context, index) {
        final profile = profiles[index];
        final isSelected = profile.id == selectedProfileId;

        // Per-device connection state comes from the canonical
        // `profileConnectionStatusProvider`, the single source of truth for
        // the "is device X connected for profile Y" matrix.
        final status = ref.watch(profileConnectionStatusProvider(profile));
        final deviceStates = _toDeviceStateMap(status);
        final connectedCount = status.coreConnectedCount;
        final totalCount = status.coreTotalCount;

        return _ProfileCard(
          key: ValueKey(profile.id),
          profile: profile,
          isSelected: isSelected,
          isActive: profile.id == activeProfileId,
          deviceStates: deviceStates,
          connectedCount: connectedCount,
          totalCount: totalCount,
          index: index,
          colors: colors,
          onTap: () => onProfileSelected(profile.id!),
          onDoubleTap: () {
            onProfileSelected(profile.id!);
            onConnectAll(profile);
          },
          onShowContextMenu: (globalAnchor) => _showProfileContextMenu(
            context,
            ref,
            globalAnchor,
            profile,
            colors,
            isActive: profile.id == activeProfileId,
          ),
        );
      },
    );
  }

  Widget _buildFooter(
    BuildContext context,
    SkotiqColors colors,
    EquipmentProfileModel selectedProfile,
    bool hasConnectedDevices,
    bool hasDisconnectedDevices, {
    required bool isActive,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Selecting a row does not switch rigs — this does. Kept separate
          // from the default-profile star, which decides what loads at
          // startup and must not move just because you looked at another rig.
          if (!isActive) ...[
            SkotiqButton(
              key: profileSidebarActivateButtonKey,
              label: 'Use this profile',
              icon: LucideIcons.check,
              variant: ButtonVariant.primary,
              onPressed: () => onActivateProfile(selectedProfile),
            ),
            const SizedBox(height: 8),
          ],
          // Show Connect All when selected profile has disconnected devices
          if (hasDisconnectedDevices) ...[
            SkotiqButton(
              // Spotlight target for the Equipment Setup tour's "Connect
              // Devices" step.
              key: EquipmentTutorialKeys.quickConnectBar,
              label: 'Connect all',
              icon: LucideIcons.plug,
              // Two primaries side by side is no emphasis at all: on a profile
              // that is not in use yet, switching to it is the first move.
              variant:
                  isActive ? ButtonVariant.primary : ButtonVariant.secondary,
              onPressed: () => onConnectAll(selectedProfile),
            ),
            const SizedBox(height: 8),
          ],
          // Show Disconnect All when any devices connected
          if (hasConnectedDevices) ...[
            SkotiqButton(
              label: 'Disconnect all',
              icon: LucideIcons.unplug,
              variant: ButtonVariant.ghost,
              onPressed: onDisconnectAll,
            ),
            const SizedBox(height: 8),
          ],
          // Always show Edit Profile when a profile is selected
          SkotiqButton(
            label: 'Edit profile',
            icon: LucideIcons.pencil,
            variant: ButtonVariant.ghost,
            onPressed: () => onEditProfile(selectedProfile),
          ),
        ],
      ),
    );
  }

  void _showProfileContextMenu(
    BuildContext context,
    WidgetRef ref,
    Rect globalAnchor,
    EquipmentProfileModel profile,
    SkotiqColors colors, {
    required bool isActive,
  }) {
    // [globalAnchor] arrives in GLOBAL coordinates and `showMenu` measures its
    // insets against the nested Navigator's overlay; see
    // [menuPositionFromRect] for why those differ under `AppShell` and what
    // the unconverted version did to this menu.
    final position = menuPositionFromRect(context, globalAnchor);

    showMenu<String>(
      context: context,
      position: position,
      color: colors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      items: [
        if (!isActive)
          PopupMenuItem(
            value: 'activate',
            child: Row(
              children: [
                Icon(LucideIcons.check, size: 16, color: colors.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Use this profile',
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'default',
          child: Row(
            children: [
              Icon(
                LucideIcons.star,
                size: 16,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 8),
              // Names what the star actually controls: which profile loads at
              // startup, not which one is active now.
              Expanded(
                child: Text(
                  profile.isDefault
                      ? 'Starts up with this profile'
                      : 'Start up with this profile',
                  style:
                      SkotiqTypography.body.copyWith(color: colors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Icon(LucideIcons.pencil, size: 16, color: colors.textSecondary),
              const SizedBox(width: 8),
              Text('Edit profile',
                  style: SkotiqTypography.body
                      .copyWith(color: colors.textPrimary)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'duplicate',
          child: Row(
            children: [
              Icon(LucideIcons.copy, size: 16, color: colors.textSecondary),
              const SizedBox(width: 8),
              Text('Duplicate',
                  style: SkotiqTypography.body
                      .copyWith(color: colors.textPrimary)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(LucideIcons.trash2, size: 16, color: colors.error),
              const SizedBox(width: 8),
              Text('Delete',
                  style: SkotiqTypography.body.copyWith(color: colors.error)),
            ],
          ),
        ),
      ],
    ).then((value) async {
      if (value == null) return;
      if (!context.mounted) return;

      switch (value) {
        case 'activate':
          onActivateProfile(profile);
          break;
        case 'default':
          onSetDefault(profile);
          break;
        case 'edit':
          onEditProfile(profile);
          break;
        case 'duplicate':
          onDuplicateProfile(profile.id!);
          break;
        case 'delete':
          final confirmed =
              await _showDeleteConfirmation(context, profile, colors);
          if (confirmed == true) {
            onDeleteProfile(profile.id!);
          }
          break;
      }
    });
  }

  Future<bool?> _showDeleteConfirmation(
    BuildContext context,
    EquipmentProfileModel profile,
    SkotiqColors colors,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          'Delete profile',
          style:
              SkotiqTypography.sectionTitle.copyWith(color: colors.textPrimary),
        ),
        // Say what actually happens: the delete raises a 6-second Undo that
        // restores the profile in full, so "This cannot be undone" would be
        // false. Profile names are not unique, so the confirm carries the
        // subtitle (telescope + camera, or the device count) — the same thing
        // the sidebar rows are distinguished by.
        content: Text(
          'Delete "${profile.name}" (${profile.subtitle})?\n\n'
          'You can undo this from the message that appears, for a few seconds.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            label: 'Delete',
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
  }

  /// Adapt the canonical [ProfileConnectionStatus] core-slot states onto this
  /// widget's local [_DeviceType] keys for the connection-dot row. Only
  /// assigned core slots are present; the dot builder filters on non-null, so
  /// unassigned slots are simply absent (matching the prior behavior where
  /// `_getDeviceConnectionStates` produced `null` for unassigned devices).
  Map<_DeviceType, DeviceConnectionState?> _toDeviceStateMap(
    ProfileConnectionStatus status,
  ) {
    DeviceConnectionState? stateFor(ProfileDeviceSlot slot) {
      final conn = status[slot];
      return conn.isAssigned ? conn.profileState : null;
    }

    return {
      _DeviceType.camera: stateFor(ProfileDeviceSlot.camera),
      _DeviceType.mount: stateFor(ProfileDeviceSlot.mount),
      _DeviceType.focuser: stateFor(ProfileDeviceSlot.focuser),
      _DeviceType.filterWheel: stateFor(ProfileDeviceSlot.filterWheel),
      _DeviceType.guider: stateFor(ProfileDeviceSlot.guider),
      _DeviceType.rotator: stateFor(ProfileDeviceSlot.rotator),
    };
  }
}

/// Individual profile card widget with all interactions
class _ProfileCard extends StatefulWidget {
  final EquipmentProfileModel profile;
  final bool isSelected;

  /// True for the profile the rest of the app is pointed at.
  final bool isActive;
  final Map<_DeviceType, DeviceConnectionState?> deviceStates;
  final int connectedCount;
  final int totalCount;
  final int index;
  final SkotiqColors colors;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  /// Opens the profile menu anchored on [globalAnchor], in GLOBAL coordinates.
  /// A pointer gesture passes a zero-size rect at the cursor; the overflow
  /// button passes its own bounds, so the menu hangs off the button rather
  /// than off a corner of the card.
  final void Function(Rect globalAnchor) onShowContextMenu;

  const _ProfileCard({
    super.key,
    required this.profile,
    required this.isSelected,
    required this.isActive,
    required this.deviceStates,
    required this.connectedCount,
    required this.totalCount,
    required this.index,
    required this.colors,
    required this.onTap,
    required this.onDoubleTap,
    required this.onShowContextMenu,
  });

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _checkForConnecting();
  }

  @override
  void didUpdateWidget(_ProfileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _checkForConnecting();
  }

  void _checkForConnecting() {
    final hasConnecting = widget.deviceStates.values
        .any((state) => state == DeviceConnectionState.connecting);

    if (hasConnecting) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Get profile color or fall back to primary
    final profileColor = widget.profile.profileColor != null
        ? Color(widget.profile.profileColor!)
        : widget.colors.primary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      // FocusRing makes profile rows keyboard-discoverable; without it the
      // raw GestureDetector silently swallowed focus traversal.
      child: FocusRing(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        child: GestureDetector(
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          onSecondaryTapUp: (details) {
            widget.onShowContextMenu(details.globalPosition & Size.zero);
          },
          onLongPressStart: (details) {
            widget.onShowContextMenu(details.globalPosition & Size.zero);
          },
          child: ReorderableDragStartListener(
            index: widget.index,
            child: AnimatedContainer(
              duration: SkotiqTokens.durationNormal,
              curve: SkotiqTokens.curveStandard,
              margin: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceSm,
                vertical: SkotiqTokens.spaceXs,
              ),
              padding: SkotiqTokens.paddingMd,
              // Selection is a primary ring, not a coloured border and a glow:
              // depth comes from tone (02 §2), and the profile's own colour
              // stays where it belongs — on the profile's dot.
              decoration: widget.isSelected
                  ? SkotiqDecorations.panelSelected(widget.colors)
                  : _isHovered
                      ? SkotiqDecorations.panel(widget.colors)
                      : const BoxDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: icon, name, default star
                  Row(
                    children: [
                      // Profile glyph. The stored emoji is a user choice and
                      // is honoured; the DEFAULT is an icon, never the
                      // telescope emoji 06 §Equipment removes.
                      if (widget.profile.profileIcon != null &&
                          widget.profile.profileIcon!.isNotEmpty)
                        Text(
                          widget.profile.profileIcon!,
                          style: SkotiqTypography.body.copyWith(
                            color: profileColor,
                          ),
                        )
                      else
                        Icon(
                          LucideIcons.aperture,
                          size: SkotiqTokens.iconSm,
                          color: profileColor,
                        ),
                      const SizedBox(width: SkotiqTokens.spaceSm),

                      // Profile name
                      Expanded(
                        child: Text(
                          widget.profile.name,
                          style: SkotiqTypography.bodyStrong
                              .copyWith(color: widget.colors.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),

                      // Default star indicator
                      if (widget.profile.isDefault)
                        Tooltip(
                          message: 'Starts up with this profile',
                          child: Icon(
                            LucideIcons.star,
                            size: 14,
                            color: widget.colors.warning,
                          ),
                        ),

                      // Keep profile actions discoverable without a context menu.
                      //
                      // Builder so the anchor is the BUTTON's render object.
                      // The enclosing `build` context is the card's, and its
                      // box put the menu against a corner of the card instead
                      // of under the control that opened it.
                      Builder(
                        builder: (buttonContext) => SkotiqIconButton(
                          key: profileCardMenuButtonKey(widget.profile.id),
                          icon: LucideIcons.moreVertical,
                          tooltip: 'Profile actions',
                          size: IconButtonSize.sm,
                          onPressed: () {
                            // Not null-guarded: the button has just been
                            // pressed, so it is laid out. A fallback offset
                            // here is how the old code shipped a menu that
                            // opened in the wrong place instead of failing.
                            final box =
                                buttonContext.findRenderObject()! as RenderBox;
                            widget.onShowContextMenu(
                              box.localToGlobal(Offset.zero) & box.size,
                            );
                          },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 4),

                  // Subtitle row
                  Text(
                    widget.profile.subtitle,
                    style: SkotiqTypography.caption.copyWith(
                      color: widget.colors.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 8),

                  // Bottom row: device dots + connection count
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Device dots
                      _buildDeviceDots(),

                      // "Selected" (this card is highlighted) and "in use by
                      // the app" are different things, and the header/devices
                      // panel follows the latter. Without this the two are
                      // indistinguishable.
                      if (widget.isActive)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: SkotiqTokens.spaceXs + 2,
                          ),
                          child: SkotiqChip(
                            label: 'In use',
                            tone: ChipTone.primary,
                          ),
                        ),

                      // Connection count
                      if (widget.totalCount > 0)
                        Text(
                          '${widget.connectedCount}/${widget.totalCount}',
                          style: SkotiqTypography.monoCaption.copyWith(
                            color: widget.connectedCount == widget.totalCount
                                ? widget.colors.success
                                : widget.connectedCount > 0
                                    ? widget.colors.warning
                                    : widget.colors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceDots() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: _DeviceType.values
              .where((type) => widget.deviceStates[type] != null)
              .map((type) => _buildDot(type, widget.deviceStates[type]!))
              .toList(),
        );
      },
    );
  }

  Widget _buildDot(_DeviceType type, DeviceConnectionState state) {
    final Color color;
    final bool isHollow;
    final bool isPulsing;

    switch (state) {
      case DeviceConnectionState.connected:
        color = widget.colors.success;
        isHollow = false;
        isPulsing = false;
      case DeviceConnectionState.connecting:
        color = widget.colors.warning;
        isHollow = false;
        isPulsing = true;
      case DeviceConnectionState.error:
        color = widget.colors.error;
        isHollow = false;
        isPulsing = false;
      case DeviceConnectionState.disconnected:
        color = widget.colors.textMuted.withValues(alpha: 0.5);
        isHollow = true;
        isPulsing = false;
    }

    final effectiveOpacity = isPulsing ? _pulseAnimation.value : 1.0;

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: _getDeviceTypeTooltip(type, state),
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isHollow
                ? Colors.transparent
                : color.withValues(alpha: effectiveOpacity),
            border: Border.all(
              color: color.withValues(alpha: effectiveOpacity),
              width: isHollow ? 1.5 : 0,
            ),
          ),
        ),
      ),
    );
  }

  String _getDeviceTypeTooltip(_DeviceType type, DeviceConnectionState state) {
    final typeName = switch (type) {
      _DeviceType.camera => 'Camera',
      _DeviceType.mount => 'Mount',
      _DeviceType.focuser => 'Focuser',
      _DeviceType.filterWheel => 'Filter wheel',
      _DeviceType.guider => 'Guider',
      _DeviceType.rotator => 'Rotator',
    };

    final stateName = switch (state) {
      DeviceConnectionState.connected => 'Connected',
      DeviceConnectionState.connecting => 'Connecting...',
      DeviceConnectionState.error => 'Error',
      DeviceConnectionState.disconnected => 'Disconnected',
    };

    return '$typeName: $stateName';
  }
}

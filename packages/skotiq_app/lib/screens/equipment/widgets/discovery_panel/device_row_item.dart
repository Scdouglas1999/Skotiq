part of '../discovery_panel.dart';

class _DeviceRowItem extends ConsumerStatefulWidget {
  final UnifiedDevice device;
  final DeviceType deviceType;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;
  final ValueChanged<(DeviceInfo, int)>? onAssignDevice;

  const _DeviceRowItem({
    required this.device,
    required this.deviceType,
    required this.onConnect,
    required this.onDisconnect,
    this.onAssignDevice,
  });

  @override
  ConsumerState<_DeviceRowItem> createState() => _DeviceRowItemState();
}

class _DeviceRowItemState extends ConsumerState<_DeviceRowItem> {
  bool _isConnecting = false;
  bool _isAssigning = false;

  /// The assignment in progress; a newer one or a host change drops it.
  late final _assignments = ref.backendScopes(alive: () => mounted);

  bool _isDeviceConnected() {
    final slot = readDeviceSlot(ref, widget.deviceType);
    return slot.connectionState == DeviceConnectionState.connected &&
        _deviceIdsMatch(slot.deviceId, widget.device.activeDeviceId);
  }

  bool _deviceIdsMatch(String? connectedId, String discoveredId) {
    if (connectedId == null) return false;
    final c = connectedId.trim().toLowerCase();
    final d = discoveredId.trim().toLowerCase();
    if (c == d) return true;
    final normC = c.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final normD = d.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (normC == normD) return true;
    if (normC.contains(normD) || normD.contains(normC)) return true;
    return false;
  }

  Future<void> _handleConnect() async {
    if (_isConnecting) return;
    // A click that lands after the connect completes but before the row
    // repaints as "Disconnect" issued a SECOND connect to a device that was
    // already connected — two `Connecting to Camera device: sim_camera_1`
    // 190 ms apart with no disconnect between them, each starting its own
    // heartbeat monitor.
    if (_isDeviceConnected()) return;

    setState(() => _isConnecting = true);
    try {
      await widget.onConnect();
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  Future<void> _handleAssign(AssignAction action) async {
    if (_isAssigning) return;
    final profiles = ref.read(sortedProfilesProvider);
    if (action.profileId == AssignAction.newProfile) {
      await _assignToNewProfile(profiles);
      return;
    }
    final profile =
        profiles.where((profile) => profile.id == action.profileId).firstOrNull;
    if (profile == null) {
      if (mounted) {
        context.showErrorSnackBar(
          'Cannot assign ${widget.device.displayName}: the selected profile '
          'no longer exists.',
        );
      }
      return;
    }
    final device = widget.device;
    final assignment = _assignments.beginLatest();
    setState(() => _isAssigning = true);
    try {
      final profileService = ref.read(profileServiceProvider);

      await profileService.updateProfileDevices(action.profileId, {
        action.deviceType: device.activeDeviceId,
      });

      if (!mounted || assignment.isStale) return;

      // Notify callback if provided - need to convert from UnifiedDevice to DeviceInfo
      if (widget.onAssignDevice != null) {
        final deviceInfo = device.activeDevice;
        widget.onAssignDevice!((deviceInfo, action.profileId));
      }

      context.showSuccessSnackBar(
          'Assigned ${device.displayName} to ${profile.name}');
    } catch (e) {
      if (mounted && assignment.isCurrent) {
        context.showErrorSnackBar('Failed to assign device: ${userFacingError(e)}');
      }
    } finally {
      if (assignment.isCurrent) setState(() => _isAssigning = false);
    }
  }

  /// Make a profile that starts with this device in it, and select it.
  Future<void> _assignToNewProfile(List<EquipmentProfileModel> profiles) async {
    final device = widget.device;
    final assignment = _assignments.beginLatest();
    setState(() => _isAssigning = true);
    try {
      final name = uniqueProfileName(
        'My Equipment',
        profiles.map((profile) => profile.name),
      );
      final profileId = await ref
          .read(equipmentProfilesProvider.notifier)
          .saveProfile(EquipmentProfileModel(name: name));
      await ref.read(profileServiceProvider).updateProfileDevices(profileId, {
        widget.deviceType: device.activeDeviceId,
      });
      if (!mounted || assignment.isStale) return;
      ref.read(profileMutationEpochProvider.notifier).state++;
      ref.read(selectedEquipmentProfileIdProvider.notifier).state = profileId;
      context.showSuccessSnackBar(
        'Created profile "$name" with ${device.displayName}',
      );
    } catch (e) {
      if (mounted && assignment.isCurrent) {
        context.showErrorSnackBar(failureText('Failed to create a profile', e));
      }
    } finally {
      if (assignment.isCurrent) setState(() => _isAssigning = false);
    }
  }

  String _getSlotStatus(EquipmentProfileModel profile, DeviceType type) {
    final currentId = profile.deviceIdFor(type);
    return currentId == null || currentId.isEmpty ? '(empty)' : '(has device)';
  }

  List<PopupMenuEntry<AssignAction>> _buildAssignMenuItems(
      SkotiqColors colors) {
    final profiles = ref.read(sortedProfilesProvider);
    final items = <PopupMenuEntry<AssignAction>>[];

    for (final profile in profiles) {
      if (profile.id == null) continue;

      final slotStatus = _getSlotStatus(profile, widget.deviceType);
      items.add(PopupMenuItem<AssignAction>(
        value: AssignAction(
          profileId: profile.id!,
          deviceType: widget.deviceType,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                profile.name,
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              slotStatus,
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ));
    }

    // Always offered, and the only entry before the first profile exists:
    // a device can start a profile instead of waiting for one.
    if (items.isNotEmpty) items.add(const PopupMenuDivider());
    items.add(PopupMenuItem<AssignAction>(
      value: AssignAction(
        profileId: AssignAction.newProfile,
        deviceType: widget.deviceType,
      ),
      child: Row(
        children: [
          Icon(LucideIcons.plus, size: 14, color: colors.textSecondary),
          const SizedBox(width: 8),
          Text(
            'New profile with this device',
            style: SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    ));

    return items;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      _assignments.cancelAll();
      if (_isAssigning) setState(() => _isAssigning = false);
    });
    final colors = SkotiqColors.of(context);

    ref.watch(cameraStateProvider);
    ref.watch(mountStateProvider);
    ref.watch(focuserStateProvider);
    ref.watch(filterWheelStateProvider);
    ref.watch(guiderStateProvider);
    ref.watch(rotatorStateProvider);
    ref.watch(domeStateProvider);
    ref.watch(weatherStateProvider);
    ref.watch(safetyMonitorStateProvider);
    ref.watch(switchStateProvider);
    ref.watch(coverCalibratorStateProvider);

    final isConnected = _isDeviceConnected();
    final activeBackend = widget.device.activeBackend;

    return LayoutBuilder(
      builder: (context, constraints) =>
          _row(colors, constraints, isConnected, activeBackend: activeBackend),
    );
  }

  /// The row proper. Below [_discoveryRowCompactWidth] the Connect / Disconnect
  /// button drops its label and becomes an icon: a device NAME truncated to
  /// "Simulated Filter W…" costs the operator the one thing the row exists to
  /// tell them, and a verb they already know does not.
  Widget _row(
    SkotiqColors colors,
    BoxConstraints constraints,
    bool isConnected, {
    required DriverType activeBackend,
  }) {
    final compact = constraints.hasBoundedWidth &&
        constraints.maxWidth < _discoveryRowCompactWidth;
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(
            widget.deviceType.icon,
            size: _discoveryRowIconSize,
            color: isConnected ? colors.success : colors.textMuted,
          ),
          const SizedBox(width: 10),
          // Expanded, not Flexible-beside-a-Spacer: sharing the row's slack
          // with a Spacer gave the name half of it and truncated
          // "Simulated Filter Wheel" to "Simulated Filter W…". The name is the
          // one thing the row exists to say, so it takes ALL the slack and the
          // actions sit at the end.
          Expanded(
            child: Text(
              widget.device.displayName,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          // The protocol, as a quiet mono tag: "sim", "ascom", "indi".
          Text(
            activeBackend.shortLabel.toLowerCase(),
            style: SkotiqTypography.monoCaption.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          // "Add to profile" persists the device; "Connect" does not — it is a
          // session-only connection that is silently gone after a restart. The
          // two sat side by side with nothing saying so, so the difference is
          // spelled out in the tooltip here and marked on the resulting panel.
          Tooltip(
            message: isConnected
                ? 'Disconnect this device now.'
                : 'Connect for this session only. It is NOT saved to a '
                    'profile and will not reconnect on the next launch — use '
                    '"Add to profile" for that.',
            child: compact
                ? SkotiqIconButton(
                    icon: isConnected ? LucideIcons.unplug : LucideIcons.plug,
                    tooltip: isConnected ? 'Disconnect' : 'Connect',
                    size: IconButtonSize.sm,
                    onPressed: _isConnecting
                        ? null
                        : (isConnected ? widget.onDisconnect : _handleConnect),
                  )
                : SkotiqButton(
                    label: isConnected ? 'Disconnect' : 'Connect',
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                    isLoading: _isConnecting,
                    onPressed: _isConnecting
                        ? null
                        : (isConnected ? widget.onDisconnect : _handleConnect),
                  ),
          ),
          const SizedBox(width: _discoveryRowActionGap),
          _AddToProfileButton(
            enabled: !_isAssigning,
            isBusy: _isAssigning,
            itemBuilder: () => _buildAssignMenuItems(colors),
            onSelected: _handleAssign,
          ),
        ],
      ),
    );
  }
}

/// The row's "Add to profile" control: a `secondary sm` button that opens the
/// profile picker itself, so the sheet's button is the control rather than a
/// bare `PopupMenuButton` child.
class _AddToProfileButton extends StatefulWidget {
  final bool enabled;
  final bool isBusy;
  final List<PopupMenuEntry<AssignAction>> Function() itemBuilder;
  final ValueChanged<AssignAction> onSelected;

  const _AddToProfileButton({
    required this.enabled,
    required this.isBusy,
    required this.itemBuilder,
    required this.onSelected,
  });

  @override
  State<_AddToProfileButton> createState() => _AddToProfileButtonState();
}

class _AddToProfileButtonState extends State<_AddToProfileButton> {
  final GlobalKey _anchorKey = GlobalKey();

  Future<void> _open() async {
    final anchor = _anchorKey.currentContext;
    if (anchor == null) return;
    final action = await showMenu<AssignAction>(
      context: context,
      position: menuPositionBelowWidget(anchor),
      items: widget.itemBuilder(),
    );
    if (!mounted || action == null) return;
    widget.onSelected(action);
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqButton(
      key: _anchorKey,
      label: 'Add to profile',
      variant: ButtonVariant.secondary,
      size: ButtonSize.small,
      isLoading: widget.isBusy,
      onPressed: widget.enabled ? _open : null,
    );
  }
}

const double _discoveryRowIconSize = 15.0;

/// Gap between the row's two actions (mockup: 6).
const double _discoveryRowActionGap = 6.0;

/// Below this the row's Connect button becomes icon-only so the device name
/// keeps the width.
const double _discoveryRowCompactWidth = 380.0;

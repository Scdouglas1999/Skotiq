part of '../discovery_panel.dart';

class _DeviceRowItem extends ConsumerStatefulWidget {
  final KnownDevice known;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;
  final ValueChanged<(DeviceInfo, int)>? onAssignDevice;

  const _DeviceRowItem({
    required this.known,
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

  DeviceType get _type => widget.known.type;

  Future<void> _handleConnect() async {
    // A click that lands after the connect completes but before the row
    // repaints as "Disconnect" would issue a second connect to a device that
    // is already connected.
    final state = widget.known.state;
    if (_isConnecting ||
        state == DeviceConnectionState.connected ||
        state == DeviceConnectionState.connecting) {
      return;
    }
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
          'Cannot assign ${widget.known.name}: the selected profile '
          'no longer exists.',
        );
      }
      return;
    }
    final device = widget.known.device;
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
        context.showErrorSnackBar(
            'Failed to assign device: ${userFacingError(e)}');
      }
    } finally {
      if (assignment.isCurrent) setState(() => _isAssigning = false);
    }
  }

  /// Make a profile that starts with this device in it, and select it.
  Future<void> _assignToNewProfile(List<EquipmentProfileModel> profiles) async {
    final device = widget.known.device;
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
        _type: device.activeDeviceId,
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

      final slotStatus = _getSlotStatus(profile, _type);
      items.add(PopupMenuItem<AssignAction>(
        value: AssignAction(
          profileId: profile.id!,
          deviceType: _type,
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
        deviceType: _type,
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
    return LayoutBuilder(
      builder: (context, constraints) => _row(colors, constraints),
    );
  }

  /// [child] with the failure as its tooltip, when there is one.
  static Widget _withErrorTooltip(String? error, Widget child) =>
      error == null || error.isEmpty
          ? child
          : Tooltip(message: error, child: child);

  /// What the row says about the device's state, and in which color.
  (String, Color) _stateText(SkotiqColors colors) =>
      switch (widget.known.state) {
        DeviceConnectionState.connected => ('Connected', colors.success),
        DeviceConnectionState.connecting => ('Connecting', colors.warning),
        DeviceConnectionState.error => ('Failed to connect', colors.error),
        DeviceConnectionState.disconnected => (
            'Not connected',
            colors.textMuted,
          ),
      };

  /// The row proper: name over a muted line with the state, the protocol and
  /// whether the active profile names the device. Below
  /// [_discoveryRowCompactWidth] Connect / Disconnect drops its label and
  /// becomes an icon, so the device name keeps the width.
  Widget _row(SkotiqColors colors, BoxConstraints constraints) {
    final known = widget.known;
    final compact = constraints.hasBoundedWidth &&
        constraints.maxWidth < _discoveryRowCompactWidth;
    final isConnected = known.isConnected;
    final busy =
        _isConnecting || known.state == DeviceConnectionState.connecting;
    final (stateLabel, stateColor) = _stateText(colors);
    final secondary = SkotiqTypography.bodySm.copyWith(color: colors.textMuted);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(
            _type.icon,
            size: _discoveryRowIconSize,
            color: isConnected ? colors.success : colors.textMuted,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          // The name takes all the slack and the actions sit at the end: the
          // name is the one thing the row exists to say.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  known.name,
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                _withErrorTooltip(
                  known.error,
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: stateLabel,
                          style: secondary.copyWith(color: stateColor),
                        ),
                        TextSpan(
                          text: ' · ${known.device.activeBackend.shortLabel}'
                              '${known.inProfile ? ' · In profile' : ''}',
                        ),
                      ],
                    ),
                    style: secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          // "Add to profile" persists the device; "Connect" does not — it is a
          // session-only connection that is gone after a restart unless the
          // profile names the device.
          Tooltip(
            message: isConnected
                ? 'Disconnect this device now.'
                : known.inProfile
                    ? 'Connect this device now.'
                    : 'Connect for this session only. It is NOT saved to a '
                        'profile and will not reconnect on the next launch. '
                        'Use "Add to profile" for that.',
            child: compact
                ? SkotiqIconButton(
                    icon: isConnected ? LucideIcons.unplug : LucideIcons.plug,
                    tooltip: isConnected ? 'Disconnect' : 'Connect',
                    size: IconButtonSize.sm,
                    onPressed: busy
                        ? null
                        : (isConnected ? widget.onDisconnect : _handleConnect),
                  )
                : SkotiqButton(
                    label: isConnected ? 'Disconnect' : 'Connect',
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                    isLoading: busy,
                    onPressed: busy
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

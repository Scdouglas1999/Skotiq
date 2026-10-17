// Connect-all progress strip, the header's connection chip, and the device grid.
part of '../equipment_screen.dart';

/// Renders one chip per device-type tracked by
/// [deviceConnectionProgressProvider]. Each chip shows the device type, the
/// outcome of the attempt, and a tooltip with the backend error message when
/// the connect attempt failed.
///
/// The strip hides itself completely when no sweep has been run yet (the
/// provider state is empty). After a sweep completes the chips remain
/// visible until [DeviceConnectionProgressNotifier.clear] is called, so the
/// user can review what failed without having to re-run "Connect All".
class _ConnectAllProgressStrip extends ConsumerWidget {
  const _ConnectAllProgressStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final state = ref.watch(deviceConnectionProgressProvider);

    if (state.byDeviceType.isEmpty) {
      return const SizedBox.shrink();
    }

    // Stable canonical ordering matching the connectAllFromProfile dispatch
    // order so chips don't jitter between rebuilds.
    const order = <String>[
      'camera',
      'mount',
      'focuser',
      'filter wheel',
      'guider',
      'rotator',
      'dome',
      'weather station',
      'safety monitor',
      'cover calibrator',
    ];

    final entries = <DeviceConnectProgress>[
      for (final type in order)
        if (state.byDeviceType.containsKey(type)) state.byDeviceType[type]!,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: SkotiqPanel(
        head: PanelHead(
          label: 'Last connect sweep',
          icon: LucideIcons.plugZap,
          trailing: [
            if (!state.isSweeping)
              SkotiqButton(
                label: 'Clear',
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                onPressed: () =>
                    ref.read(deviceConnectionProgressProvider.notifier).clear(),
              ),
          ],
        ),
        // The headline is a SENTENCE, so it is body text under the eyebrow —
        // not the eyebrow itself, which PanelHead uppercases.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _stripHeadline(state),
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final event in entries)
                  _ConnectAllProgressChip(event: event, colors: colors),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Dates and scores the finished sweep.
  ///
  /// The strip is a RECORD — it survives until the operator clears it, so after
  /// a Disconnect All it sat undated next to a live "No devices connected"
  /// empty state still reading `${source} result` with four green `Connected`
  /// chips. A time and a score make it unmistakably the past.
  static String _stripHeadline(DeviceConnectionProgressState state) {
    if (state.isSweeping) return 'Connecting…';
    final scored =
        '${state.connectedCount} of ${state.byDeviceType.length} succeeded';
    final at = state.finishedAt;
    if (at == null) return '${state.source}: $scored';
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return '${state.source} at $hh:$mm: $scored';
  }
}

class _ConnectAllProgressChip extends StatelessWidget {
  final DeviceConnectProgress event;
  final SkotiqColors colors;

  const _ConnectAllProgressChip({
    required this.event,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final (tone, label) = _statusVisuals(event.status);
    final chip = SkotiqChip(
      label: '${event.deviceType} · $label',
      icon: _iconForDeviceType(event.deviceType),
      tone: tone,
      dot: true,
    );

    if (event.status == DeviceConnectProgressStatus.failed &&
        event.errorMessage != null) {
      return Tooltip(
        message: event.errorMessage!,
        waitDuration: SkotiqTokens.durationNormal,
        child: chip,
      );
    }
    return chip;
  }

  /// Outcome words, not state words. `Connected` is what the device cards and
  /// the status bar say about NOW; a chip that outlives the sweep saying the
  /// same thing was read as live state and contradicted them after a
  /// disconnect. `Succeeded` / `Failed` can only be read as what the attempt
  /// did.
  static (ChipTone, String) _statusVisuals(DeviceConnectProgressStatus status) {
    switch (status) {
      case DeviceConnectProgressStatus.connecting:
        return (ChipTone.warning, 'Connecting');
      case DeviceConnectProgressStatus.connected:
        return (ChipTone.success, 'Succeeded');
      case DeviceConnectProgressStatus.failed:
        return (ChipTone.error, 'Failed');
    }
  }

  static IconData _iconForDeviceType(String deviceType) {
    switch (deviceType) {
      case 'camera':
        return LucideIcons.camera;
      case 'mount':
        return LucideIcons.compass;
      case 'focuser':
        return LucideIcons.focus;
      case 'filter wheel':
        return LucideIcons.disc;
      case 'guider':
        return LucideIcons.crosshair;
      case 'rotator':
        return LucideIcons.rotateCw;
      case 'dome':
        return LucideIcons.home;
      case 'weather station':
        return LucideIcons.cloudSun;
      case 'safety monitor':
        return LucideIcons.shieldCheck;
      case 'cover calibrator':
        return LucideIcons.lamp;
      default:
        return LucideIcons.circle;
    }
  }
}

// The page header's connection chip

/// `[dot] N connected` in the page header — the ONE place this screen states
/// how many devices are up.
/// How many devices are connected right now, across every slot.
///
/// Shared so the header chip and the header's "Disconnect all" agree by
/// construction: an action that disconnects everything must appear exactly when
/// the chip says there is something to disconnect, and two copies of this list
/// would drift the first time a slot was added.
int equipmentConnectedCount(WidgetRef ref) {
  final connectionStates = <DeviceConnectionState>[
    ref.watch(cameraStateProvider).connectionState,
    ref.watch(mountStateProvider).connectionState,
    ref.watch(focuserStateProvider).connectionState,
    ref.watch(filterWheelStateProvider).connectionState,
    ref.watch(guiderStateProvider).connectionState,
    ref.watch(rotatorStateProvider).connectionState,
    ref.watch(domeStateProvider).connectionState,
    ref.watch(weatherStateProvider).connectionState,
    ref.watch(safetyMonitorStateProvider).connectionState,
    ref.watch(switchStateProvider).connectionState,
    ref.watch(coverCalibratorStateProvider).connectionState,
  ];
  return connectionStates
      .where((state) => state == DeviceConnectionState.connected)
      .length;
}

class _ConnectionStatusSummary extends ConsumerWidget {
  const _ConnectionStatusSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectedCount = equipmentConnectedCount(ref);

    if (connectedCount == 0) {
      return const SkotiqChip(label: 'Nothing connected', dot: true);
    }

    // How many of those connections are NOT the profile's devices. Without this
    // the header read a green "9 connected" while the persistent bottom status
    // bar read "My Equipment 4/4" — two numbers, one screen, no explanation, and
    // the five extra devices silently vanished on the next launch.
    final sessionOnly = ref.watch(sessionOnlyConnectedSlotsProvider).length;

    return Tooltip(
      message: sessionOnly > 0
          ? '$connectedCount device${connectedCount == 1 ? '' : 's'} connected, '
              'of which $sessionOnly ${sessionOnly == 1 ? 'is' : 'are'} not '
              'saved to the active profile and will not reconnect on the next '
              'launch.'
          : '$connectedCount device${connectedCount == 1 ? '' : 's'} connected, '
              'all saved to the active profile.',
      child: SkotiqChip(
        label: sessionOnly > 0
            ? '$connectedCount connected · $sessionOnly unsaved'
            : '$connectedCount connected',
        tone: sessionOnly > 0 ? ChipTone.warning : ChipTone.success,
        dot: true,
      ),
    );
  }
}

// Device grid

class _DeviceDashboard extends ConsumerWidget {
  final EquipmentProfileModel? profile;

  /// Invoked when the empty-state primary CTA is pressed. Required so the
  /// "Connect devices" button is discoverable directly from the empty state
  /// itself rather than only from the profile menu.
  final void Function(EquipmentProfileModel) onConnectAll;

  /// Invoked when the empty state's action routes to the profile editor so the
  /// user can attach equipment without hunting through a menu.
  final void Function(EquipmentProfileModel) onEditProfile;

  /// Optional chrome rendered above the grid INSIDE this column's scroll view
  /// (narrow layout): the side panel's content, which has no column of its own
  /// below the shell breakpoint.
  final Widget? header;

  /// Chrome rendered BELOW the grid, inside the same scroll view. Used for the
  /// discovery drawer on viewports too short to seat it as a sibling (see
  /// [_EquipmentMainColumn._cardsAndDiscovery]).
  final Widget? footer;

  const _DeviceDashboard({
    this.profile,
    required this.onConnectAll,
    required this.onEditProfile,
    this.header,
    this.footer,
  });

  /// A scroll view hands its child UNBOUNDED height, which would trip the
  /// `Flexible` inside DiscoveryPanel's own column. Bounding the footer keeps
  /// that resolvable while still letting it size to its content.
  Widget? get _boundedFooter => footer == null
      ? null
      : ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 500),
          child: footer!,
        );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch device connection states
    final cameraState = ref.watch(cameraStateProvider);
    final mountState = ref.watch(mountStateProvider);
    final focuserState = ref.watch(focuserStateProvider);
    final filterWheelState = ref.watch(filterWheelStateProvider);
    final guiderState = ref.watch(guiderStateProvider);
    final rotatorState = ref.watch(rotatorStateProvider);
    final domeState = ref.watch(domeStateProvider);
    final weatherState = ref.watch(weatherStateProvider);
    final safetyMonitorState = ref.watch(safetyMonitorStateProvider);
    final coverCalibratorState = ref.watch(coverCalibratorStateProvider);
    final switchState = ref.watch(switchStateProvider);

    // Which connected slots are NOT the profile's devices. Resolved here, where
    // the profile is already in scope, and handed to each card as a plain flag —
    // a single card must not depend on the profiles provider (on a remote backend
    // that starts a periodic host poll).
    final sessionOnlySlots = ref.watch(sessionOnlyConnectedSlotsProvider);
    bool adHoc(ProfileDeviceSlot slot) => sessionOnlySlots.contains(slot);

    // Build list of connected device cards
    final connectedCards = <Widget>[];

    if (cameraState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        key: EquipmentTutorialKeys.cameraCard,
        type: ConnectedDeviceType.camera,
        sessionOnly: adHoc(ProfileDeviceSlot.camera),
      ));
    }

    if (mountState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        key: EquipmentTutorialKeys.mountCard,
        type: ConnectedDeviceType.mount,
        sessionOnly: adHoc(ProfileDeviceSlot.mount),
      ));
    }

    if (focuserState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        type: ConnectedDeviceType.focuser,
        sessionOnly: adHoc(ProfileDeviceSlot.focuser),
      ));
    }

    if (filterWheelState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        type: ConnectedDeviceType.filterWheel,
        sessionOnly: adHoc(ProfileDeviceSlot.filterWheel),
      ));
    }

    if (guiderState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        type: ConnectedDeviceType.guider,
        sessionOnly: adHoc(ProfileDeviceSlot.guider),
      ));
    }

    if (rotatorState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        type: ConnectedDeviceType.rotator,
        sessionOnly: adHoc(ProfileDeviceSlot.rotator),
      ));
    }

    if (domeState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        type: ConnectedDeviceType.dome,
        sessionOnly: adHoc(ProfileDeviceSlot.dome),
      ));
    }

    if (weatherState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        type: ConnectedDeviceType.weather,
        sessionOnly: adHoc(ProfileDeviceSlot.weather),
      ));
    }

    if (safetyMonitorState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        type: ConnectedDeviceType.safetyMonitor,
        sessionOnly: adHoc(ProfileDeviceSlot.safetyMonitor),
      ));
    }

    if (coverCalibratorState.connectionState ==
        DeviceConnectionState.connected) {
      connectedCards.add(ConnectedDeviceCard(
        type: ConnectedDeviceType.coverCalibrator,
        sessionOnly: adHoc(ProfileDeviceSlot.coverCalibrator),
      ));
    }

    // Switch / power box has no ConnectedDeviceType, so render its per-channel
    // control card directly (dew heaters, outlets). Works remotely via the
    // switch-channel fix.
    if (switchState.connectionState == DeviceConnectionState.connected) {
      connectedCards.add(const SwitchControlCard());
    }

    // No profile selected state.
    //
    // REMOTE (slave) mode: cards come from per-device state providers, not the
    // profile's slots, so a connected device must render even before the host's
    // profile hydrates (or if the host has devices but no active profile). Only
    // fall through to the "select a profile" empty-state when there is genuinely
    // nothing connected. Local/host keeps the original null-profile prompt.
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    if (profile == null && (!isRemoteMode || connectedCards.isEmpty)) {
      return _EquipmentEmptyState(
        header: header,
        footer: _boundedFooter,
        child: EmptyState(
          icon: LucideIcons.layoutGrid,
          title: 'No profile is selected',
          body: 'Pick a profile to see the devices it connects.',
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

    // Nothing connected: ONE empty state, and the discovery drawer below it is
    // the way forward.
    if (connectedCards.isEmpty) {
      final p = profile!;
      final hasDevicesAssigned =
          (p.cameraId != null && p.cameraId!.isNotEmpty) ||
              (p.mountId != null && p.mountId!.isNotEmpty) ||
              (p.focuserId != null && p.focuserId!.isNotEmpty) ||
              (p.filterWheelId != null && p.filterWheelId!.isNotEmpty) ||
              (p.guiderId != null && p.guiderId!.isNotEmpty) ||
              (p.rotatorId != null && p.rotatorId!.isNotEmpty) ||
              (p.domeId != null && p.domeId!.isNotEmpty) ||
              (p.weatherId != null && p.weatherId!.isNotEmpty) ||
              (p.coverCalibratorId != null && p.coverCalibratorId!.isNotEmpty);

      return _EquipmentEmptyState(
        header: header,
        footer: _boundedFooter,
        child: hasDevicesAssigned
            ? EmptyState(
                icon: LucideIcons.unplug,
                title: 'Nothing is connected',
                body: 'Connect the equipment this profile assigns, or pick a '
                    'device from the list below.',
                action: SkotiqButton(
                  label: 'Connect devices',
                  icon: LucideIcons.plug,
                  size: ButtonSize.small,
                  onPressed: () => onConnectAll(p),
                ),
              )
            : EmptyState(
                icon: LucideIcons.plusCircle,
                title: 'This profile has no devices',
                body: 'Add equipment to the profile, or connect a device from '
                    'the list below.',
                action: SkotiqButton(
                  label: 'Edit profile',
                  icon: LucideIcons.pencil,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () => onEditProfile(p),
                ),
              ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) header!,
          Padding(
            padding: _bodyPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const RunDashboardRecoveryBanner(),
                const _ProfileMismatchBanner(),
                const _ConnectAllProgressStrip(),
                _DeviceGrid(cards: connectedCards),
              ],
            ),
          ),
          if (_boundedFooter != null) _boundedFooter!,
        ],
      ),
    );
  }
}

/// Lays the device panels out in a 3-column grid (2 then 1 as the column
/// narrows), with the rows of each run sharing a height so the grid is never
/// ragged, and an "add more" slot as the last cell.
class _DeviceGrid extends StatelessWidget {
  final List<Widget> cards;

  const _DeviceGrid({required this.cards});

  /// The grid gap, from the mockup.
  static const double spacing = SkotiqTokens.spaceLg;

  /// Narrowest a device panel may get before the grid drops a column.
  static const double minTileWidth = 300.0;

  /// Never more than three columns: the mockup's grid, and wider tiles only
  /// stretch the readouts apart.
  static const int maxColumns = 3;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : minTileWidth * maxColumns;
        final columns = ((available + spacing) / (minTileWidth + spacing))
            .floor()
            .clamp(1, maxColumns);

        // The cell width the panels are told about. They must not measure it
        // themselves: a LayoutBuilder has no intrinsic height, and these rows
        // are laid out inside an IntrinsicHeight so a row's panels share a
        // height.
        final tileWidth = (available - spacing * (columns - 1)) / columns;

        final cells = <Widget>[...cards, const _EmptySlotPanel()];
        final rows = <Widget>[];
        for (var start = 0; start < cells.length; start += columns) {
          final end = (start + columns).clamp(0, cells.length);
          final rowCells = cells.sublist(start, end);
          if (rows.isNotEmpty) rows.add(const SizedBox(height: spacing));
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < columns; i++) ...[
                    if (i > 0) const SizedBox(width: spacing),
                    Expanded(
                      child: i < rowCells.length
                          ? DeviceTileWidth(
                              width: tileWidth,
                              child: rowCells[i],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        );
      },
    );
  }
}

/// The "add more equipment" slot: an outlined panel, not a filled one, so it
/// reads as a gap in the grid rather than another device.
class _EmptySlotPanel extends ConsumerWidget {
  const _EmptySlotPanel();

  /// The slot never collapses below the height of a one-readout device panel.
  static const double minHeight = 150.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    // See the note on the "Add to profile" link: a `button` node with no
    // `enabled`/`onTap` is reported DISABLED even though the InkWell beneath
    // it works.
    return Semantics(
      button: true,
      enabled: true,
      label: 'Add rotator, dome, flat panel, weather',
      onTap: () => ref.read(discoveryScanRequestProvider.notifier).state++,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: SkotiqTokens.borderRadiusLg,
          onTap: () => ref.read(discoveryScanRequestProvider.notifier).state++,
          child: Container(
            constraints: const BoxConstraints(minHeight: minHeight),
            padding: SkotiqTokens.paddingLg,
            decoration: BoxDecoration(
              borderRadius: SkotiqTokens.borderRadiusLg,
              border: Border.all(color: colors.borderHighlight),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.plus,
                  size: SkotiqTokens.iconMd,
                  color: colors.textMuted,
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'Add rotator, dome, flat panel, weather…',
                  textAlign: TextAlign.center,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A centred empty state that scrolls when the device column is shorter than
/// its content, keeping the narrow-layout header and the discovery drawer
/// reachable while nothing is connected.
class _EquipmentEmptyState extends StatelessWidget {
  final Widget child;
  final Widget? header;
  final Widget? footer;

  const _EquipmentEmptyState({required this.child, this.header, this.footer});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (header != null) header!,
              // The banners and the sweep record ride ABOVE the empty state:
              // a sweep that connected nothing is precisely when its
              // per-device failures are the thing to read, and hiding them
              // with the grid left the operator an empty page and no reason.
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  SkotiqTokens.space2xl,
                  SkotiqTokens.spaceXl,
                  SkotiqTokens.space2xl,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RunDashboardRecoveryBanner(),
                    _ProfileMismatchBanner(),
                    _ConnectAllProgressStrip(),
                  ],
                ),
              ),
              Padding(
                padding: _bodyPadding,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    // The header has already consumed part of the viewport, so
                    // only the REMAINDER should be reserved for centring —
                    // otherwise the empty state pushes itself off the bottom.
                    minHeight: constraints.hasBoundedHeight && header == null
                        ? constraints.maxHeight - _bodyPadding.vertical
                        : 0,
                  ),
                  child: Center(child: child),
                ),
              ),
              if (footer != null) footer!,
            ],
          ),
        );
      },
    );
  }
}

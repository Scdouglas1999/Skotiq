import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Reusable device-picker step body shared between Camera / Mount /
/// Focuser / Filter Wheel / Guider onboarding steps.
///
/// Plugs into the real [unifiedDiscoveryProvider] so the listed devices
/// come from an actual discovery run (Native SDK / ASCOM / Alpaca /
/// INDI), not a fixture. The selected driver subset persisted in
/// [onboardingDraftProvider] gates which backends discovery runs against.
///
/// Why one widget for many device types: every device type has the same
/// "scan → list → pick → connect-optional" affordance. Cloning this five
/// times would diverge over time. The caller passes a [deviceType] and
/// callbacks for when the user picks/clears a device.
class OnboardingDevicePickerBody extends ConsumerStatefulWidget {
  const OnboardingDevicePickerBody({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.deviceType,
    required this.selectedDeviceId,
    required this.selectedDeviceName,
    required this.onSelected,
    required this.onCleared,
    this.allowSkip = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final DeviceType deviceType;
  final String? selectedDeviceId;
  final String? selectedDeviceName;
  final void Function(UnifiedDevice device) onSelected;
  final VoidCallback onCleared;

  /// True for steps that should render an explicit "Skip this device"
  /// affordance (focuser, filter wheel, guider).
  final bool allowSkip;

  @override
  ConsumerState<OnboardingDevicePickerBody> createState() =>
      _OnboardingDevicePickerBodyState();
}

class _OnboardingDevicePickerBodyState
    extends ConsumerState<OnboardingDevicePickerBody> {
  bool _scanRequested = false;

  /// Owned so the scrollbar can be pinned visible: `thumbVisibility` requires
  /// a controller shared with exactly one scroll view.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Kick discovery off the first time the step renders so the user
    // doesn't have to hit "Scan" on every step. We schedule it post-
    // frame because [_runDiscovery] reads providers — calling it during
    // the build/initState pass would error.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scanRequested) return;
      _runDiscovery();
    });
  }

  Future<void> _runDiscovery() async {
    if (!mounted) return;
    setState(() => _scanRequested = true);
    // discoverAll() pings every available backend. The discovery state
    // notifier batches the results so the rest of the UI updates as
    // each backend finishes — we don't need to await for individual
    // device types here.
    await ref.read(unifiedDiscoveryProvider.notifier).discoverAll();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final discovery = ref.watch(unifiedDiscoveryProvider);
    final draft = ref.watch(onboardingDraftProvider);

    // Filter the unified devices by:
    //   1. The requested DeviceType (camera/mount/etc.)
    //   2. The user's chosen driver subset (so a user who unchecked INDI
    //      doesn't see INDI-only devices in the list).
    final allDevices = discovery.getDevicesByType(widget.deviceType);
    final selectedDrivers = draft.selectedDrivers;
    final devices = allDevices.where((device) {
      // Keep the device if it has at least one backend in the user's
      // selected driver set; otherwise we'd surface a device the user
      // can't actually connect to.
      return device.availableBackends.keys.any(selectedDrivers.contains);
    }).toList();

    final isDiscovering = discovery.isDiscovering;

    // The picker is handed a FIXED height by the steps that embed it (the
    // filter-wheel step gives it 240 px so the slot editor has room). Its own
    // chrome is not fixed: a backend that fails adds an explanation block, and
    // on step 6 that pushed the header row straight through the footnote — two
    // sentences painted over each other at 1600x900. Scroll instead of
    // overflowing, and stretch to fill the box when there is room to.
    // ...and a box that scrolls must SAY it scrolls. With the two backend
    // failure lines present the just-selected device row was cut through the
    // middle of its subtitle glyphs, with no scrollbar, no fade and no bottom
    // border — it read as a rendering fault, on the one row the operator had
    // just chosen. An always-visible thumb is the affordance; the tile scrolls
    // itself into view (see [_DeviceTileState]) so the choice is never the
    // thing hidden below the fold.
    return LayoutBuilder(
      builder: (context, constraints) => Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scrollController,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
            ),
            child: _buildBody(
              context,
              colors: colors,
              devices: devices,
              selectedDrivers: selectedDrivers,
              discovery: discovery,
              isDiscovering: isDiscovering,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required SkotiqColors colors,
    required List<UnifiedDevice> devices,
    required Set<DriverType> selectedDrivers,
    required UnifiedDiscoveryState discovery,
    required bool isDiscovering,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(icon: widget.icon, title: widget.title),
        Text(
          widget.subtitle,
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // Scan controls
        Row(
          children: [
            SkotiqButton(
              icon: SkotiqIcons.refresh,
              label: isDiscovering ? 'Scanning...' : 'Scan again',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: isDiscovering ? null : _runDiscovery,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            if (widget.selectedDeviceId != null)
              SkotiqButton(
                icon: SkotiqIcons.close,
                label: 'Clear selection',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: widget.onCleared,
              ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // Per-backend status (so the user understands why some lists are
        // empty — e.g. INDI server unreachable).
        _BackendStatusRow(
          discovery: discovery,
          drivers: selectedDrivers,
          deviceType: widget.deviceType,
        ),

        const SizedBox(height: SkotiqTokens.spaceMd),

        // Device list. A minimum, not a slot: the surrounding box is a fixed
        // height that the chrome above can eat into, and a list laid out at
        // zero height is what put two sentences on one line.
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 96),
          child: _DeviceList(
            devices: devices,
            isDiscovering: isDiscovering,
            selectedDeviceId: widget.selectedDeviceId,
            onSelected: widget.onSelected,
          ),
        ),

        if (widget.allowSkip) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                SkotiqIcons.info,
                size: SkotiqTokens.iconXs,
                color: colors.textMuted,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'No matching device? You can skip this step and add it '
                  'later from the Equipment screen.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Endpoint (`host:port`) named anywhere inside a backend error, or null.
final RegExp _endpointPattern =
    RegExp(r'\b((?:[A-Za-z0-9_-]+\.)*[A-Za-z0-9_-]+:\d{2,5})\b');

/// Marks of a developer-facing dump rather than a sentence: an enum/constructor
/// call, a Dart/Rust error type, an errno, a URL, or a stack frame.
final RegExp _debugDebrisPattern = RegExp(
  r'\w+\.\w+\(|\w+Error\b|\w+Exception\b|os error|://|package:|#\d',
);

/// What to tell the operator about a backend that did not answer.
///
/// The raw string here is a driver/transport error — an enum dump, a URL, a
/// Rust error chain and an errno — which is what the log file is for, not copy
/// for the third screen of a first run.
///
/// So the raw text is never shown. Recognised transports get the sentence that
/// says what to DO about them, keeping the endpoint (the one part of the dump
/// the operator can act on); anything unrecognised falls back to a plain
/// statement that the scan did not complete.
@visibleForTesting
String describeBackendFailure(String? rawError) {
  final raw = rawError?.trim() ?? '';
  if (raw.isEmpty) return 'the scan did not complete';
  final lower = raw.toLowerCase();
  final endpoint = _endpointPattern.firstMatch(raw)?.group(1);
  final at = endpoint ?? 'that address';

  if (lower.contains('connection refused') || lower.contains('os error 111')) {
    return 'nothing is listening at $at';
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return '$at did not answer in time';
  }
  if (lower.contains('no route to host') ||
      lower.contains('network is unreachable') ||
      lower.contains('unreachable')) {
    return '$at could not be reached from this network';
  }
  if (lower.contains('name or service not known') ||
      lower.contains('failed to lookup') ||
      lower.contains('nodename nor servname') ||
      lower.contains('dns')) {
    return 'the address $at could not be resolved';
  }
  if (lower.contains('401') ||
      lower.contains('unauthorized') ||
      lower.contains('forbidden') ||
      lower.contains('403')) {
    return '$at refused the connection as unauthorised';
  }
  if (lower.contains('certificate') || lower.contains('handshake')) {
    return 'the secure connection to $at could not be established';
  }
  // Unrecognised transport. A backend that already reports a sentence ("No
  // Alpaca server answered on this network") keeps it — flattening that would
  // throw away the only thing anyone knows. Anything carrying developer debris
  // does not reach the operator at all.
  if (raw.length > 140 || _debugDebrisPattern.hasMatch(raw)) {
    return endpoint == null
        ? 'the scan did not complete'
        : 'the scan of $at did not complete';
  }
  return raw;
}

class _BackendStatusRow extends StatelessWidget {
  const _BackendStatusRow({
    required this.discovery,
    required this.drivers,
    required this.deviceType,
  });

  final UnifiedDiscoveryState discovery;
  final Set<DriverType> drivers;
  final DeviceType deviceType;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final entries =
        drivers.map((d) => MapEntry(d, discovery.backendStates[d])).toList();
    final failures = <String>[];

    final chips = entries.map((entry) {
      final driver = entry.key;
      final state = entry.value;
      IconData icon;
      ChipTone tone;
      String label = driver.shortLabel;
      // What a screen reader is told. A chip that publishes only its driver
      // name is indistinguishable from every other chip to assistive tech, so
      // the state goes in the description.
      String description;

      if (state == null) {
        icon = SkotiqIcons.circle;
        tone = ChipTone.neutral;
        description = '${driver.shortLabel}: not scanned yet';
      } else {
        switch (state.status) {
          case DiscoveryStatus.idle:
            icon = SkotiqIcons.circle;
            tone = ChipTone.neutral;
            description = '${driver.shortLabel}: not scanned yet';
            break;
          case DiscoveryStatus.discovering:
            icon = LucideIcons.loader;
            tone = ChipTone.primary;
            description = '${driver.shortLabel}: scanning';
            break;
          case DiscoveryStatus.completed:
            icon = LucideIcons.checkCircle2;
            tone = ChipTone.success;
            final matchingCount = state.devices
                .where((device) => device.deviceType == deviceType)
                .length;
            label = '${driver.shortLabel} ($matchingCount)';
            description = '${driver.shortLabel}: scan complete, '
                '$matchingCount found';
            break;
          case DiscoveryStatus.error:
            icon = SkotiqIcons.warning;
            tone = ChipTone.error;
            label = '${driver.shortLabel} (0)';
            description = '${driver.shortLabel}: nothing answered — '
                '${describeBackendFailure(state.error)}';
            failures.add(description);
            break;
        }
      }

      return Semantics(
        container: true,
        label: description,
        excludeSemantics: true,
        child: SkotiqTooltip(
          message: description,
          child: SkotiqChip(label: label, icon: icon, tone: tone),
        ),
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceXs,
          children: chips,
        ),
        // A red chip whose only explanation is a hover tooltip is an unexplained
        // alarm on the first run of a paid product. Say what happened where the
        // user is already looking.
        if (failures.isNotEmpty) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            failures.join('\n'),
            style: SkotiqTypography.bodySm.copyWith(color: colors.error),
          ),
        ],
      ],
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.devices,
    required this.isDiscovering,
    required this.selectedDeviceId,
    required this.onSelected,
  });

  final List<UnifiedDevice> devices;
  final bool isDiscovering;
  final String? selectedDeviceId;
  final void Function(UnifiedDevice device) onSelected;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      // Centred when there is room, scrollable when there is not. As a bare
      // Center this overflowed its Expanded slot wherever the picker is given a
      // short fixed height — on the guider step (a 240 px box) the "No devices
      // found" line painted straight through the "No matching device?" footnote
      // below it, leaving two sentences overprinted on one line.
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
            ),
            child: Center(
              child: EmptyState.compact(
                icon: isDiscovering
                    ? LucideIcons.loader
                    : SkotiqIcons.searchEmpty,
                title:
                    isDiscovering ? 'Scanning for devices' : 'No devices found',
                body: isDiscovering
                    ? null
                    : 'Make sure the device is connected and powered on, then '
                        'scan again.',
              ),
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      // The picker body scrolls as one; a second scrollable inside it would
      // fight the outer one for the same drag.
      physics: const NeverScrollableScrollPhysics(),
      itemCount: devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: SkotiqTokens.spaceSm),
      itemBuilder: (context, index) {
        final device = devices[index];
        // Selection match is done on activeDeviceId (the id of the
        // recommended backend) so re-selecting through "Use this device"
        // keeps the same backend the user previously chose.
        final isSelected = device.activeDeviceId == selectedDeviceId;
        return _DeviceTile(
          device: device,
          isSelected: isSelected,
          onSelected: () => onSelected(device),
        );
      },
    );
  }
}

/// One device row in the picker.
///
/// Stateful only to render a focus ring: the row is an [InkWell], so Tab
/// already reached it and Space already selected it, but InkWell paints its
/// focus highlight BEHIND the child and this row's opaque surface decoration
/// hid it completely. A keyboard user tabbing the device list saw nothing move
/// and had no way to tell which device Space would pick.
class _DeviceTile extends StatefulWidget {
  const _DeviceTile({
    required this.device,
    required this.isSelected,
    required this.onSelected,
  });

  final UnifiedDevice device;
  final bool isSelected;
  final VoidCallback onSelected;

  @override
  State<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<_DeviceTile> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    // Re-entering the step with a device already picked put the chosen row
    // below the fold of the fixed-height picker, half-drawn.
    if (widget.isSelected) _revealSelf();
  }

  @override
  void didUpdateWidget(_DeviceTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelected && !oldWidget.isSelected) _revealSelf();
  }

  /// Bring the chosen row fully inside the picker's viewport.
  void _revealSelf() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final position = Scrollable.maybeOf(context)?.position;
      if (position == null || !position.hasContentDimensions) return;
      Scrollable.ensureVisible(
        context,
        duration: SkotiqTokens.durationSmooth,
        curve: SkotiqTokens.curveStandard,
        alignment: 0.5,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final device = widget.device;
    final isSelected = widget.isSelected;

    // One accessible node for the row, declared as what it is: a radio in a
    // mutually-exclusive group.
    //
    // Read off the live accessibility tree during the GUI drive 2026-08-09, the
    // camera step's only device came out as:
    //
    //   panel: Simulated Camera
    //   Sim [DISABLED]
    //
    // — focusable, no selected state, announced as not enabled, on a row that
    // selects perfectly well with a click. A bare `InkWell` publishes a
    // tappable, focusable node that never sets `isEnabled`, and nothing in the
    // subtree carries the selection (it is drawn as an icon swap, which has no
    // semantics at all). So a screen-reader user is told the row is dead and is
    // never told which device is chosen.
    //
    // This tile is shared by the camera, mount, focuser, filter-wheel and guider
    // steps, so the same two untruths were on five of the thirteen onboarding
    // steps.
    return Semantics(
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: isSelected,
      selected: isSelected,
      enabled: true,
      label: '${device.displayName}. '
          '${device.availableBackends.keys.map((b) => b.shortLabel).join(' / ')}',
      onTap: widget.onSelected,
      child: InkWell(
        // The wrapper above is the accessible node; without this the
        // InkWell publishes a second, unflagged one and AT still reads
        // the control as disabled. Verified on the running app.
        excludeFromSemantics: true,
        onTap: widget.onSelected,
        onFocusChange: (value) {
          if (_focused == value) return;
          setState(() => _focused = value);
        },
        borderRadius: SkotiqTokens.borderRadiusSm,
        child: Container(
          foregroundDecoration: _focused
              ? BoxDecoration(
                  borderRadius: SkotiqTokens.borderRadiusSm,
                  border: Border.all(color: colors.primary, width: 2),
                )
              : null,
          padding: SkotiqTokens.paddingMd,
          // A `well` row inside the step panel; the selection is a `primary`
          // ring, not a second fill (05 §9).
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: SkotiqTokens.borderRadiusSm,
            border: Border.all(
              color: isSelected
                  ? colors.primary.withValues(
                      alpha: SkotiqTokens.opacitySelectedRing,
                    )
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? LucideIcons.checkCircle2 : SkotiqIcons.circle,
                color: isSelected ? colors.primary : colors.textMuted,
                size: SkotiqTokens.iconSm,
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName,
                      style: SkotiqTypography.bodyStrong.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      device.availableBackends.keys
                          .map((b) => b.shortLabel)
                          .join(' / '),
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

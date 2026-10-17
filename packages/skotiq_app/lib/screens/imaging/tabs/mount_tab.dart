import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        MountCapabilities,
        MountState,
        mountStateProvider,
        equipmentMountCapabilitiesProvider,
        gateCapability,
        slewCoordinatesProvider,
        CoordinateParser,
        CoordinateUtils,
        DeviceConnectionState;
import '../../../services/mount_command_service.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/slew_dropdown_button.dart';
import '../widgets/panel_widgets.dart';

/// The trailing half of [SlewDropdownButton]: a 4px gap and the popup that
/// opens the slew alternatives, which is an `IconButton` at Material's minimum
/// interactive size. It is not part of the label measurement, so a cell that
/// holds one has to reserve it or "Slew" is the label that ellipsises.
const double _slewMenuAffordance = 4 + kMinInteractiveDimension;

/// Side of one pulse-guide pad, and the resting gap between the west and east
/// pads (the cross's empty centre).
const double _pulsePadSize = 48;
const double _pulseCentreGap = 48;

/// The Mount section of the Imaging side panel.
class MountTab extends ConsumerStatefulWidget {
  const MountTab({super.key});

  @override
  ConsumerState<MountTab> createState() => _MountTabState();
}

class _MountTabState extends ConsumerState<MountTab> {
  // Slew target inputs - initialized from provider in initState
  late final TextEditingController _raController;
  late final TextEditingController _decController;

  @override
  void initState() {
    super.initState();
    // Initialize controllers from provider state synchronously
    final coords = ref.read(slewCoordinatesProvider);
    _raController = TextEditingController(text: coords.raText);
    _decController = TextEditingController(text: coords.decText);

    // Add listeners to sync changes back to provider (persists across tab
    // switches) and to rebuild this tab, so the Slew payload and the
    // enablement of Slew/Sync follow every keystroke.
    _raController.addListener(_syncRaToProvider);
    _decController.addListener(_syncDecToProvider);
  }

  void _syncRaToProvider() {
    final currentCoords = ref.read(slewCoordinatesProvider);
    if (currentCoords.raText != _raController.text) {
      ref.read(slewCoordinatesProvider.notifier).state =
          currentCoords.copyWith(raText: _raController.text);
    }
  }

  void _syncDecToProvider() {
    final currentCoords = ref.read(slewCoordinatesProvider);
    if (currentCoords.decText != _decController.text) {
      ref.read(slewCoordinatesProvider.notifier).state =
          currentCoords.copyWith(decText: _decController.text);
    }
  }

  @override
  void dispose() {
    _raController.removeListener(_syncRaToProvider);
    _decController.removeListener(_syncDecToProvider);
    _raController.dispose();
    _decController.dispose();
    super.dispose();
  }

  /// Sync mount to coordinates from text fields with validation
  Future<void> _handleSync() async {
    final ra = CoordinateParser.parseRa(_raController.text);
    final dec = CoordinateParser.parseDec(_decController.text);
    if (ra == null || dec == null) {
      context.showErrorSnackBar(
          "Invalid coordinates. Supported formats: decimal, HH:MM:SS, DD:MM:SS");
      return;
    }
    final result = await ref.read(mountCommandServiceProvider).sync(ra, dec);
    if (!mounted) return;
    context.showCommandActionResult(result);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final mountState = ref.watch(mountStateProvider);
    // Watch the persisted text state so validation and the command payload
    // rebuild on every edit. Reading only the TextEditingControllers inside a
    // Builder left the disabled/enabled state and captured coordinates stale.
    final slewCoordinates = ref.watch(slewCoordinatesProvider);
    final targetRa = CoordinateParser.parseRa(slewCoordinates.raText);
    final targetDec = CoordinateParser.parseDec(slewCoordinates.decText);
    final hasValidTarget = targetRa != null && targetDec != null;
    final isConnected =
        mountState.connectionState == DeviceConnectionState.connected;

    // Watch mount capabilities to gate UI features.
    //
    // Gated through the equipment capability provider which
    // returns a fail-closed boolean — a driver that refuses to report
    // `canPark` no longer ships a button that hits a "Not implemented"
    // path. While loading we keep buttons visible (`loadingDefault: true`)
    // so the UI does not flash empty on every tab switch.
    final mountCapsAsync = ref
        .watch(equipmentMountCapabilitiesProvider(mountState.deviceId ?? ''));
    final canPark = gateCapability<MountCapabilities>(
      mountCapsAsync,
      (c) => c.canPark,
      loadingDefault: true,
    );
    final canUnpark = gateCapability<MountCapabilities>(
      mountCapsAsync,
      (c) => c.canUnpark,
      loadingDefault: true,
    );
    final canSetTracking = gateCapability<MountCapabilities>(
      mountCapsAsync,
      (c) => c.canSetTracking,
      loadingDefault: true,
    );
    final canAbortSlew = gateCapability<MountCapabilities>(
      mountCapsAsync,
      (c) => c.canAbortSlew,
      loadingDefault: true,
    );
    final canSync = gateCapability<MountCapabilities>(
      mountCapsAsync,
      (c) => c.canSync,
      loadingDefault: false,
    );
    final canSlew = gateCapability<MountCapabilities>(
      mountCapsAsync,
      (c) => c.canSlew || c.canSlewAsync,
      loadingDefault: false,
    );
    final canPulseGuide = gateCapability<MountCapabilities>(
      mountCapsAsync,
      (c) => c.canPulseGuide,
      loadingDefault: false,
    );
    final mountCaps = mountCapsAsync.valueOrNull;
    final minimumPulseMs = mountCaps?.minPulseGuideMs?.ceil() ?? 1;
    final maximumPulseMs = mountCaps?.maxPulseGuideMs?.floor();
    final hasValidPulseRange = minimumPulseMs > 0 &&
        (maximumPulseMs == null || maximumPulseMs >= minimumPulseMs);
    var pulseDurationMs = 500;
    if (pulseDurationMs < minimumPulseMs) pulseDurationMs = minimumPulseMs;
    if (maximumPulseMs != null && pulseDurationMs > maximumPulseMs) {
      pulseDurationMs = maximumPulseMs;
    }
    final pulseControlsEnabled = isConnected &&
        canPulseGuide &&
        hasValidPulseRange &&
        !mountState.isParked &&
        !mountState.isSlewing;

    final parkLabel = mountState.isParked ? 'Unpark' : 'Park';
    final trackingLabel =
        mountState.isTracking ? 'Stop tracking' : 'Start tracking';

    return SingleChildScrollView(
      // Both hosts of this section — the SidePanel's content area and the
      // narrow bottom sheet — already inset it by 16 (05 §15). The 24 this
      // used to add on top, plus a card of its own at 16, spent 80 of the
      // panel's 320 px on nothing but air, which is most of the room a second
      // column of buttons needs.
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PanelSection(
            title: 'Mount status',
            colors: colors,
            child: _StatusBlock(
              mountState: mountState,
              isConnected: isConnected,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          PanelSection(
            title: 'Actions',
            colors: colors,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AdaptiveColumns(
                  cells: <AdaptiveCell>[
                    AdaptiveCell(
                      minWidth: SkotiqButton.measureWidth(
                        context,
                        label: parkLabel,
                        hasIcon: true,
                      ),
                      child: _LabelFirstButton(
                        label: parkLabel,
                        icon: LucideIcons.parkingSquare,
                        variant: ButtonVariant.secondary,
                        // Gate on canPark/canUnpark with
                        // fail-closed capability lookup — see
                        // gateCapability above.
                        onPressed: isConnected &&
                                !mountState.isSlewing &&
                                (mountState.isParked ? canUnpark : canPark)
                            ? () => ref
                                    .read(mountCommandServiceProvider)
                                    .togglePark()
                                    .then((result) {
                                  if (context.mounted) {
                                    context.showCommandActionResult(result);
                                  }
                                })
                            : null,
                      ),
                    ),
                    AdaptiveCell(
                      minWidth: SkotiqButton.measureWidth(
                        context,
                        label: trackingLabel,
                        hasIcon: true,
                      ),
                      child: _LabelFirstButton(
                        label: trackingLabel,
                        icon: SkotiqIcons.activity,
                        variant: mountState.isTracking
                            ? ButtonVariant.secondary
                            : ButtonVariant.primary,
                        // Gate on canSetTracking capability.
                        onPressed: isConnected &&
                                canSetTracking &&
                                !mountState.isParked &&
                                !mountState.isSlewing
                            ? () => ref
                                    .read(mountCommandServiceProvider)
                                    .setTracking(!mountState.isTracking)
                                    .then((result) {
                                  if (context.mounted) {
                                    context.showCommandActionResult(result);
                                  }
                                })
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                // The panic button keeps the full width in every layout and
                // takes the destructive face: it is the one control here the
                // operator reaches for without reading, and it must never
                // share a row with an ordinary action.
                _LabelFirstButton(
                  label: 'Abort slew',
                  icon: LucideIcons.octagon,
                  variant: ButtonVariant.destructive,
                  // Gate on canAbortSlew. Drivers without
                  // abort support would otherwise stall the user when
                  // a runaway slew demands the panic button.
                  onPressed: isConnected && canAbortSlew
                      ? () => ref
                              .read(mountCommandServiceProvider)
                              .abortSlew()
                              .then((result) {
                            if (context.mounted) {
                              context.showCommandActionResult(result);
                            }
                          })
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          PanelSection(
            title: 'Alignment',
            colors: colors,
            // "Polar alignment" is what the screen behind this button is
            // called everywhere else it is offered (the Sequencer toolbar, the
            // command palette). Three-point is the method chosen inside it,
            // not the name of the door.
            child: _LabelFirstButton(
              label: 'Polar alignment',
              icon: SkotiqIcons.compass,
              variant: ButtonVariant.secondary,
              onPressed: () => context.push('/polar-alignment'),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          PanelSection(
            title: 'Go to & sync',
            colors: colors,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Stacked, labelled fields: side by side, the labels became
                // "RA (H…" and "Dec (…", and a coordinate is exactly the kind
                // of value a reader has to be able to check digit by digit.
                SkotiqTextField(
                  label: 'RA',
                  hint: 'HH:MM:SS',
                  suffix: 'h',
                  mono: true,
                  controller: _raController,
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                SkotiqTextField(
                  label: 'Dec',
                  hint: '±DD:MM:SS',
                  suffix: '°',
                  mono: true,
                  controller: _decController,
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                AdaptiveColumns(
                  cells: <AdaptiveCell>[
                    AdaptiveCell(
                      minWidth: SkotiqButton.measureWidth(
                            context,
                            label: 'Slew',
                            hasIcon: true,
                          ) +
                          _slewMenuAffordance,
                      child: !hasValidTarget
                          ? const _LabelFirstButton(
                              label: 'Slew',
                              icon: SkotiqIcons.move,
                              onPressed: null,
                            )
                          : SlewDropdownButton(
                              ra: targetRa,
                              dec: targetDec,
                              targetName: 'Manual Coordinates',
                              // No rotation from manual coordinate entry
                              targetRotation: null,
                              isEnabled: isConnected &&
                                  canSlew &&
                                  !mountState.isParked &&
                                  !mountState.isSlewing,
                            ),
                    ),
                    AdaptiveCell(
                      minWidth: SkotiqButton.measureWidth(
                        context,
                        label: 'Sync',
                        hasIcon: true,
                      ),
                      child: _LabelFirstButton(
                        label: 'Sync',
                        icon: SkotiqIcons.refresh,
                        variant: ButtonVariant.secondary,
                        onPressed: isConnected &&
                                canSync &&
                                hasValidTarget &&
                                !mountState.isParked &&
                                !mountState.isSlewing
                            ? _handleSync
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          PanelSection(
            title: 'Pulse guide',
            colors: colors,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  !isConnected
                      ? 'Connect a mount to send guide corrections.'
                      : !canPulseGuide
                          ? 'Pulse guiding is unavailable for this mount.'
                          : !hasValidPulseRange
                              ? 'The mount reported an invalid pulse-duration range.'
                              : mountState.isParked
                                  ? 'Unpark the mount before pulse guiding.'
                                  : mountState.isSlewing
                                      ? 'Pulse guiding is disabled during a slew.'
                                      : '$pulseDurationMs ms correction pulses',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                _PulseCross(
                  enabled: pulseControlsEnabled,
                  onPulse: (direction) => ref
                      .read(mountCommandServiceProvider)
                      .pulseGuide(direction, durationMs: pulseDurationMs)
                      .then((result) {
                    if (context.mounted) {
                      context.showCommandActionResult(result);
                    }
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A button that would rather lose its icon than its label.
///
/// The glyph plus its gap is 22px of a 32px-tall control and says nothing the
/// words do not. Below the width the label needs, `SkotiqButton` spends
/// that 22px on the icon and ellipsises the words instead — which is how this
/// panel came to offer "U…" and "St…". The icon is therefore the part that
/// gives way, and only in the last few pixels: at the 320px side panel every
/// label here keeps its glyph.
class _LabelFirstButton extends StatelessWidget {
  const _LabelFirstButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.variant = ButtonVariant.primary,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final ButtonVariant variant;

  @override
  Widget build(BuildContext context) {
    final withIcon = SkotiqButton.measureWidth(
      context,
      label: label,
      hasIcon: true,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final fits =
            !constraints.hasBoundedWidth || constraints.maxWidth >= withIcon;
        return SkotiqButton(
          label: label,
          icon: fits ? icon : null,
          variant: variant,
          onPressed: onPressed,
        );
      },
    );
  }
}

/// The mount's readouts: a chip that says what it is doing, over a grid of
/// values that says where it is pointing.
class _StatusBlock extends StatelessWidget {
  const _StatusBlock({required this.mountState, required this.isConnected});

  final MountState mountState;
  final bool isConnected;

  /// The chip's copy and tone, in the order a reader cares about. Park state
  /// is NOT folded in here: it is its own readout in the grid below, and a
  /// parked mount that is also disconnected has to report the connection.
  ({String label, ChipTone tone}) get _status {
    if (!isConnected) return (label: 'Disconnected', tone: ChipTone.error);
    if (mountState.isSlewing) {
      return (label: 'Slewing', tone: ChipTone.warning);
    }
    if (mountState.isTracking) {
      return (label: 'Tracking', tone: ChipTone.success);
    }
    return (label: 'Stopped', tone: ChipTone.neutral);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SkotiqChip(label: status.label, tone: status.tone, dot: true),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _ReadoutPair(<(String, String?)>[
          // Mount RA is hours (0-24); render sexagesimal so astronomers read
          // HH MM SS rather than raw decimals.
          (
            'RA',
            mountState.ra == null
                ? null
                : CoordinateUtils.formatRA(mountState.ra!)
          ),
          // Mount Dec is degrees (-90..+90); render signed DMS.
          (
            'Dec',
            mountState.dec == null
                ? null
                : CoordinateUtils.formatDec(mountState.dec!)
          ),
        ]),
        const SizedBox(height: SkotiqTokens.spaceSm),
        _ReadoutPair(<(String, String?)>[
          (
            'Alt',
            mountState.altitude == null
                ? null
                : '${mountState.altitude!.toStringAsFixed(2)}°'
          ),
          (
            'Az',
            mountState.azimuth == null
                ? null
                : '${mountState.azimuth!.toStringAsFixed(2)}°'
          ),
        ]),
        const SizedBox(height: SkotiqTokens.spaceSm),
        _ReadoutPair(<(String, String?)>[
          ('Pier', mountState.sideOfPier),
          ('Status', mountState.isParked ? 'Parked' : 'Ready'),
        ]),
      ],
    );
  }
}

/// One row of the status grid: two readouts side by side while both values fit
/// at the mono readout size, stacked as soon as one of them does not.
///
/// A sexagesimal RA is 13 characters wide, which two columns of a 320px panel
/// cannot hold — and half a coordinate is not a coordinate, so this row gives
/// up the pairing rather than the digits.
class _ReadoutPair extends StatelessWidget {
  const _ReadoutPair(this.values);

  final List<(String, String?)> values;

  @override
  Widget build(BuildContext context) {
    return AdaptiveColumns(
      spacing: SkotiqTokens.spaceMd,
      cells: <AdaptiveCell>[
        for (final (String label, String? value) in values)
          AdaptiveCell(
            minWidth: math.max(
              measureTextWidth(
                context,
                text: value ?? kReadoutUnknown,
                style: SkotiqTypography.readoutSm,
              ),
              measureTextWidth(
                context,
                text: label.toUpperCase(),
                style: SkotiqTypography.readoutLabel,
              ),
            ),
            child: Readout(
              label: label,
              value: value,
              size: ReadoutSize.sm,
            ),
          ),
      ],
    );
  }
}

/// The four pulse-guide pads, laid out as the compass cross they are.
class _PulseCross extends StatelessWidget {
  const _PulseCross({required this.enabled, required this.onPulse});

  final bool enabled;
  final ValueChanged<String> onPulse;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _PulseButton(
          icon: SkotiqIcons.chevronUp,
          label: 'N',
          onPressed: enabled ? () => onPulse('north') : null,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _PulseButton(
              icon: SkotiqIcons.chevronLeft,
              label: 'W',
              onPressed: enabled ? () => onPulse('west') : null,
            ),
            // The cross's centre is the one part of this cluster that may
            // shrink: the pads themselves are touch targets. Flexible lets the
            // gap close before anything overflows the card.
            const Flexible(child: SizedBox(width: _pulseCentreGap)),
            _PulseButton(
              icon: SkotiqIcons.chevronRight,
              label: 'E',
              onPressed: enabled ? () => onPulse('east') : null,
            ),
          ],
        ),
        _PulseButton(
          icon: SkotiqIcons.chevronDown,
          label: 'S',
          onPressed: enabled ? () => onPulse('south') : null,
        ),
      ],
    );
  }
}

class _PulseButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _PulseButton(
      {required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final enabled = onPressed != null;
    return Column(
      children: [
        Material(
          color: colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            child: Container(
              width: _pulsePadSize,
              height: _pulsePadSize,
              alignment: Alignment.center,
              child: Icon(
                icon,
                color: enabled ? colors.primary : colors.textMuted,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary)),
      ],
    );
  }
}

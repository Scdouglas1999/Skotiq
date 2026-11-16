import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../device_connection_mixin.dart';
import '../../../utils/device_type_ui.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/troubleshooter/connection_troubleshooter_dialog.dart';
import '../dialogs/fujifilm_disclaimer_dialog.dart';
import '../profile_actions.dart';
import '../utils/profile_mutation_epoch.dart';

part 'discovery_panel/device_row_item.dart';

class AssignAction {
  /// [profileId] of the menu entry that makes a new profile for the device.
  static const int newProfile = -1;

  final int profileId;
  final DeviceType deviceType;

  const AssignAction({
    required this.profileId,
    required this.deviceType,
  });
}

/// Bumped by the page header's "Scan for devices" primary. The drawer listens,
/// expands and runs the SAME scan its own button runs — the screen has one
/// primary action and one scan code path, not two that can drift.
final discoveryScanRequestProvider = StateProvider<int>((ref) => 0);

/// The drawer at the foot of Equipment > Devices: every device the imaging
/// host knows about (connected, named by the active profile, or found by the
/// last scan) with its state, and Scan to look for new ones.
class DiscoveryPanel extends ConsumerStatefulWidget {
  final ValueChanged<(DeviceInfo, int)>? onAssignDevice;

  const DiscoveryPanel({super.key, this.onAssignDevice});

  @override
  ConsumerState<DiscoveryPanel> createState() => _DiscoveryPanelState();

  /// Derives the troubleshooter inputs from the backend the user actually tried
  /// to connect and shows [ConnectionTroubleshooterDialog], resolving to `true`
  /// when the user asked to retry.
  ///
  /// Exposed for testing so the connect-failure → troubleshooter orchestration
  /// can be exercised directly without standing up the full discovery panel and
  /// its device-state providers. The caller is responsible for the `mounted`
  /// guards around the (async) dialog.
  /// Resolves the namespaced [DriverType] for the backend the user actually
  /// tried to connect, so the troubleshooter playbook is protocol-aware.
  ///
  /// `availableBackends` may not contain the resolved key in pathological
  /// cases, so we fall back to the backend identity itself rather than
  /// guessing. This is the authoritative resolution for the discovery surface
  /// (more accurate than deriving the driver from the device-id prefix), and it
  /// is shared by both the inline connect path and the test-only
  /// [showConnectionTroubleshooter] entry point.
  @visibleForTesting
  static DriverType resolveDriverType(UnifiedDevice device) {
    final backend = device.selectedBackend ?? device.recommendedBackend;
    final info = device.availableBackends[backend];
    return info?.driverType ?? backend;
  }

  @visibleForTesting
  static Future<bool> showConnectionTroubleshooter(
    BuildContext context,
    UnifiedDevice device,
    Object error,
  ) {
    return ConnectionTroubleshooterDialog.show(
      context,
      deviceType: device.type,
      driverType: resolveDriverType(device),
      rawError: error.toString(),
    );
  }
}

class _DiscoveryPanelState extends ConsumerState<DiscoveryPanel>
    with SingleTickerProviderStateMixin, DeviceConnectionMixin {
  bool _isExpanded = false;
  bool _isScanning = false;
  // True while the Rust-side manual hot-plug rescan is running. Kept
  // separate from `_isScanning` (the full Dart-side unified discovery)
  // because the two actions have different latencies and we don't want
  // the "Rescanning..." spinner blocking the much longer "Scan All".
  bool _isRescanning = false;

  /// The scan or rescan in progress; a host change drops it.
  late final _operations = ref.backendScopes(alive: () => mounted);
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  late AnimationController _expandController;
  late Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next)) return;
        _operations.cancelAll();
        if (mounted && (_isScanning || _isRescanning)) {
          setState(() {
            _isScanning = false;
            _isRescanning = false;
          });
        }
      },
    );
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _expandAnimation = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    _expandController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _expandController.forward();
      } else {
        _expandController.reverse();
      }
    });
  }

  Future<void> _scanForDevices() async {
    if (_isScanning || _isRescanning) return;
    final scan = _operations.beginLatest();
    setState(() => _isScanning = true);
    try {
      await ref.read(unifiedDiscoveryProvider.notifier).discoverAll();
    } catch (e) {
      if (mounted && _isCurrentOperation(scan, scanning: true)) {
        context
            .showErrorSnackBar('Equipment scan failed: ${userFacingError(e)}');
      }
    } finally {
      if (_isCurrentOperation(scan, scanning: true)) {
        setState(() => _isScanning = false);
      }
    }
  }

  /// Trigger the host-side hot-plug diff pass.
  ///
  /// This is the lightweight cousin of `_scanForDevices`. The bridge polls
  /// the device lists after each OS device-change event
  /// (`bridge/src/hotplug.rs`) and on no timer, so Rescan is how a change
  /// the OS does not signal (an ASCOM driver install, a serial adapter, a
  /// quirky hub) is found. Arrival / removal events flow over the equipment
  /// event stream and refresh the device lists without a full backend scan.
  ///
  /// Routed through [DeviceBackend.rescanDevices] rather than calling the
  /// `bridge_api` FFI directly so it reaches the backend that actually owns
  /// the hardware buses. On a remote client (phone) a direct FFI call would
  /// rescan the phone's empty local backend and falsely report success; the
  /// backend op POSTs to the HOST instead. On the desktop host the same op
  /// resolves to the FfiBackend and drives the local hot-plug pass unchanged.
  Future<void> _rescanEquipment() async {
    if (_isRescanning || _isScanning) return;
    final rescan = _operations.beginLatest();
    setState(() => _isRescanning = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await rescan.value.rescanDevices();
      if (mounted && _isCurrentOperation(rescan, rescanning: true)) {
        context.showSuccessSnackBar('Equipment rescan complete');
      }
    } catch (e) {
      // A failed rescan must say so: silence here is indistinguishable from a
      // scan that ran and found nothing.
      if (_isCurrentOperation(rescan, rescanning: true)) {
        messenger?.showErrorSnackBar('Rescan failed: ${userFacingError(e)}');
      }
    } finally {
      if (_isCurrentOperation(rescan, rescanning: true)) {
        setState(() => _isRescanning = false);
      }
    }
  }

  bool _isCurrentOperation(
    AsyncScope<SkotiqBackend> operation, {
    bool scanning = false,
    bool rescanning = false,
  }) =>
      operation.isCurrent &&
      (!scanning || _isScanning) &&
      (!rescanning || _isRescanning);

  /// "7 devices · Last scan 21:52"; each half only when it says something,
  /// and null when neither does. Each row says whether it is connected.
  String? _summary(KnownDevices? known) {
    if (known == null) return null;
    final lastScanAt = known.lastScanAt;
    final parts = [
      if (known.devices.isNotEmpty)
        known.devices.length == 1
            ? '1 device'
            : '${known.devices.length} devices',
      if (lastScanAt != null)
        'Last scan ${ClockFormat.hmOrMonthDayHm(
          lastScanAt.toLocal(),
          ref.read(clockProvider).instant,
        )}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    // The page header's "Scan for devices" is this screen's single primary, so
    // it drives the same scan this drawer runs — one code path, two entries.
    ref.listen<int>(discoveryScanRequestProvider, (previous, next) {
      if (previous == null || previous == next) return;
      if (!_isExpanded) _toggleExpanded();
      unawaited(_scanForDevices());
    });

    final colors = SkotiqColors.of(context);
    final known = ref.watch(knownDevicesProvider);
    final isDiscovering =
        ref.watch(unifiedDiscoveryProvider.select((s) => s.isDiscovering)) ||
            _isScanning;

    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeadRow(
            colors,
            summary: _summary(known.valueOrNull),
            isDiscovering: isDiscovering,
          ),
          // Flexible(loose): under a tight parent this section takes the
          // remaining height and scrolls inside, instead of insisting on its
          // intrinsic size and overflowing the drawer.
          Flexible(
            child: SizeTransition(
              sizeFactor: _expandAnimation,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  SkotiqTokens.space2xl,
                  0,
                  SkotiqTokens.space2xl,
                  SkotiqTokens.spaceMd,
                ),
                child: switch (known) {
                  AsyncValue(valueOrNull: final list?) => list.devices.isEmpty
                      ? _buildNothingKnown(isDiscovering)
                      : _buildDeviceColumns(list.devices),
                  AsyncValue(error: final error?) => EmptyState.error(
                      title: 'Could not read the devices',
                      body: userFacingError(error),
                      onRetry: () => ref.invalidate(knownDevicesProvider),
                    ),
                  _ => const Padding(
                      padding: EdgeInsets.all(SkotiqTokens.spaceLg),
                      child: Center(child: SkotiqSpinner()),
                    ),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `[radio] [KNOWN DEVICES] [7 devices · Last scan 21:52] … [Rescan] [Scan all] [v]`
  ///
  /// On a phone the eyebrow, the summary and two labelled buttons do not fit
  /// 312 px — measured, the row overflowed by 243 px. Below
  /// [_discoveryHeadCompactWidth] the summary sits under the eyebrow and the
  /// two scans become icon buttons with the same tooltips.
  Widget _buildHeadRow(
    SkotiqColors colors, {
    required String? summary,
    required bool isDiscovering,
  }) {
    return SizedBox(
      // 06's 44 px is a POINTER height. It is a tight constraint, so on a
      // phone it squeezed the row's three icon buttons — Rescan, Scan all and
      // the expand chevron — to 48x44 and they failed the Android 48 dp
      // tap-target floor; each one grows its own interactive box to 48, but a
      // Row can only hand down the height it was given.
      height: math.max(
        _discoveryHeadHeight,
        SkotiqTouchTarget.minExtent(context),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.space2xl,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.hasBoundedWidth &&
                constraints.maxWidth < _discoveryHeadCompactWidth;
            final eyebrow = Text(
              'Known devices'.toUpperCase(),
              style: SkotiqTypography.eyebrow.copyWith(
                color: colors.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
            final summaryText = summary == null
                ? null
                : Text(
                    summary,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
            return Row(
              children: [
                // The label and the summary share ONE Expanded, and there is
                // no Spacer: a Flexible child beside a Spacer splits the row's
                // slack three ways, which truncated the label in a 652 px row
                // it fits twice over.
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.radio,
                        size: SectionTitle.iconSize,
                        color: colors.textMuted,
                      ),
                      const SizedBox(width: SkotiqTokens.spaceSm + 2),
                      if (compact)
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              eyebrow,
                              if (summaryText != null) summaryText
                            ],
                          ),
                        )
                      else ...[
                        Flexible(child: eyebrow),
                        if (summaryText != null) ...[
                          const SizedBox(width: SkotiqTokens.spaceMd),
                          Flexible(child: summaryText),
                        ],
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                if (compact)
                  SkotiqIconButton(
                    icon: LucideIcons.refreshCw,
                    tooltip: 'Rescan',
                    size: IconButtonSize.sm,
                    onPressed: (_isRescanning || isDiscovering)
                        ? null
                        : _rescanEquipment,
                  )
                else
                  SkotiqButton(
                    label: 'Rescan',
                    icon: LucideIcons.refreshCw,
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                    isLoading: _isRescanning,
                    onPressed: (_isRescanning || isDiscovering)
                        ? null
                        : _rescanEquipment,
                  ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                if (compact)
                  SkotiqIconButton(
                    icon: LucideIcons.search,
                    tooltip: isDiscovering ? 'Scanning' : 'Scan all',
                    size: IconButtonSize.sm,
                    onPressed: (isDiscovering || _isRescanning)
                        ? null
                        : _scanForDevices,
                  )
                else
                  SkotiqButton(
                    label: isDiscovering ? 'Scanning' : 'Scan all',
                    icon: LucideIcons.search,
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                    isLoading: isDiscovering,
                    onPressed: (isDiscovering || _isRescanning)
                        ? null
                        : _scanForDevices,
                  ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                SkotiqIconButton(
                  icon: _isExpanded
                      ? LucideIcons.chevronDown
                      : LucideIcons.chevronUp,
                  tooltip: _isExpanded ? 'Collapse' : 'Expand',
                  size: IconButtonSize.sm,
                  onPressed: _toggleExpanded,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The known devices in two columns, per 06 §Equipment.
  Widget _buildDeviceColumns(List<KnownDevice> devices) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth >= _discoveryTwoColumnWidth ? 2 : 1;
        final perColumn = (devices.length / columns).ceil();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var column = 0; column < columns; column++) ...[
              if (column > 0) const SizedBox(width: _discoveryColumnGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = column * perColumn;
                        i < (column + 1) * perColumn && i < devices.length;
                        i++)
                      _DeviceRowItem(
                        known: devices[i],
                        onConnect: () => _connectDevice(devices[i].device),
                        onDisconnect: () =>
                            _disconnectDevice(devices[i].device),
                        onAssignDevice: widget.onAssignDevice,
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The drawer before the host knows any device. After a scan it names
  /// which backends were asked and which of them failed.
  Widget _buildNothingKnown(bool isDiscovering) {
    final discoveryState = ref.watch(unifiedDiscoveryProvider);
    final searched = discoveryState.backendStates.keys.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final failed = discoveryState.errorBackends.toSet();
    final where =
        ref.watch(isRemoteModeProvider) ? 'the host' : 'this computer';

    final String title;
    final String detail;
    if (searched.isEmpty) {
      title = isDiscovering ? 'Scanning' : 'No devices yet';
      detail = 'Scan looks for the devices $where can reach.';
    } else {
      title = isDiscovering ? 'Scanning' : 'No devices found';
      final names = searched.map((b) {
        final label = b.displayName;
        return failed.contains(b) ? '$label (failed)' : label;
      }).join(', ');
      detail = 'Searched: $names.';
    }

    return EmptyState(
      icon: LucideIcons.radio,
      title: title,
      body: '$detail Devices on another machine are reached over Alpaca or '
          'INDI. Set the server address in Settings.',
      action: SkotiqButton(
        label: 'Scan all',
        icon: LucideIcons.search,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        isLoading: isDiscovering,
        onPressed: isDiscovering ? null : _scanForDevices,
      ),
    );
  }

  Future<void> _connectDevice(UnifiedDevice device) async {
    final deviceService = ref.read(deviceServiceProvider);
    final deviceId = device.activeDeviceId;

    // Fujifilm warranty disclaimer check — must clear before we attempt the
    // connection, so it stays out of the shared mixin connect path.
    if (device.type == DeviceType.camera &&
        isFujifilmDevice(deviceId, device.displayName)) {
      final accepted = await showFujifilmDisclaimerIfNeeded(context);
      if (!accepted) return;
    }

    // Route through the shared [DeviceConnectionMixin.connectDevice] so the
    // guided troubleshooter recovery (bounded single retry, raw error carried
    // verbatim into the dialog's "Technical details") is the one canonical
    // connect path for the equipment surfaces — not a fork duplicated here.
    //
    // We pass the backend-resolved [DriverType] (more accurate than the mixin's
    // device-id-prefix fallback) and the device type so the opt-in
    // troubleshooter branch fires. The per-type connect dispatch lives in
    // [connectFn]; the success toast lives in [onConnected] so it only fires on
    // a genuinely successful connection.
    await connectDevice(
      deviceId: deviceId,
      deviceName: device.displayName,
      deviceType: device.type,
      driverType: DiscoveryPanel.resolveDriverType(device),
      connectFn: (id) => deviceService.connect(device.type, id),
      onConnected: () async {
        if (mounted) {
          _announce('Connected to ${device.displayName}');
        }
      },
    );
  }

  /// Shows a device-state toast, dropping any earlier one still on screen.
  ///
  /// Snackbars queue, and this row's buttons can be pressed far faster than a
  /// snackbar's dwell time: hammering Connect/Disconnect left the bar replaying
  /// stale messages for eight seconds after the last click, so the window read
  /// "Disconnected camera" while the same frame showed the camera connected at
  /// 20.0 degrees. Only the newest statement about a device can be true.
  void _announce(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    context.showSuccessSnackBar(message);
  }

  Future<void> _disconnectDevice(UnifiedDevice device) async {
    final deviceService = ref.read(deviceServiceProvider);
    final deviceType = device.type;

    try {
      await deviceService.disconnect(deviceType);
      if (mounted) {
        _announce('Disconnected ${device.displayName}');
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar(
            'Failed to disconnect ${device.displayName}: ${userFacingError(e)}');
      }
    }
  }
}

/// The drawer's head row height, per 06 §Equipment.
const double _discoveryHeadHeight = 44.0;

/// Gap between the drawer's two device columns (mockup: 32).
const double _discoveryColumnGap = SkotiqTokens.space3xl;

/// Below this the drawer drops to a single column.
const double _discoveryTwoColumnWidth = 760.0;

/// Below this the head row drops its summary and shrinks the two scans to
/// icons, so a 360 dp phone does not overflow it.
const double _discoveryHeadCompactWidth = 520.0;

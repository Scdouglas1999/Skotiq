import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../mixins/device_connection_mixin.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/troubleshooter/connection_troubleshooter_dialog.dart';
import '../dialogs/fujifilm_disclaimer_dialog.dart';

part 'discovery_panel/device_row_item.dart';

/// Action for assigning a device to a profile
class AssignAction {
  final int profileId;
  final DeviceType deviceType;

  const AssignAction({
    required this.profileId,
    required this.deviceType,
  });
}

/// Provider to track when the last scan occurred
// autoDispose: the "last scan: N seconds ago" label is only meaningful while
// the Equipment screen is mounted. Resetting on screen teardown avoids
// stale "last scan: 6 hours ago" strings from a previous session.
final lastScanTimeProvider =
    StateProvider.autoDispose<DateTime?>((ref) => null);

/// Bumped by the page header's "Scan for devices" primary. The drawer listens,
/// expands and runs the SAME scan its own button runs — the screen has one
/// primary action and one scan code path, not two that can drift.
final discoveryScanRequestProvider = StateProvider<int>((ref) => 0);

/// A collapsible panel at the bottom of the equipment screen for discovering devices.
/// Shows available backends, discovered devices grouped by type, and connection controls.
class DiscoveryPanel extends ConsumerStatefulWidget {
  /// Optional callback when a device is assigned to a profile
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
    with
        SingleTickerProviderStateMixin,
        DeviceConnectionMixin,
        WidgetsBindingObserver {
  bool _isExpanded = false;
  bool _isScanning = false;
  // True while the Rust-side manual hot-plug rescan is running. Kept
  // separate from `_isScanning` (the full Dart-side unified discovery)
  // because the two actions have different latencies and we don't want
  // the "Rescanning..." spinner blocking the much longer "Scan All".
  bool _isRescanning = false;
  int _operationGeneration = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  late AnimationController _expandController;
  late Animation<double> _expandAnimation;
  // 30s tick refreshes the "Last scan: N seconds ago" label. Suspended when
  // the app is backgrounded so a hidden equipment tab doesn't tick.
  Timer? _lastScanTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next)) return;
        _operationGeneration++;
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
    _startLastScanTimer();
  }

  void _startLastScanTimer() {
    _lastScanTimer?.cancel();
    _lastScanTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_lastScanTimer == null || !_lastScanTimer!.isActive) {
        if (mounted) setState(() {});
        _startLastScanTimer();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _lastScanTimer?.cancel();
      _lastScanTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _operationGeneration++;
    _backendSubscription?.close();
    _expandController.dispose();
    _lastScanTimer?.cancel();
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
    final authority = ref.read(backendProvider);
    final generation = ++_operationGeneration;
    setState(() => _isScanning = true);
    try {
      // discoverAll clears stale grouped results before scanning.
      await ref.read(unifiedDiscoveryProvider.notifier).discoverAll();
      if (_isCurrentOperation(generation, authority, scanning: true)) {
        final completedAt =
            ref.read(unifiedDiscoveryProvider).lastDiscoveryCompletedAt;
        ref.read(lastScanTimeProvider.notifier).state =
            completedAt ?? DateTime.now();
      }
    } catch (e) {
      if (mounted &&
          _isCurrentOperation(generation, authority, scanning: true)) {
        context.showErrorSnackBar('Equipment scan failed: $e');
      }
    } finally {
      if (_isCurrentOperation(generation, authority, scanning: true)) {
        setState(() => _isScanning = false);
      }
    }
  }

  /// Trigger the host-side hot-plug diff pass.
  ///
  /// This is the lightweight cousin of `_scanForDevices`. The Rust bridge
  /// has a hybrid hot-plug architecture (`bridge/src/hotplug.rs`):
  ///   * Kernel-event listener (WM_DEVICECHANGE / libusb hotplug) for
  ///     sub-second USB arrival latency.
  ///   * 30 s slow poll catching ASCOM-registry / serial-port changes.
  /// Pressing Rescan forces an off-cadence diff cycle for users who plug
  /// in a device the kernel didn't surface (quirky hub, ASCOM driver
  /// install, etc.). Arrival / removal events flow over the equipment
  /// event stream and trigger the unified discovery provider to refresh
  /// without a full backend scan.
  ///
  /// Routed through [DeviceBackend.rescanDevices] rather than calling the
  /// `bridge_api` FFI directly so it reaches the backend that actually owns
  /// the hardware buses. On a remote client (phone) a direct FFI call would
  /// rescan the phone's empty local backend and falsely report success; the
  /// backend op POSTs to the HOST instead. On the desktop host the same op
  /// resolves to the FfiBackend and drives the local hot-plug pass unchanged.
  Future<void> _rescanEquipment() async {
    if (_isRescanning || _isScanning) return;
    final authority = ref.read(backendProvider);
    final backend = ref.read(deviceBackendProvider);
    final generation = ++_operationGeneration;
    setState(() => _isRescanning = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await backend.rescanDevices();
      if (mounted &&
          _isCurrentOperation(generation, authority, rescanning: true) &&
          identical(ref.read(deviceBackendProvider), backend)) {
        context.showSuccessSnackBar('Equipment rescan complete');
      }
    } catch (e) {
      // A failed rescan must say so: silence here is indistinguishable from a
      // scan that ran and found nothing.
      if (_isCurrentOperation(generation, authority, rescanning: true)) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Rescan failed: $e')),
        );
      }
    } finally {
      if (_isCurrentOperation(generation, authority, rescanning: true)) {
        setState(() => _isRescanning = false);
      }
    }
  }

  bool _isCurrentOperation(
    int generation,
    SkotiqBackend authority, {
    bool scanning = false,
    bool rescanning = false,
  }) =>
      mounted &&
      generation == _operationGeneration &&
      identical(ref.read(backendProvider), authority) &&
      (!scanning || _isScanning) &&
      (!rescanning || _isRescanning);

  String _formatLastScanTime(DateTime? lastScan) {
    if (lastScan == null) return 'Never scanned';

    final now = DateTime.now();
    final difference = now.difference(lastScan);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      final mins = difference.inMinutes;
      return '$mins min${mins == 1 ? '' : 's'} ago';
    } else if (difference.inHours < 24) {
      final hours = difference.inHours;
      return '$hours hour${hours == 1 ? '' : 's'} ago';
    } else {
      return 'Over a day ago';
    }
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
    final discoveryState = ref.watch(unifiedDiscoveryProvider);
    final lastScanTime = ref.watch(lastScanTimeProvider);
    final devices = discoveryState.groupedDevices;
    final isDiscovering = discoveryState.isDiscovering || _isScanning;
    final discoveryCompletedAt = discoveryState.lastDiscoveryCompletedAt;

    final lastScanText = _formatLastScanTime(
      lastScanTime ?? discoveryCompletedAt,
    );

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
            found: devices.length,
            lastScanText: lastScanText,
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
                child: devices.isEmpty
                    ? _buildNothingFound(colors, isDiscovering)
                    : _buildDeviceColumns(devices),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `[radio] [DISCOVERED DEVICES] [11 found · scanned 2 min ago] … [Rescan] [v]`
  ///
  /// On a phone the eyebrow, the summary and two labelled buttons do not fit
  /// 312 px — measured, the row overflowed by 243 px. Below
  /// [_discoveryHeadCompactWidth] the summary drops (it is repeated in the
  /// rows beneath) and the two scans become icon buttons with the same
  /// tooltips.
  Widget _buildHeadRow(
    SkotiqColors colors, {
    required int found,
    required String lastScanText,
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
            return Row(
              children: [
                // The label and the summary share ONE Expanded, and there is
                // no Spacer: a Flexible child beside a Spacer splits the row's
                // slack three ways, which truncated the label to
                // "DISCOVERED DEVIC…" in a 652 px row it fits twice over.
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.radio,
                        size: SectionTitle.iconSize,
                        color: colors.textMuted,
                      ),
                      const SizedBox(width: SkotiqTokens.spaceSm + 2),
                      Flexible(
                        child: Text(
                          'Discovered devices'.toUpperCase(),
                          style: SkotiqTypography.eyebrow.copyWith(
                            color: colors.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: SkotiqTokens.spaceMd),
                        Flexible(
                          child: Text(
                            '$found found · $lastScanText',
                            style: SkotiqTypography.caption.copyWith(
                              color: colors.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
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

  /// The discovered devices in two columns, per 06 §Equipment.
  Widget _buildDeviceColumns(List<UnifiedDevice> devices) {
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
                        device: devices[i],
                        deviceType: devices[i].type,
                        onConnect: () => _connectDevice(devices[i]),
                        onDisconnect: () => _disconnectDevice(devices[i]),
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

  /// ONE empty state, carrying the thing the bare "No devices found" withheld:
  /// which backends were asked and which of them failed.
  Widget _buildNothingFound(SkotiqColors colors, bool isDiscovering) {
    final discoveryState = ref.watch(unifiedDiscoveryProvider);
    final searched = discoveryState.backendStates.keys.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final failed = discoveryState.errorBackends.toSet();

    final String detail;
    if (searched.isEmpty) {
      detail = 'Nothing has been searched yet.';
    } else {
      final names = searched.map((b) {
        final label = b.displayName;
        return failed.contains(b) ? '$label (failed)' : label;
      }).join(', ');
      detail = 'Searched: $names.';
    }

    return EmptyState(
      icon: LucideIcons.radio,
      title: isDiscovering ? 'Scanning' : 'No devices found',
      body: '$detail Devices on another machine are reached over Alpaca or '
          'INDI — set the server address in Settings.',
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
      connectFn: (id) => _dispatchConnect(deviceService, device.type, id),
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

  /// Per-device-type connect dispatch shared by the discovery connect path.
  /// Throws for unsupported types so the mixin surfaces the failure through the
  /// troubleshooter rather than silently no-op'ing (errors-are-a-feature).
  Future<void> _dispatchConnect(
    DeviceService deviceService,
    DeviceType type,
    String deviceId,
  ) {
    switch (type) {
      case DeviceType.camera:
        return deviceService.connectCamera(deviceId);
      case DeviceType.mount:
        return deviceService.connectMount(deviceId);
      case DeviceType.focuser:
        return deviceService.connectFocuser(deviceId);
      case DeviceType.filterWheel:
        return deviceService.connectFilterWheel(deviceId);
      case DeviceType.guider:
        return deviceService.connectGuider(deviceId);
      case DeviceType.rotator:
        return deviceService.connectRotator(deviceId);
      case DeviceType.dome:
        return deviceService.connectDome(deviceId);
      case DeviceType.weather:
        return deviceService.connectWeather(deviceId);
      case DeviceType.safetyMonitor:
        return deviceService.connectSafetyMonitor(deviceId);
      case DeviceType.coverCalibrator:
        return deviceService.connectCoverCalibrator(deviceId);
      case DeviceType.switch_:
        return deviceService.connectSwitch(deviceId);
    }
  }

  Future<void> _disconnectDevice(UnifiedDevice device) async {
    final deviceService = ref.read(deviceServiceProvider);
    final deviceType = device.type;

    try {
      switch (deviceType) {
        case DeviceType.camera:
          await deviceService.disconnectCamera();
          break;
        case DeviceType.mount:
          await deviceService.disconnectMount();
          break;
        case DeviceType.focuser:
          await deviceService.disconnectFocuser();
          break;
        case DeviceType.filterWheel:
          await deviceService.disconnectFilterWheel();
          break;
        case DeviceType.guider:
          await deviceService.disconnectGuider();
          break;
        case DeviceType.rotator:
          await deviceService.disconnectRotator();
          break;
        case DeviceType.dome:
          await deviceService.disconnectDome();
          break;
        case DeviceType.weather:
          await deviceService.disconnectWeather();
          break;
        case DeviceType.safetyMonitor:
          await deviceService.disconnectSafetyMonitor();
          break;
        case DeviceType.coverCalibrator:
          await deviceService.disconnectCoverCalibrator();
          break;
        case DeviceType.switch_:
          await deviceService.disconnectSwitch();
          break;
      }
      if (mounted) {
        _announce('Disconnected ${device.displayName}');
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar(
            'Failed to disconnect ${device.displayName}: $e');
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

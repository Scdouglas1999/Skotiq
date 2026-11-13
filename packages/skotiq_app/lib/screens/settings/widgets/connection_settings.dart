import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../tours/tour_target.dart';
import '../../connection/rig_connect_entry.dart';
import '../../connection/work_locally.dart';
import '../../../widgets/indi_server_dialog.dart';
import 'connection_settings_alpaca_dialog.dart';
import 'settings_scope_notice.dart';
import 'settings_widgets.dart';

class ConnectionSettings extends ConsumerWidget {
  const ConnectionSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final backend = ref.watch(backendProvider);
    final hostLink = ref.watch(linkedHostLinkProvider);
    final isNetwork = hostLink != null;
    final isDisconnected = backend.hasNoHost;
    // Live connection state — the authoritative signal for whether a network
    // backend is actually connected, mid-handshake, or errored. Relying on
    // `backend.remoteHost != null` alone would render a still-connecting (or a
    // rolled-back/errored) session as "Connected".
    final connState =
        ref.watch(networkBackendConnectionStateProvider).valueOrNull;
    final isConnected =
        isNetwork && connState == BackendConnectionState.connected;
    final isConnectError =
        isNetwork && connState == BackendConnectionState.error;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final settingsNotifier = ref.read(appSettingsProvider.notifier);
    final platformCapabilities =
        PlatformCapabilityMatrix.forPlatform(Platform.operatingSystem);

    // Derive the status label/colour from the live connection state, not just
    // the backend's runtime type.
    String serverAddress = 'Not connected';
    String connectionStatus = 'Disconnected';
    Color statusColor = colors.textMuted;

    if (hostLink != null) {
      serverAddress = hostLink.address;
      if (isConnected) {
        connectionStatus = 'Connected';
        statusColor = colors.success;
      } else if (isConnectError) {
        connectionStatus = 'Connection error';
        statusColor = colors.error;
      } else {
        connectionStatus = 'Connecting...';
        statusColor = colors.warning;
      }
    } else if (!isDisconnected) {
      // FfiBackend (local mode)
      serverAddress = 'Local';
      connectionStatus = 'Local Mode';
      statusColor = colors.primary;
    }

    return SettingsPage(
      key: TourTarget.settingsConnection.key,
      title: 'Connection',
      description: 'Server connection settings',
      children: [
        // This page keeps groups in both places: the link is this
        // computer's, discovery is the imaging host's.
        const SettingsScopeNotice(onHost: false, padding: _groupNoticePadding),
        SettingsSection(
          title: 'Server status',
          children: [
            SettingRow(
              icon: LucideIcons.server,
              title: 'Connection status',
              subtitle: serverAddress,
              trailing: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: SkotiqDecorations.emphasisSurface(
                  statusColor,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                ),
                child: Text(
                  connectionStatus,
                  style: SkotiqTypography.eyebrow.copyWith(
                    color: statusColor,
                  ),
                ),
              ),
            ),
            if (isNetwork)
              SettingRow(
                icon: LucideIcons.globe,
                title: 'Server address',
                subtitle: 'Current host and port for this Skotiq server',
                trailing: SelectableText(
                  serverAddress,
                  style: SkotiqTypography.readoutXs.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            SettingRow(
              icon: isNetwork ? LucideIcons.logOut : LucideIcons.logIn,
              title: isNetwork ? 'Disconnect' : 'Connect to Server',
              subtitle: isNetwork
                  ? 'Return to connection screen to connect to a different server'
                  : 'Open connection screen to connect to a server',
              trailing: SkotiqButton(
                label: isNetwork ? 'Disconnect' : 'Connect',
                variant: isNetwork
                    ? ButtonVariant.destructive
                    : ButtonVariant.primary,
                size: ButtonSize.small,
                onPressed: () =>
                    _handleConnectionAction(context, ref, isNetwork),
              ),
              isLast: !(isDisconnected && canWorkLocally),
            ),
            // The only way out of a DisconnectedBackend was to relaunch:
            // `useLocalBackend()` had no UI caller anywhere in the app, so a
            // desktop that fell out of local mode stayed there, red banner and
            // all. Offer the way back on the platforms whose entry point runs
            // the rig locally — a phone has no local hardware to fall back to.
            if (isDisconnected && canWorkLocally)
              const SettingRow(
                icon: LucideIcons.hardDrive,
                title: 'Work locally',
                subtitle:
                    'Drive the equipment attached to this computer instead of '
                    'a remote server',
                trailing: WorkLocallyButton(),
                isLast: true,
              ),
          ],
        ),
        if (settings != null)
          const SettingsScopeNotice(onHost: true, padding: _groupNoticePadding),
        if (settings != null)
          SettingsSection(
            title: 'Discovery',
            children: [
              // INDI is a Linux/macOS device-protocol server; on Windows the
              // host/port knob is not applicable, so only offer it off-Windows.
              if (!Platform.isWindows)
                SettingRow(
                  icon: LucideIcons.server,
                  title: 'INDI server address',
                  subtitle:
                      '${settings.indiServerHost}:${settings.indiServerPort}'
                      ' • host and port used for INDI discovery',
                  trailing: SkotiqButton(
                    label: 'Configure',
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: () => showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => const IndiServerDialog(),
                    ),
                  ),
                ),
              SettingRow(
                icon: LucideIcons.radio,
                title: 'Query INDI on startup',
                subtitle:
                    'Include the configured INDI server in automatic startup discovery',
                trailing: SettingsSwitch(
                  value: settings.indiAutoConnect,
                  onChanged: settingsNotifier.setIndiAutoConnect,
                ),
              ),
              // The address row the "configured Alpaca server" below it always
              // referred to. Without it the address was permanently the stored
              // default (localhost:11111) even though the common Alpaca
              // deployment is an ASCOM Remote host elsewhere on the LAN.
              SettingRow(
                icon: LucideIcons.server,
                title: 'Alpaca server address',
                subtitle:
                    '${settings.alpacaServerHost}:${settings.alpacaServerPort}'
                    ' • host and port used for Alpaca discovery',
                trailing: SkotiqButton(
                  label: 'Configure',
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () => showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => const AlpacaServerDialog(),
                  ),
                ),
              ),
              SettingRow(
                icon: LucideIcons.search,
                title: 'Query Alpaca on startup',
                subtitle:
                    'Include the configured Alpaca server in automatic startup discovery',
                trailing: SettingsSwitch(
                  value: settings.alpacaAutoDiscover,
                  onChanged: settingsNotifier.setAlpacaAutoDiscover,
                ),
              ),
              SettingRow(
                icon: LucideIcons.camera,
                title: 'Look for QHY cameras',
                subtitle: _qhyDiscoverySubtitle(
                  linked: isNetwork,
                  sdkAvailable: ref.watch(qhySdkAvailableProvider).valueOrNull,
                ),
                trailing: SettingsSwitch(
                  value: settings.qhyDiscoveryEnabled,
                  onChanged: settingsNotifier.setQhyDiscoveryEnabled,
                ),
                isLast: true,
              ),
            ],
          ),
        if (isConnected)
          const SettingsSection(
            title: 'Remote features',
            children: [
              SettingRow(
                icon: LucideIcons.refreshCw,
                title: 'Refresh host settings',
                subtitle: 'Reload this screen from the connected Skotiq host',
                trailing: _HostSettingsRefreshButton(),
                isLast: true,
              ),
            ],
          ),
        SettingsSection(
          // The capability matrix is computed from the LOCAL device's OS
          // (Platform.operatingSystem). In remote mode that is the tablet, not
          // the imaging host — so relabel to make clear whose driver support
          // this describes and avoid implying it is the rig's capabilities.
          title: isConnected
              ? 'This device capabilities'
              : 'Platform capabilities',
          children: [
            _PlatformCapabilityMatrixView(
              report: platformCapabilities,
              isRemote: isConnected,
            ),
          ],
        ),
      ],
    );
  }

  void _handleConnectionAction(
      BuildContext context, WidgetRef ref, bool hasNetworkBackend) {
    if (hasNetworkBackend) {
      // Offer to tear down the installed network backend (whether it is live,
      // still connecting, or errored) before returning to the connect screen.
      var disconnecting = false;
      String? disconnectError;
      showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Disconnect from Server?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'You will return to the connection screen where you can '
                  'connect to a different server.',
                ),
                if (disconnectError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    disconnectError!,
                    style: SkotiqTypography.body.copyWith(
                      color: Theme.of(ctx).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              SkotiqButton(
                label: 'Cancel',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: disconnecting ? null : () => Navigator.pop(ctx),
              ),
              SkotiqButton(
                label: disconnecting ? 'Disconnecting...' : 'Disconnect',
                variant: ButtonVariant.destructive,
                size: ButtonSize.small,
                onPressed: disconnecting
                    ? null
                    : () async {
                        setDialogState(() {
                          disconnecting = true;
                          disconnectError = null;
                        });
                        try {
                          await ref.read(backendProvider.notifier).disconnect();
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (e) {
                          if (!ctx.mounted) return;
                          setDialogState(() {
                            disconnecting = false;
                            disconnectError =
                                'Disconnect blocked: ${userFacingError(e)}';
                          });
                        }
                      },
              ),
            ],
          ),
        ),
      );
    } else {
      ref.read(openRigConnectProvider)(context);
    }
  }
}

/// What the QHY switch does here. The QHY SDK runs on the computer that owns
/// the rig, so on a linked client the switch is the host's.
const _groupNoticePadding = EdgeInsets.only(bottom: SkotiqTokens.spaceSm);

String _qhyDiscoverySubtitle({
  required bool linked,
  required bool? sdkAvailable,
}) {
  if (linked) {
    return 'Set on the imaging host. Turn off if its device scan crashes or '
        'hangs in the QHY SDK.';
  }
  if (sdkAvailable == false) {
    return 'The QHY SDK is not installed on this computer, so scans find no '
        'QHY devices either way.';
  }
  return 'Turn off if a device scan crashes or hangs in the QHY SDK. QHY '
      'cameras and filter wheels then stay out of scans.';
}

class _HostSettingsRefreshButton extends ConsumerStatefulWidget {
  const _HostSettingsRefreshButton();

  @override
  ConsumerState<_HostSettingsRefreshButton> createState() =>
      _HostSettingsRefreshButtonState();
}

class _HostSettingsRefreshButtonState
    extends ConsumerState<_HostSettingsRefreshButton> {
  bool _refreshing = false;
  int _generation = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next)) return;
        _generation++;
        if (mounted && _refreshing) {
          setState(() => _refreshing = false);
        }
      },
    );
  }

  @override
  void dispose() {
    _generation++;
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    final authority = ref.read(backendProvider);
    final generation = ++_generation;
    setState(() => _refreshing = true);
    try {
      ref.invalidate(appSettingsProvider);
      await ref.read(appSettingsProvider.future);
      if (_isCurrent(generation, authority) && mounted) {
        context.showSuccessSnackBar('Host settings refreshed');
      }
    } catch (e) {
      if (_isCurrent(generation, authority) && mounted) {
        context.showErrorSnackBar('Refresh failed: ${userFacingError(e)}');
      }
    } finally {
      if (_isCurrent(generation, authority)) {
        setState(() => _refreshing = false);
      }
    }
  }

  bool _isCurrent(int generation, SkotiqBackend authority) =>
      mounted &&
      _refreshing &&
      generation == _generation &&
      ref.backendScopeOver(authority).isCurrent;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // The spinner keeps the button's footprint while the fetch is in flight,
    // so the row does not reflow under the pointer.
    if (_refreshing) {
      return SizedBox.square(
        dimension: SkotiqTokens.iconButtonSize,
        child: Tooltip(
          message: 'Refreshing the host settings…',
          child: Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            child: SkotiqSpinner(size: 16, color: colors.primary),
          ),
        ),
      );
    }
    return SkotiqIconButton(
      icon: LucideIcons.downloadCloud,
      tooltip: 'Refresh host settings',
      onPressed: _refresh,
      color: colors.primary,
    );
  }
}

class _PlatformCapabilityMatrixView extends StatelessWidget {
  final PlatformCapabilityReport report;
  final bool isRemote;

  const _PlatformCapabilityMatrixView({
    required this.report,
    this.isRemote = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final platformLabel = _formatPlatform(report.platform);
    final narrow = SettingsFormScope.narrowOf(context);

    return Padding(
      padding: EdgeInsets.all(narrow ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.monitor,
                  size: narrow ? 16 : 18, color: colors.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isRemote
                      ? 'This device: $platformLabel (not the imaging host)'
                      : 'Current platform: $platformLabel',
                  style: SkotiqTypography.buttonSm.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (isRemote) ...[
            const SizedBox(height: 6),
            Text(
              'Driver support shown is for this device. The imaging host may '
              'support different drivers.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
          const SizedBox(height: 12),
          ...report.drivers.map(
            (driver) => _PlatformCapabilityRow(
              driver: driver,
              platform: report.platform,
            ),
          ),
        ],
      ),
    );
  }

  String _formatPlatform(String platform) {
    switch (platform) {
      case PlatformCapabilityMatrix.windows:
        return 'Windows';
      case PlatformCapabilityMatrix.linux:
        return 'Linux';
      case PlatformCapabilityMatrix.macos:
        return 'macOS';
      default:
        return platform;
    }
  }
}

class _PlatformCapabilityRow extends StatelessWidget {
  final PlatformDriverCapability driver;
  final String platform;
  const _PlatformCapabilityRow({
    required this.driver,
    required this.platform,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final status = driver.statusFor(platform);
    final statusColor = _statusColor(colors, status);
    final statusLabel = _statusLabel(status);
    // Label beside the details where there is room, above them where not.
    final narrow = SettingsFormScope.narrowOf(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(narrow ? 10 : 12),
      decoration: BoxDecoration(
        color: colors.well.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border.withValues(alpha: 0.6)),
      ),
      child: narrow
          ? _buildStacked(statusColor, statusLabel)
          : _buildSideBySide(statusColor, statusLabel),
    );
  }

  Color _statusColor(SkotiqColors colors, String status) {
    switch (status) {
      case 'available':
        return colors.success;
      case 'capability-gated':
        return colors.warning;
      default:
        return colors.error;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'available':
        return 'Available';
      case 'capability-gated':
        return 'Capability-gated';
      default:
        return 'Unsupported';
    }
  }

  Widget _buildSideBySide(Color statusColor, String statusLabel) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
          child: _DriverLabel(
            driver: driver,
            statusColor: statusColor,
            statusLabel: statusLabel,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _DriverDetails(
            driver: driver,
            platform: platform,
          ),
        ),
      ],
    );
  }

  Widget _buildStacked(Color statusColor, String statusLabel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DriverLabel(
          driver: driver,
          statusColor: statusColor,
          statusLabel: statusLabel,
        ),
        const SizedBox(height: 8),
        _DriverDetails(
          driver: driver,
          platform: platform,
        ),
      ],
    );
  }
}

class _DriverLabel extends StatelessWidget {
  final PlatformDriverCapability driver;
  final Color statusColor;
  final String statusLabel;

  const _DriverLabel({
    required this.driver,
    required this.statusColor,
    required this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          driver.label,
          style: SkotiqTypography.caption.copyWith(
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: SkotiqDecorations.chip(colors, tone: statusColor),
          child: Text(
            statusLabel,
            style: SkotiqTypography.eyebrow.copyWith(
              color: statusColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _DriverDetails extends StatelessWidget {
  final PlatformDriverCapability driver;
  final String platform;
  const _DriverDetails({
    required this.driver,
    required this.platform,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final unsupportedReason =
        driver.isAvailableOn(platform) ? null : driver.unsupportedReason;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          driver.notes,
          style: SkotiqTypography.caption.copyWith(
            color: colors.textSecondary,
          ),
        ),
        if (unsupportedReason != null) ...[
          const SizedBox(height: 4),
          Text(
            unsupportedReason,
            style: SkotiqTypography.caption.copyWith(
              color: colors.warning,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          driver.deviceCoverage,
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }
}

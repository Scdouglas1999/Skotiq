import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../services/network_service.dart';

/// How the active session reaches the headless server. Drives the LAN-vs-
/// Tailscale badge + icon on the indicator so the operator can tell at a
/// glance whether they're on the fast on-site LAN path or the
/// reachable-from-anywhere tailnet path.
enum _TransportTier {
  /// Server host is an RFC1918 / link-local / `.local` LAN address —
  /// only reachable on-site.
  lan,

  /// Server host is a Tailscale tailnet address (`100.64.0.0/10` /
  /// `fd7a:115c::/32`) — reachable from anywhere on the tailnet.
  tailscale,

  /// No NetworkBackend / not connected, so transport is irrelevant.
  none,
}

/// Combined connection-state model for [NetworkStatusIndicator].
///
/// The mobile UX cares about two layered signals:
///   1. OS-level connectivity (do we have any WiFi/cellular link at all?)
///   2. WebSocket session liveness (is the headless server reachable?)
///
/// The user almost always cares about (2): a green dot must mean "I can
/// drive the rig right now". If the WS is down but WiFi is up, we surface
/// "Server offline", not "Connected via WiFi" — that earlier behaviour
/// was the audit finding (bug 5).
///
/// the OS-online + WS-down case is now reported as
/// `serverOffline` ("Server unreachable" in the UI) while the first-time
/// connect attempt is `connecting` (distinct from `reconnecting`). The
/// new `error` case covers terminal failures like API-version mismatch.
enum _CombinedConnectionStatus {
  /// WS is connected AND OS reports network. The user can drive the rig.
  connected,

  /// WS is on its first connect attempt (no previous successful session).
  connecting,

  /// WS is reconnecting after a previously-healthy session dropped.
  reconnecting,

  /// WS dropped (post-grace) but OS still has a usable link. This usually
  /// means the server itself is offline / firewall / wrong host.
  serverOffline,

  /// WS hit a terminal failure (API version mismatch, etc.). The backend
  /// has stopped attempting; the user must fix the underlying issue.
  error,

  /// OS reports no usable network at all (no WiFi, no cellular).
  noNetwork,

  /// The mobile app is intentionally not paired to a server (e.g. the
  /// user picked "Skip" on the connection screen, or hasn't connected
  /// yet). Distinct from `serverOffline` because there's nothing to retry.
  notConnected,
}

/// Network status indicator widget.
///
/// Reflects the *effective* connection state to the headless server,
/// not just the OS link. Tap to open a details sheet that also lets
/// the operator force an immediate reconnect (audit bug 6).
class NetworkStatusIndicator extends ConsumerStatefulWidget {
  final bool compact;

  const NetworkStatusIndicator({super.key, this.compact = false});

  @override
  ConsumerState<NetworkStatusIndicator> createState() =>
      _NetworkStatusIndicatorState();
}

class _NetworkStatusIndicatorState
    extends ConsumerState<NetworkStatusIndicator> {
  Duration? _latency;
  StreamSubscription<Duration>? _latencySubscription;
  NetworkBackend? _trackedBackend;
  int _backendGeneration = 0;

  @override
  void initState() {
    super.initState();
    // Seed and subscribe against whatever backend is currently active.
    _attachToBackend(ref.read(backendProvider));
  }

  @override
  void dispose() {
    _backendGeneration++;
    _latencySubscription?.cancel();
    super.dispose();
  }

  void _attachToBackend(SkotiqBackend backend) {
    if (identical(backend, _trackedBackend)) return;
    final generation = ++_backendGeneration;
    _latencySubscription?.cancel();
    _latencySubscription = null;
    if (backend is NetworkBackend) {
      _trackedBackend = backend;
      // Seed with the last observed value so the UI doesn't flash empty
      // immediately after a backend swap.
      _latency = backend.lastLatency;
      _latencySubscription = backend.latencyStream.listen((value) {
        if (!mounted ||
            generation != _backendGeneration ||
            !identical(_trackedBackend, backend)) {
          return;
        }
        setState(() => _latency = value);
      });
    } else {
      _trackedBackend = null;
      if (_latency != null) {
        _latency = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild + re-attach whenever the backend instance changes (connect,
    // disconnect, swap). `ref.listen` keeps the StreamSubscription scoped
    // to the live backend so we don't leak handlers across reconnects.
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      _attachToBackend(next);
    });

    final backend = ref.watch(backendProvider);

    // Build the combined state from (a) backend WS state, (b) OS connectivity.
    // OS connectivity comes through NetworkService' stateStream; we use a
    // StreamBuilder for that signal so we don't have to bridge it through
    // Riverpod just for the indicator.
    return StreamBuilder<NetworkServiceState>(
      stream: NetworkService().stateStream,
      initialData: NetworkService().currentState,
      builder: (context, snapshot) {
        final osState = snapshot.data ?? NetworkService().currentState;
        return _buildForBackend(context, backend, osState);
      },
    );
  }

  Widget _buildForBackend(
    BuildContext context,
    SkotiqBackend backend,
    NetworkServiceState osState,
  ) {
    // When the backend itself is a NetworkBackend we also want to rebuild
    // on every connectionState transition so the indicator follows the
    // grace-window UX. StreamBuilder handles that for us.
    if (backend is NetworkBackend) {
      return StreamBuilder<BackendConnectionState>(
        stream: backend.connectionStateStream,
        initialData: backend.connectionState,
        builder: (context, wsSnap) {
          final wsState = wsSnap.data ?? backend.connectionState;
          final combined = _combine(wsState, osState);
          return _renderIndicator(context, combined, osState, backend: backend);
        },
      );
    }
    // No NetworkBackend means the app is using either FfiBackend
    // (local-only) or DisconnectedBackend (skipped connect / dropped
    // session). On mobile the first is irrelevant, so collapse both
    // into `notConnected`.
    final combined = backend is DisconnectedBackend
        ? _CombinedConnectionStatus.notConnected
        : _CombinedConnectionStatus.connected;
    return _renderIndicator(context, combined, osState, backend: null);
  }

  _CombinedConnectionStatus _combine(
    BackendConnectionState wsState,
    NetworkServiceState osState,
  ) {
    // OS link gone → that's the dominant failure, surface it regardless
    // of WS state. Reconnecting against no network is a hopeless task and
    // showing "Reconnecting…" would mislead the operator.
    if (!osState.hasConnection) {
      return _CombinedConnectionStatus.noNetwork;
    }
    switch (wsState) {
      case BackendConnectionState.connected:
        return _CombinedConnectionStatus.connected;
      case BackendConnectionState.connecting:
        return _CombinedConnectionStatus.connecting;
      case BackendConnectionState.reconnecting:
        return _CombinedConnectionStatus.reconnecting;
      case BackendConnectionState.disconnected:
        // OS link present, WS not — server side problem.
        return _CombinedConnectionStatus.serverOffline;
      case BackendConnectionState.error:
        return _CombinedConnectionStatus.error;
    }
  }

  /// Classify how the active backend reaches the server (LAN vs tailnet).
  /// Returns [_TransportTier.none] when there is no NetworkBackend.
  static _TransportTier _transportTier(NetworkBackend? backend) {
    if (backend == null) return _TransportTier.none;
    return backend.isRemoteHost ? _TransportTier.tailscale : _TransportTier.lan;
  }

  Widget _renderIndicator(
    BuildContext context,
    _CombinedConnectionStatus status,
    NetworkServiceState osState, {
    required NetworkBackend? backend,
  }) {
    final transport = _transportTier(backend);
    return GestureDetector(
      onTap: () => _showConnectionDetails(context, status, osState, backend),
      child: widget.compact
          ? _buildCompactIndicator(context, status, transport)
          : _buildFullIndicator(context, status, osState, backend, transport),
    );
  }

  /// Compact indicator (icon-only, used in tight AppBar slots).
  Widget _buildCompactIndicator(
    BuildContext context,
    _CombinedConnectionStatus status,
    _TransportTier transport,
  ) {
    final color = _statusColor(context, status);
    final icon = _statusIcon(status, transport);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: SkotiqDecorations.statusChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        bordered: false,
      ),
      child: Icon(icon, size: 20, color: color),
    );
  }

  /// Full indicator (status text + server name + latency badge).
  Widget _buildFullIndicator(
    BuildContext context,
    _CombinedConnectionStatus status,
    NetworkServiceState osState,
    NetworkBackend? backend,
    _TransportTier transport,
  ) {
    final color = _statusColor(context, status);
    final icon = _statusIcon(status, transport);
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: SkotiqDecorations.statusChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _statusText(status, transport),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (osState.connectedServer != null || _shouldShowLatency(status))
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (osState.connectedServer != null)
                      Text(
                        osState.connectedServer!.name,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: color.withValues(alpha: 0.8),
                        ),
                      ),
                    if (_shouldShowLatency(status) && _latency != null) ...[
                      if (osState.connectedServer != null)
                        Text(
                          ' · ',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: color.withValues(alpha: 0.6),
                          ),
                        ),
                      _LatencyBadge(latency: _latency!, baseColor: color),
                    ],
                  ],
                ),
            ],
          ),
          const SizedBox(width: 4),
          Icon(
            LucideIcons.chevronRight,
            size: 16,
            color: color.withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }

  bool _shouldShowLatency(_CombinedConnectionStatus status) {
    // Stale latency on a dropped connection is misleading — only show it
    // while the link is reporting healthy.
    return status == _CombinedConnectionStatus.connected;
  }

  Color _statusColor(BuildContext context, _CombinedConnectionStatus status) {
    final theme = Theme.of(context);
    final colors = theme.extension<SkotiqColors>();
    switch (status) {
      case _CombinedConnectionStatus.connected:
        return colors?.success ?? theme.colorScheme.primary;
      case _CombinedConnectionStatus.connecting:
      case _CombinedConnectionStatus.reconnecting:
        return colors?.warning ?? theme.colorScheme.secondary;
      case _CombinedConnectionStatus.serverOffline:
      case _CombinedConnectionStatus.error:
        return colors?.error ?? theme.colorScheme.error;
      case _CombinedConnectionStatus.noNetwork:
        return colors?.textMuted ?? theme.colorScheme.onSurfaceVariant;
      case _CombinedConnectionStatus.notConnected:
        return colors?.textMuted ?? theme.colorScheme.onSurfaceVariant;
    }
  }

  IconData _statusIcon(
    _CombinedConnectionStatus status,
    _TransportTier transport,
  ) {
    switch (status) {
      case _CombinedConnectionStatus.connected:
        // Lucide icon sweep: a live tailnet session reads as
        // "reachable from anywhere" (radio tower), a LAN session as the
        // familiar on-site WiFi glyph.
        return transport == _TransportTier.tailscale
            ? LucideIcons.radioTower
            : LucideIcons.wifi;
      case _CombinedConnectionStatus.connecting:
      case _CombinedConnectionStatus.reconnecting:
        return LucideIcons.refreshCw;
      case _CombinedConnectionStatus.serverOffline:
        return LucideIcons.serverOff;
      case _CombinedConnectionStatus.error:
        return LucideIcons.alertTriangle;
      case _CombinedConnectionStatus.noNetwork:
        return LucideIcons.wifiOff;
      case _CombinedConnectionStatus.notConnected:
        return LucideIcons.wifiOff;
    }
  }

  String _statusText(
    _CombinedConnectionStatus status,
    _TransportTier transport,
  ) {
    switch (status) {
      case _CombinedConnectionStatus.connected:
        // Distinguish the reachability path so the operator knows whether
        // they're on the fast on-site LAN or the roam-anywhere tailnet.
        switch (transport) {
          case _TransportTier.tailscale:
            return 'Live · Tailscale';
          case _TransportTier.lan:
            return 'Live · LAN';
          case _TransportTier.none:
            return 'Live';
        }
      case _CombinedConnectionStatus.connecting:
        return 'Connecting';
      case _CombinedConnectionStatus.reconnecting:
        return 'Reconnecting...';
      case _CombinedConnectionStatus.serverOffline:
        return 'Server unreachable';
      case _CombinedConnectionStatus.error:
        return 'Connection error';
      case _CombinedConnectionStatus.noNetwork:
        return 'No network';
      case _CombinedConnectionStatus.notConnected:
        return 'Not connected';
    }
  }

  void _showConnectionDetails(
    BuildContext context,
    _CombinedConnectionStatus status,
    NetworkServiceState osState,
    NetworkBackend? backend,
  ) {
    final colors = SkotiqColors.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: colors.background.withValues(alpha: 0.72),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SkotiqTokens.radiusLg),
        ),
      ),
      builder: (sheetContext) => _ConnectionDetailsSheet(
        status: status,
        osState: osState,
        latency: _latency,
        backend: backend,
      ),
    );
  }
}

/// Latency chip rendered next to the server name. Coloured by threshold:
/// green <50ms, amber 50-200ms, red >200ms. Falls back to the parent
/// status colour if no SkotiqColors extension is found.
class _LatencyBadge extends StatelessWidget {
  final Duration latency;
  final Color baseColor;

  const _LatencyBadge({required this.latency, required this.baseColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<SkotiqColors>();
    final ms = latency.inMicroseconds / 1000.0;
    Color color;
    if (colors != null) {
      if (ms < 50) {
        color = colors.success;
      } else if (ms < 200) {
        color = colors.warning;
      } else {
        color = colors.error;
      }
    } else {
      color = baseColor;
    }
    return Text(
      '${ms.round()} ms',
      style: theme.textTheme.bodySmall?.copyWith(
        color: color.withValues(alpha: 0.9),
        fontFeatures: const [FontFeature.tabularFigures()],
        fontFamily: SkotiqTypography.fontFamilyMono,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Connection details bottom sheet.
class _ConnectionDetailsSheet extends ConsumerStatefulWidget {
  final _CombinedConnectionStatus status;
  final NetworkServiceState osState;
  final Duration? latency;
  final NetworkBackend? backend;

  const _ConnectionDetailsSheet({
    required this.status,
    required this.osState,
    required this.latency,
    required this.backend,
  });

  @override
  ConsumerState<_ConnectionDetailsSheet> createState() =>
      _ConnectionDetailsSheetState();
}

class _ConnectionDetailsSheetState
    extends ConsumerState<_ConnectionDetailsSheet> {
  bool _reconnecting = false;
  bool _searching = false;
  bool _disconnecting = false;

  Future<void> _handleReconnectNow() async {
    if (_reconnecting) return;
    final activeBackend = ref.read(backendProvider);
    if (activeBackend is! NetworkBackend) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No remote server is selected. Reconnect first.'),
          ),
        );
      }
      return;
    }
    final backend = activeBackend;
    setState(() => _reconnecting = true);
    try {
      await backend.reconnectNow();
    } catch (e) {
      if (mounted && identical(ref.read(backendProvider), backend)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Reconnect failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _reconnecting = false);
      }
    }
  }

  /// Run the discovery cascade and, on a hit, connect the backend to the rig.
  /// Stamping last-server and NetworkService status alone — what
  /// `NetworkService().rediscoverServer()` does — leaves the WebSocket session
  /// down, so the button would report success while the app still could not
  /// drive the rig.
  Future<void> _handleSearchForServers() async {
    setState(() => _searching = true);
    DiscoveredServer? server;
    Object? discoveryError;
    try {
      server = await EnhancedSkotiqDiscovery.discoverWithFallback();
    } catch (e) {
      discoveryError = e;
    }
    if (!mounted) return;
    if (server == null) {
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            discoveryError == null
                ? 'No servers found on this network.'
                : 'Server discovery failed: $discoveryError',
          ),
        ),
      );
      return;
    }
    try {
      await ref
          .read(backendProvider.notifier)
          .connect(
            server.host,
            server.webPort,
            authToken: server.authToken,
            scheme: server.scheme,
            pinnedFingerprint: server.fingerprint,
          );
      await EnhancedSkotiqDiscovery.saveLastServer(server);
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to connect: $e')));
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _handleDisconnect() async {
    if (_disconnecting) return;
    setState(() => _disconnecting = true);
    try {
      await ref.read(backendProvider.notifier).disconnect();
      await NetworkService().disconnect();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _disconnecting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Disconnect blocked: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);
    final status = widget.status;
    final osState = widget.osState;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(SkotiqTokens.radiusLg),
        ),
        border: Border(top: BorderSide(color: colors.border)),
        boxShadow: SkotiqTokens.shadowLg,
      ),
      padding: SkotiqTokens.dialogPadding.add(
        EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                _headerIcon(status),
                size: 32,
                color: _headerColor(context, status),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Connection Status',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      _statusDescription(status, osState),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Connection Details
          if (osState.connectedServer != null) ...[
            _DetailRow(label: 'Server', value: osState.connectedServer!.name),
            _DetailRow(label: 'Host', value: osState.connectedServer!.host),
            _DetailRow(
              label: 'Port',
              value: osState.connectedServer!.webPort.toString(),
            ),
            _DetailRow(
              label: 'Version',
              value: osState.connectedServer!.version,
            ),
          ],

          // Network Details
          _DetailRow(
            label: 'Network Type',
            value: _getNetworkType(osState.connectivityResults),
          ),

          // Transport path — only meaningful for a live NetworkBackend. Tells
          // the operator whether the session is on the on-site LAN or the
          // reachable-from-anywhere Tailscale tailnet.
          if (widget.backend != null)
            _DetailRow(
              label: 'Reachable via',
              value: widget.backend!.isRemoteHost
                  ? 'Tailscale (${widget.backend!.serverHost})'
                  : 'LAN (${widget.backend!.serverHost})',
            ),

          if (widget.latency != null &&
              status == _CombinedConnectionStatus.connected)
            _DetailRow(
              label: 'Latency',
              value: '${(widget.latency!.inMicroseconds / 1000.0).round()} ms',
            ),

          if (osState.statusMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.info, size: 16, color: colors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      osState.statusMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Actions
          // "Reconnect now" — only meaningful when a NetworkBackend exists
          // and the WS is not currently fully healthy. The button is the
          // primary remediation for audit bug 6 (no manual reconnect
          // during the 30s grace window).
          if (widget.backend != null &&
              status != _CombinedConnectionStatus.noNetwork &&
              status != _CombinedConnectionStatus.notConnected) ...[
            SizedBox(
              width: double.infinity,
              child: SkotiqButton(
                onPressed: _reconnecting ? null : _handleReconnectNow,
                icon: LucideIcons.refreshCw,
                label: _reconnecting ? 'Reconnecting...' : 'Reconnect now',
              ),
            ),
            const SizedBox(height: 8),
          ],

          if (status == _CombinedConnectionStatus.noNetwork ||
              status == _CombinedConnectionStatus.serverOffline ||
              status == _CombinedConnectionStatus.error ||
              status == _CombinedConnectionStatus.notConnected)
            SizedBox(
              width: double.infinity,
              child: SkotiqButton(
                onPressed: _searching ? null : _handleSearchForServers,
                icon: LucideIcons.search,
                label: _searching ? 'Searching...' : 'Search for Servers',
                variant: ButtonVariant.outline,
              ),
            ),

          if (status == _CombinedConnectionStatus.connected)
            SizedBox(
              width: double.infinity,
              child: SkotiqButton(
                onPressed: _disconnecting ? null : _handleDisconnect,
                icon: LucideIcons.logOut,
                label: _disconnecting ? 'Disconnecting...' : 'Disconnect',
                variant: ButtonVariant.destructive,
              ),
            ),
        ],
      ),
    );
  }

  IconData _headerIcon(_CombinedConnectionStatus status) {
    switch (status) {
      case _CombinedConnectionStatus.connected:
        return LucideIcons.checkCircle;
      case _CombinedConnectionStatus.connecting:
      case _CombinedConnectionStatus.reconnecting:
        return LucideIcons.loader;
      case _CombinedConnectionStatus.serverOffline:
        return LucideIcons.serverOff;
      case _CombinedConnectionStatus.error:
        return LucideIcons.alertTriangle;
      case _CombinedConnectionStatus.noNetwork:
        return LucideIcons.wifiOff;
      case _CombinedConnectionStatus.notConnected:
        return LucideIcons.xCircle;
    }
  }

  Color _headerColor(BuildContext context, _CombinedConnectionStatus status) {
    final theme = Theme.of(context);
    final colors = theme.extension<SkotiqColors>();
    switch (status) {
      case _CombinedConnectionStatus.connected:
        return colors?.success ?? theme.colorScheme.primary;
      case _CombinedConnectionStatus.connecting:
      case _CombinedConnectionStatus.reconnecting:
        return colors?.warning ?? theme.colorScheme.secondary;
      case _CombinedConnectionStatus.serverOffline:
      case _CombinedConnectionStatus.error:
        return colors?.error ?? theme.colorScheme.error;
      case _CombinedConnectionStatus.noNetwork:
      case _CombinedConnectionStatus.notConnected:
        return colors?.textMuted ?? theme.colorScheme.onSurfaceVariant;
    }
  }

  String _statusDescription(
    _CombinedConnectionStatus status,
    NetworkServiceState osState,
  ) {
    switch (status) {
      case _CombinedConnectionStatus.connected:
        return 'Connected to ${osState.connectedServer?.name ?? "server"}';
      case _CombinedConnectionStatus.connecting:
        return 'Connecting to '
            '${osState.connectedServer?.name ?? "the server"}...';
      case _CombinedConnectionStatus.reconnecting:
        return 'Attempting to reconnect...';
      case _CombinedConnectionStatus.serverOffline:
        return 'WiFi is up but the server is not responding.';
      case _CombinedConnectionStatus.error:
        return 'The server rejected the connection. Check version '
            'compatibility and the server log.';
      case _CombinedConnectionStatus.noNetwork:
        return 'No network connection available';
      case _CombinedConnectionStatus.notConnected:
        return 'Not connected to a server';
    }
  }

  String _getNetworkType(List<dynamic> results) {
    if (results.isEmpty) return 'None';

    final types = <String>[];
    for (final result in results) {
      final name = result.toString().split('.').last;
      if (name != 'none') {
        types.add(name[0].toUpperCase() + name.substring(1));
      }
    }

    return types.isEmpty ? 'None' : types.join(', ');
  }
}

/// Detail row widget
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

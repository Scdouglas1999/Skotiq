import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:go_router/go_router.dart';

import 'link_rig_actions.dart';
import 'link_rig_dialog.dart';
import '../../router/settings_sections.dart';
import 'share_session_dialog.dart';

import 'work_locally.dart';
import '../../router/app_routes.dart';
import 'package:skotiq_core/models.dart';
import '../../utils/snackbar_helper.dart';

/// Four-state model for the shared remote-connection indicator.
///
/// Distinct from `BackendConnectionState` so we can render a sane
/// "not connected at all" state (e.g. desktop using FfiBackend or
/// mobile that hasn't reached a server yet) without forcing the
/// backend to invent another enum value just for UI.
///
/// `connecting` is separate from `reconnecting` so the very
/// first handshake says "Connecting" rather than "Reconnecting" (the
/// latter implies a prior successful session). Both map to amber/
/// pulsing visuals but the messaging differs.
enum RemoteConnectionStatus {
  connected,

  /// The socket is open but the host has left a heartbeat unanswered for at
  /// least [hostAnswerStaleAfter]: what the screen shows may be out of date.
  notAnswering,
  connecting,
  reconnecting,
  serverOffline,
  error,
  notConnected,
}

/// Compact pill-style indicator showing the live state of the
/// [NetworkBackend] WebSocket session. Designed for the mobile shell's
/// title-bar slot but reusable anywhere a small
/// "is the remote rig reachable?" chip is wanted.
///
/// When the current backend is not a [NetworkBackend] (e.g. the host
/// desktop running [FfiBackend], or a mobile session that hasn't paired
/// yet), the indicator renders a muted "Not connected" pill instead of
/// a green one — there is nothing remote to reach, so claiming
/// "Connected" would lie.
///
/// Tap to open a detail sheet that includes a "Reconnect now" button
/// addressing audit bug 6.
class RemoteConnectionIndicator extends ConsumerStatefulWidget {
  /// When true, render only the icon (used in tight AppBar slots).
  final bool compact;

  /// When true, render an ambient ~10px status **dot** only — no pill, no
  /// label. Used by the immersive phone shell, where a dedicated connection
  /// strip would waste the very short cover-screen height; the dot sits in a
  /// corner overlay (zero layout cost) and still opens the detail sheet on tap.
  final bool dot;

  const RemoteConnectionIndicator({
    super.key,
    this.compact = false,
    this.dot = false,
  });

  @override
  ConsumerState<RemoteConnectionIndicator> createState() =>
      _RemoteConnectionIndicatorState();
}

class _RemoteConnectionIndicatorState
    extends ConsumerState<RemoteConnectionIndicator> {
  Duration? _latency;
  StreamSubscription<Duration>? _latencySubscription;
  HostLink? _trackedLink;

  /// The link the latency and heartbeat readings come from; readings that
  /// arrive after a host change are dropped.
  late final _links = ref.backendScopes(alive: () => mounted);
  Timer? _answerTimer;
  int? _unansweredSeconds;

  @override
  void initState() {
    super.initState();
    _attachToLink(ref.read(linkedHostLinkProvider));
  }

  @override
  void dispose() {
    _latencySubscription?.cancel();
    _answerTimer?.cancel();
    super.dispose();
  }

  /// Subscribe to the latency of the current link to the host. Resubscribes
  /// when a backend swap happens (connect / disconnect / reconnect creates a
  /// new instance).
  void _attachToLink(HostLink? hostLink) {
    if (identical(hostLink, _trackedLink)) return;
    final link = _links.beginLatest();
    _latencySubscription?.cancel();
    _latencySubscription = null;
    _answerTimer?.cancel();
    _answerTimer = null;
    _unansweredSeconds = null;
    if (hostLink != null) {
      _trackedLink = hostLink;
      _latency = hostLink.lastLatency;
      // The socket state alone said "Live" through a two-minute stall on a
      // failing Wi-Fi link: the connection stayed open while answers took
      // seconds to tens of seconds. Look at the heartbeat every second.
      _unansweredSeconds = unansweredSecondsFor(hostLink);
      _answerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (link.isStale) return;
        final seconds = unansweredSecondsFor(hostLink);
        if (seconds != _unansweredSeconds) {
          setState(() => _unansweredSeconds = seconds);
        }
      });
      _latencySubscription = hostLink.latencyStream.listen((value) {
        if (link.isStale) return;
        setState(() => _latency = value);
      });
    } else {
      _trackedLink = null;
      if (_latency != null) {
        setState(() => _latency = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<HostLink?>(linkedHostLinkProvider, (_, next) {
      _attachToLink(next);
    });
    final hostLink = ref.watch(linkedHostLinkProvider);

    if (hostLink != null) {
      return StreamBuilder<BackendConnectionState>(
        stream: hostLink.connectionStateStream,
        initialData: hostLink.connectionState,
        builder: (context, snap) {
          final wsState = snap.data ?? hostLink.connectionState;
          var status = _statusForBackendState(wsState);
          if (status == RemoteConnectionStatus.connected &&
              _unansweredSeconds != null) {
            status = RemoteConnectionStatus.notAnswering;
          }
          return _build(
            context,
            status,
            hostAddress: hostLink.serverHost,
          );
        },
      );
    }
    // A launch linked to a host that has not answered yet has no backend to
    // ask, but it is linked: say the host is unreachable, not "not linked".
    final target = ref.watch(remoteLaunchTargetProvider);
    return _build(
      context,
      target == null
          ? RemoteConnectionStatus.notConnected
          : RemoteConnectionStatus.serverOffline,
      hostAddress: target?.host,
    );
  }

  RemoteConnectionStatus _statusForBackendState(BackendConnectionState state) {
    switch (state) {
      case BackendConnectionState.connected:
        return RemoteConnectionStatus.connected;
      case BackendConnectionState.connecting:
        return RemoteConnectionStatus.connecting;
      case BackendConnectionState.reconnecting:
        return RemoteConnectionStatus.reconnecting;
      case BackendConnectionState.disconnected:
        return RemoteConnectionStatus.serverOffline;
      case BackendConnectionState.error:
        return RemoteConnectionStatus.error;
    }
  }

  Widget _build(
    BuildContext context,
    RemoteConnectionStatus status, {
    required String? hostAddress,
  }) {
    // The tap lived on a bare gesture wrapper, which publishes an action
    // and no role, so assistive tech read a live control as an inert
    // disabled panel. The flags are only published when given.
    final description = hostAddress == null
        ? 'Not linked to a remote imaging host'
        : '${_textFor(status, _unansweredSeconds)} · $hostAddress';
    return Tooltip(
      message: description,
      child: Semantics(
        button: true,
        enabled: true,
        label: 'Imaging host link: $description',
        child: GestureDetector(
          onTap: () => _showDetails(context),
          child: widget.dot
              ? _buildDot(context, status)
              : widget.compact
                  ? _buildCompact(context, status)
                  : _buildFull(context, status, hostAddress),
        ),
      ),
    );
  }

  Widget _buildDot(BuildContext context, RemoteConnectionStatus status) {
    final color = _colorFor(context, status);
    final pulsing = status == RemoteConnectionStatus.connecting ||
        status == RemoteConnectionStatus.reconnecting ||
        status == RemoteConnectionStatus.notAnswering;
    // A generous transparent hit area around a small visible dot so it stays
    // tappable without claiming visual space.
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: pulsing ? 0.6 : 0.4),
              blurRadius: pulsing ? 6 : 3,
              spreadRadius: pulsing ? 1 : 0,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, RemoteConnectionStatus status) {
    final color = _colorFor(context, status);
    // In the title bar this sits beside three plain icon buttons, so a filled
    // chip would make the RESTING state — "not connected to a server", the
    // normal state of a local install — read as the one selected control in the
    // row. The tint is meaningful when something is actually happening
    // (connected, retrying, offline, error), so it stays for those.
    final isResting = status == RemoteConnectionStatus.notConnected;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: isResting
          ? const BoxDecoration()
          : SkotiqDecorations.statusChip(
              color,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              bordered: false,
            ),
      child: Icon(_iconFor(status), size: 20, color: color),
    );
  }

  Widget _buildFull(
    BuildContext context,
    RemoteConnectionStatus status,
    String? hostAddress,
  ) {
    final color = _colorFor(context, status);
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
          Icon(_iconFor(status), size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            _textFor(status, _unansweredSeconds),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (hostAddress != null) ...[
            Text(
              ' · $hostAddress',
              style: theme.textTheme.bodySmall?.copyWith(
                color: color.withValues(alpha: 0.75),
              ),
            ),
          ],
          if (status == RemoteConnectionStatus.connected &&
              _latency != null) ...[
            const SizedBox(width: 6),
            _LatencyBadge(latency: _latency!, baseColor: color),
          ],
        ],
      ),
    );
  }

  /// Opens the connection details.
  ///
  /// [showAdaptiveModal], not a bare bottom sheet: on the desktop this opens
  /// from the title bar at the TOP of the window, and a sheet welded to the
  /// opposite edge comes up clipped — the header visible and every control
  /// under it not. It centres on desktop like every other modal, and still
  /// presents as a sheet on a phone.
  void _showDetails(BuildContext context) {
    unawaited(
      showAdaptiveModal<void>(
        context: context,
        designWidth: 460,
        builder: (_) => const _RemoteConnectionSheet(),
      ),
    );
  }

  Color _colorFor(BuildContext context, RemoteConnectionStatus status) {
    final theme = Theme.of(context);
    final colors = theme.extension<SkotiqColors>();
    switch (status) {
      case RemoteConnectionStatus.connected:
        return colors?.success ?? theme.colorScheme.primary;
      case RemoteConnectionStatus.notAnswering:
      case RemoteConnectionStatus.connecting:
      case RemoteConnectionStatus.reconnecting:
        return colors?.warning ?? theme.colorScheme.secondary;
      case RemoteConnectionStatus.serverOffline:
      case RemoteConnectionStatus.error:
        return colors?.error ?? theme.colorScheme.error;
      case RemoteConnectionStatus.notConnected:
        return colors?.textMuted ?? theme.colorScheme.onSurfaceVariant;
    }
  }

  IconData _iconFor(RemoteConnectionStatus status) {
    switch (status) {
      case RemoteConnectionStatus.connected:
        return LucideIcons.wifi;
      case RemoteConnectionStatus.notAnswering:
        return LucideIcons.clock;
      case RemoteConnectionStatus.connecting:
      case RemoteConnectionStatus.reconnecting:
        return LucideIcons.refreshCw;
      case RemoteConnectionStatus.serverOffline:
        return LucideIcons.serverOff;
      case RemoteConnectionStatus.error:
        return LucideIcons.alertTriangle;
      case RemoteConnectionStatus.notConnected:
        return LucideIcons.wifiOff;
    }
  }

  String _textFor(RemoteConnectionStatus status, int? unansweredSeconds) {
    switch (status) {
      case RemoteConnectionStatus.connected:
        return 'Live';
      case RemoteConnectionStatus.notAnswering:
        return 'No answer for ${unansweredSeconds ?? 0} s';
      case RemoteConnectionStatus.connecting:
        return 'Connecting...';
      case RemoteConnectionStatus.reconnecting:
        return 'Reconnecting...';
      case RemoteConnectionStatus.serverOffline:
        return 'Server unreachable';
      case RemoteConnectionStatus.error:
        return 'Connection error';
      case RemoteConnectionStatus.notConnected:
        return 'Not connected';
    }
  }
}

class _LatencyBadge extends StatelessWidget {
  final Duration latency;
  final Color baseColor;

  const _LatencyBadge({
    required this.latency,
    required this.baseColor,
  });

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

class _RemoteConnectionSheet extends ConsumerStatefulWidget {
  const _RemoteConnectionSheet();

  @override
  ConsumerState<_RemoteConnectionSheet> createState() =>
      _RemoteConnectionSheetState();
}

class _RemoteConnectionSheetState
    extends ConsumerState<_RemoteConnectionSheet> {
  bool _reconnecting = false;
  bool _disconnecting = false;

  /// The reconnect in progress; a host change drops it.
  late final _reconnects = ref.backendScopes(alive: () => mounted);
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (!_reconnecting || previous == null || identical(previous, next)) {
          return;
        }
        _reconnects.cancelAll();
        if (mounted) setState(() => _reconnecting = false);
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _handleReconnect() async {
    if (_reconnecting) return;
    final reconnect = _reconnects.beginLatest();
    final hostLink = ref.read(linkedHostLinkProvider);
    if (hostLink == null) {
      if (mounted) {
        context.showInfoSnackBar(
          'No remote server is selected. Reconnect first.',
        );
      }
      return;
    }
    setState(() => _reconnecting = true);
    try {
      await hostLink.reconnectNow();
    } catch (e) {
      if (mounted && reconnect.isCurrent) {
        context.showErrorSnackBar('Reconnect failed: ${userFacingError(e)}');
      }
    } finally {
      if (reconnect.isCurrent) setState(() => _reconnecting = false);
    }
  }

  Future<void> _handleDisconnect() async {
    if (_disconnecting) return;
    setState(() => _disconnecting = true);
    try {
      await ref.read(backendProvider.notifier).disconnect();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _disconnecting = false);
      context.showErrorSnackBar('Disconnect blocked: ${userFacingError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);
    final activeBackend = ref.watch(backendProvider);
    final hostLink = ref.watch(linkedHostLinkProvider);
    final unansweredSeconds =
        hostLink == null ? null : unansweredSecondsFor(hostLink);
    var status = hostLink == null
        ? RemoteConnectionStatus.notConnected
        : _statusForConnectionState(hostLink.connectionState);
    if (status == RemoteConnectionStatus.connected &&
        unansweredSeconds != null) {
      status = RemoteConnectionStatus.notAnswering;
    }
    final latency = hostLink?.lastLatency;
    final linkedLaunch = ref.watch(remoteLaunchTargetProvider);
    final canSwitch = canSwitchRole(ref);

    return Padding(
      padding: SkotiqTokens.dialogPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                      _description(status, hostLink, unansweredSeconds),
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
          if (hostLink != null) ...[
            if (linkedLaunch?.name != null &&
                linkedLaunch!.name != hostLink.serverHost)
              _row(theme, colors, 'Computer', linkedLaunch.name!),
            _row(theme, colors, 'Host', hostLink.serverHost),
            _row(theme, colors, 'Port', hostLink.serverPort.toString()),
          ],
          if (latency != null && status == RemoteConnectionStatus.connected)
            _row(
              theme,
              colors,
              'Latency',
              '${(latency.inMicroseconds / 1000.0).round()} ms',
            ),
          const SizedBox(height: 16),
          if (hostLink != null && status != RemoteConnectionStatus.notConnected)
            SizedBox(
              width: double.infinity,
              child: SkotiqButton(
                onPressed: _reconnecting ? null : _handleReconnect,
                icon: LucideIcons.refreshCw,
                label: _reconnecting ? 'Reconnecting...' : 'Reconnect now',
              ),
            ),
          // A desktop LAUNCHED linked cannot drop to "no backend" and be useful:
          // its role is fixed for the life of the process. Its way out is to
          // restart as this computer's own host, and its way in to the link's
          // settings is the Remote access page.
          if (linkedLaunch != null && canSwitch) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: SkotiqButton(
                  key: const ValueKey('connectionSheet.manageLink'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    GoRouter.maybeOf(context)
                        ?.goToSettings(SettingsSectionId.remoteAccess);
                  },
                  icon: LucideIcons.settings2,
                  label: 'Manage link',
                  variant: ButtonVariant.secondary,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: SkotiqButton(
                  key: const ValueKey('connectionSheet.useThisComputer'),
                  onPressed: () => useThisComputerInstead(
                    context,
                    ref,
                    rigName: linkedLaunch.name,
                  ),
                  icon: LucideIcons.monitor,
                  label: 'Use this computer instead',
                  variant: ButtonVariant.ghost,
                ),
              ),
            ),
          ] else if (hostLink == null && !activeBackend.hasNoHost && canSwitch)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: SkotiqButton(
                  key: const ValueKey('connectionSheet.connectRig'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    showLinkRigDialog(context);
                  },
                  icon: LucideIcons.link,
                  label: 'Connect to an imaging computer',
                  variant: ButtonVariant.secondary,
                ),
              ),
            ),
          if (hostLink != null &&
              linkedLaunch == null &&
              (status == RemoteConnectionStatus.connected ||
                  status == RemoteConnectionStatus.notAnswering))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: SkotiqButton(
                  onPressed: _disconnecting ? null : _handleDisconnect,
                  icon: LucideIcons.logOut,
                  label: _disconnecting ? 'Disconnecting...' : 'Disconnect',
                  variant: ButtonVariant.destructive,
                ),
              ),
            ),
          // Sharing the session is an action ON this connection, so it lives
          // on the control that owns the connection. It used to be a separate
          // glyph in the status bar, which is now status and only status.
          if (ref.watch(webServerStateProvider).isRunning)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: SkotiqButton(
                  onPressed: () => showShareSessionDialog(context),
                  icon: SkotiqIcons.share,
                  label: 'Share this session',
                  variant: ButtonVariant.outline,
                ),
              ),
            ),
          // With no backend at all this sheet had no action whatsoever — it
          // stated "Not connected to a server" and stopped, which on the
          // desktop that owns the hardware was the dead end one failed
          // "Connect to Server" left behind. Same recovery the shell banner
          // and Settings > Connection offer, on the surface the title-bar
          // indicator opens.
          //
          // Gated on the backend TYPE, not on `status`: a local FFI desktop is
          // also "notConnected" to a server, and offering it a way to local
          // mode it is already in would be a control that does nothing.
          if (activeBackend.hasNoHost && canWorkLocally)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: WorkLocallyButton(
                icon: LucideIcons.hardDrive,
                fullWidth: true,
              ),
            ),
          // A local desktop reaches none of the branches above, and the sheet
          // then held no control at all — an operator who opened it had to
          // guess that Escape or the barrier was the way out.
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: SkotiqButton(
                onPressed: () => Navigator.of(context).pop(),
                label: 'Close',
                variant: ButtonVariant.ghost,
              ),
            ),
          ),
        ],
      ),
    );
  }

  RemoteConnectionStatus _statusForConnectionState(
    BackendConnectionState state,
  ) {
    switch (state) {
      case BackendConnectionState.connected:
        return RemoteConnectionStatus.connected;
      case BackendConnectionState.connecting:
        return RemoteConnectionStatus.connecting;
      case BackendConnectionState.reconnecting:
        return RemoteConnectionStatus.reconnecting;
      case BackendConnectionState.disconnected:
        return RemoteConnectionStatus.serverOffline;
      case BackendConnectionState.error:
        return RemoteConnectionStatus.error;
    }
  }

  Widget _row(
    ThemeData theme,
    SkotiqColors colors,
    String label,
    String value,
  ) {
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

  IconData _headerIcon(RemoteConnectionStatus status) {
    switch (status) {
      case RemoteConnectionStatus.connected:
        return LucideIcons.checkCircle;
      case RemoteConnectionStatus.notAnswering:
        return LucideIcons.clock;
      case RemoteConnectionStatus.connecting:
      case RemoteConnectionStatus.reconnecting:
        return LucideIcons.loader;
      case RemoteConnectionStatus.serverOffline:
        return LucideIcons.serverOff;
      case RemoteConnectionStatus.error:
        return LucideIcons.alertTriangle;
      case RemoteConnectionStatus.notConnected:
        return LucideIcons.xCircle;
    }
  }

  Color _headerColor(BuildContext context, RemoteConnectionStatus status) {
    final theme = Theme.of(context);
    final colors = theme.extension<SkotiqColors>();
    switch (status) {
      case RemoteConnectionStatus.connected:
        return colors?.success ?? theme.colorScheme.primary;
      case RemoteConnectionStatus.notAnswering:
      case RemoteConnectionStatus.connecting:
      case RemoteConnectionStatus.reconnecting:
        return colors?.warning ?? theme.colorScheme.secondary;
      case RemoteConnectionStatus.serverOffline:
      case RemoteConnectionStatus.error:
        return colors?.error ?? theme.colorScheme.error;
      case RemoteConnectionStatus.notConnected:
        return colors?.textMuted ?? theme.colorScheme.onSurfaceVariant;
    }
  }

  String _description(
    RemoteConnectionStatus status,
    HostLink? hostLink,
    int? unansweredSeconds,
  ) {
    switch (status) {
      case RemoteConnectionStatus.connected:
        return 'Connected to ${hostLink?.serverHost ?? "server"}';
      case RemoteConnectionStatus.notAnswering:
        return '${hostLink?.serverHost ?? "The host"} has not answered for '
            '${unansweredSeconds ?? 0} s. What this screen shows may be out '
            'of date until it answers again.';
      case RemoteConnectionStatus.connecting:
        return 'Connecting to ${hostLink?.serverHost ?? "server"}...';
      case RemoteConnectionStatus.reconnecting:
        return 'Attempting to reconnect...';
      case RemoteConnectionStatus.serverOffline:
        return 'The server stopped responding. Tap Reconnect to retry.';
      case RemoteConnectionStatus.error:
        return 'The server rejected the connection (e.g. version mismatch). '
            'Check the server logs and upgrade if needed.';
      case RemoteConnectionStatus.notConnected:
        return 'Not connected to a server';
    }
  }
}

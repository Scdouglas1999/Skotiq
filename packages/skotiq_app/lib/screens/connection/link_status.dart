import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The state of this app's link to an imaging host, as every connection
/// surface shows it.
///
/// `connecting` is separate from `reconnecting` so the first handshake says
/// "Connecting" rather than "Reconnecting", which implies an earlier session.
enum RemoteConnectionStatus {
  connected,

  /// The socket is open but the host has left a heartbeat unanswered for at
  /// least `hostAnswerStaleAfter`: what the screen shows may be out of date.
  notAnswering,
  connecting,
  reconnecting,
  serverOffline,
  error,
  notConnected,

  /// Not linked: the phone runs the demo rig, simulated equipment inside
  /// the app. Shown as a labeled badge everywhere, so a screenshot or a demo
  /// is never taken for a real rig.
  demoRig,
}

/// The link status from what the app knows about its link.
///
/// [linkState] is the host link's socket state, null when there is no link.
/// [linkedLaunch] is a launch linked to a host whose link is not up yet: it
/// is linked, and the host is unreachable.
RemoteConnectionStatus linkStatusFor({
  required BackendConnectionState? linkState,
  required int? unansweredSeconds,
  required HostPlace hostPlace,
  required bool linkedLaunch,
}) {
  if (linkState == null) {
    if (hostPlace == HostPlace.demo) return RemoteConnectionStatus.demoRig;
    return linkedLaunch
        ? RemoteConnectionStatus.serverOffline
        : RemoteConnectionStatus.notConnected;
  }
  switch (linkState) {
    case BackendConnectionState.connected:
      return unansweredSeconds == null
          ? RemoteConnectionStatus.connected
          : RemoteConnectionStatus.notAnswering;
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

enum _Tone { success, warning, error, muted, info }

/// How a [RemoteConnectionStatus] looks: its tone, the status chip's icon,
/// the details sheet's header icon, the chip's short label and the label of
/// the Settings > Connection status row.
class LinkStatusLook {
  const LinkStatusLook._(
    this._tone,
    this.chipIcon,
    this.headerIcon,
    this._chipLabel,
    this.settingsLabel,
  );

  final _Tone _tone;
  final IconData chipIcon;
  final IconData headerIcon;
  final String _chipLabel;
  final String settingsLabel;

  static LinkStatusLook of(RemoteConnectionStatus status) => _looks[status]!;

  Color color(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<SkotiqColors>();
    return switch (_tone) {
      _Tone.success => colors?.success ?? theme.colorScheme.primary,
      _Tone.warning => colors?.warning ?? theme.colorScheme.secondary,
      _Tone.error => colors?.error ?? theme.colorScheme.error,
      _Tone.muted => colors?.textMuted ?? theme.colorScheme.onSurfaceVariant,
      _Tone.info => colors?.info ?? theme.colorScheme.tertiary,
    };
  }

  /// The chip's label; a host not answering names how long it has been.
  String chipLabel(int? unansweredSeconds) =>
      _chipLabel.replaceFirst('{s}', '${unansweredSeconds ?? 0}');
}

// Standalone (notConnected) is the normal state of a local install, not a
// fault: its chip is a plain link (tap to link to an imaging host), never a
// crossed-out network.
const _looks = <RemoteConnectionStatus, LinkStatusLook>{
  RemoteConnectionStatus.connected: LinkStatusLook._(_Tone.success,
      LucideIcons.wifi, LucideIcons.checkCircle, 'Live', 'Connected'),
  RemoteConnectionStatus.notAnswering: LinkStatusLook._(
      _Tone.warning,
      LucideIcons.clock,
      LucideIcons.clock,
      'No answer for {s} s',
      'Not answering'),
  RemoteConnectionStatus.connecting: LinkStatusLook._(
      _Tone.warning,
      LucideIcons.refreshCw,
      LucideIcons.loader,
      'Connecting...',
      'Connecting...'),
  RemoteConnectionStatus.reconnecting: LinkStatusLook._(
      _Tone.warning,
      LucideIcons.refreshCw,
      LucideIcons.loader,
      'Reconnecting...',
      'Reconnecting...'),
  RemoteConnectionStatus.serverOffline: LinkStatusLook._(
      _Tone.error,
      LucideIcons.serverOff,
      LucideIcons.serverOff,
      'Server unreachable',
      'Server unreachable'),
  RemoteConnectionStatus.error: LinkStatusLook._(
      _Tone.error,
      LucideIcons.alertTriangle,
      LucideIcons.alertTriangle,
      'Connection error',
      'Connection error'),
  RemoteConnectionStatus.notConnected: LinkStatusLook._(_Tone.muted,
      LucideIcons.link, LucideIcons.xCircle, 'Not connected', 'Disconnected'),
  RemoteConnectionStatus.demoRig: LinkStatusLook._(
      _Tone.info,
      LucideIcons.flaskConical,
      LucideIcons.flaskConical,
      'Demo rig',
      'Demo rig'),
};

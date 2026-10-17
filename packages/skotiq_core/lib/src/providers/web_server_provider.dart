import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// TailnetDetector is the single source of truth for recognising a Tailscale
// tailnet interface address (100.64.0.0/10 or fd7a:115c::/32), shared with the
// QR/pairing validator and the NetworkBackend timeout tuning so the three
// never drift.
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show TailnetDetector;

/// Holds runtime state for the embedded web server.
///
/// This is separate from persisted AppSettings because it tracks
/// transient runtime info like whether the server is actually running,
/// the actual port (which may differ if the configured port was busy),
/// the local network IP, and the collaboration viewer count.
class WebServerState {
  final bool isRunning;
  final int configuredPort;
  final int actualPort;
  final String localIp;

  /// Co-imaging participants in the live collaboration session.
  ///
  /// NOT the number of remote clients attached to this server — a phone that
  /// holds an authenticated `/events` socket open all night never joins a
  /// collaboration session and is not counted here. See [connectedClients].
  final int activeViewers;

  /// Remote clients currently holding an open event socket on this server.
  ///
  /// This is the number the Remote Access page and the status-bar share chip
  /// mean by "connected": phones, tablets and dashboard browsers.
  final int connectedClients;

  final bool bindLocalOnly;
  final bool requiresAuthentication;
  final bool dashboardAvailable;
  final String lastError;
  final String serverFingerprint;

  /// The server's Tailscale tailnet IPv4/IPv6 address (`100.x.y.z` /
  /// `fd7a:115c::…`), or `''` if no tailnet interface is present.
  ///
  /// Fail-closed: defaults to empty and is only populated when an interface
  /// address positively classifies as a Tailscale address via
  /// [TailnetDetector.isTailscaleInterfaceAddress]. We never guess — if no
  /// tailnet interface is up, this stays empty and [tailscaleReachable] stays
  /// false, so the UI shows "not reachable over Tailscale" rather than
  /// advertising a stale/guessed address the phone can't actually reach.
  final String tailscaleIp;

  /// Whether the server currently believes it is reachable over a Tailscale
  /// tailnet — i.e. a tailnet interface address was detected AND the server is
  /// not bound loopback-only (a loopback-only bind isn't reachable from any
  /// other device regardless of the interface).
  ///
  /// Fail-closed: defaults to false. This is the value the operator UI should
  /// gate a "generate Tailscale QR" action on; it must be a positive,
  /// evidence-backed signal, never an optimistic default.
  final bool tailscaleReachable;

  const WebServerState({
    this.isRunning = false,
    this.configuredPort = 8080,
    this.actualPort = 8080,
    this.localIp = '',
    this.activeViewers = 0,
    this.connectedClients = 0,
    this.bindLocalOnly = true,
    this.requiresAuthentication = false,
    this.dashboardAvailable = false,
    this.lastError = '',
    this.serverFingerprint = '',
    this.tailscaleIp = '',
    this.tailscaleReachable = false,
  });

  /// Path the dashboard SPA is served from.
  ///
  /// These URLs are opened in a BROWSER and copied for humans (the Remote
  /// Access settings cards, the status-bar dashboard button, session sharing),
  /// so they must land on the dashboard itself: `/` is not a routed page and
  /// the auth middleware answers it with raw `401` JSON.
  ///
  /// The pairing QR is unaffected; it builds a structured host+port payload of
  /// its own rather than reusing these strings.
  static const String dashboardPath = '/dashboard';

  /// The URL for accessing the web dashboard from the local machine.
  String get localUrl => 'http://localhost:$actualPort$dashboardPath';

  /// The URL for accessing the web dashboard from other devices on the network.
  String get networkUrl => !bindLocalOnly && localIp.isNotEmpty
      ? 'http://$localIp:$actualPort$dashboardPath'
      : '';

  /// The URL for accessing the web dashboard over the Tailscale tailnet, or
  /// `''` when not reachable that way. An IPv6 tailnet literal is bracketed so
  /// the resulting URL is well-formed (`http://[fd7a:115c::1]:8080`).
  ///
  /// Fail-closed: empty unless [tailscaleReachable] is true and a tailnet
  /// address is known — mirrors [networkUrl]'s "only when actually reachable"
  /// contract so the UI never renders a link to an unreachable host.
  String get tailscaleUrl {
    if (!tailscaleReachable || tailscaleIp.isEmpty) {
      return '';
    }
    final hostPart = tailscaleIp.contains(':') ? '[$tailscaleIp]' : tailscaleIp;
    return 'http://$hostPart:$actualPort$dashboardPath';
  }

  WebServerState copyWith({
    bool? isRunning,
    int? configuredPort,
    int? actualPort,
    String? localIp,
    int? activeViewers,
    int? connectedClients,
    bool? bindLocalOnly,
    bool? requiresAuthentication,
    bool? dashboardAvailable,
    String? lastError,
    String? serverFingerprint,
    String? tailscaleIp,
    bool? tailscaleReachable,
  }) {
    return WebServerState(
      isRunning: isRunning ?? this.isRunning,
      configuredPort: configuredPort ?? this.configuredPort,
      actualPort: actualPort ?? this.actualPort,
      localIp: localIp ?? this.localIp,
      activeViewers: activeViewers ?? this.activeViewers,
      connectedClients: connectedClients ?? this.connectedClients,
      bindLocalOnly: bindLocalOnly ?? this.bindLocalOnly,
      requiresAuthentication:
          requiresAuthentication ?? this.requiresAuthentication,
      dashboardAvailable: dashboardAvailable ?? this.dashboardAvailable,
      lastError: lastError ?? this.lastError,
      serverFingerprint: serverFingerprint ?? this.serverFingerprint,
      tailscaleIp: tailscaleIp ?? this.tailscaleIp,
      tailscaleReachable: tailscaleReachable ?? this.tailscaleReachable,
    );
  }
}

/// Notifier for web server runtime state.
///
/// The desktop main.dart should call [setRunning] after starting the web server,
/// and update viewer counts from the collaboration session manager.
class WebServerStateNotifier extends StateNotifier<WebServerState> {
  WebServerStateNotifier() : super(const WebServerState()) {
    _resolveLocalIp();
  }

  void setRunning({
    required bool isRunning,
    required int actualPort,
    int? configuredPort,
    bool? bindLocalOnly,
    bool? requiresAuthentication,
    bool? dashboardAvailable,
    String? lastError,
    String? serverFingerprint,
  }) {
    state = state.copyWith(
      isRunning: isRunning,
      actualPort: actualPort,
      configuredPort: configuredPort ?? state.configuredPort,
      bindLocalOnly: bindLocalOnly ?? state.bindLocalOnly,
      requiresAuthentication:
          requiresAuthentication ?? state.requiresAuthentication,
      dashboardAvailable: dashboardAvailable ?? state.dashboardAvailable,
      lastError: lastError ?? '',
      serverFingerprint: serverFingerprint ?? state.serverFingerprint,
    );
    if (isRunning) {
      unawaited(_resolveLocalIp());
    }
  }

  void setStopped({
    int? configuredPort,
    int? actualPort,
    bool? bindLocalOnly,
    bool? requiresAuthentication,
    bool? dashboardAvailable,
    String? lastError,
  }) {
    state = state.copyWith(
      isRunning: false,
      actualPort: actualPort ?? state.actualPort,
      configuredPort: configuredPort ?? state.configuredPort,
      bindLocalOnly: bindLocalOnly ?? state.bindLocalOnly,
      requiresAuthentication:
          requiresAuthentication ?? state.requiresAuthentication,
      dashboardAvailable: dashboardAvailable ?? state.dashboardAvailable,
      activeViewers: 0,
      // A stopped server holds no sockets; leaving the last count would keep
      // the share chip claiming connected clients after shutdown.
      connectedClients: 0,
      lastError: lastError ?? '',
    );
  }

  void setActiveViewers(int count) {
    state = state.copyWith(activeViewers: count);
  }

  void setConnectedClients(int count) {
    state = state.copyWith(connectedClients: count);
  }

  void setConfiguredPort(int port) {
    state = state.copyWith(configuredPort: port);
  }

  /// Enumerate interface addresses and resolve, in one pass:
  ///   * [WebServerState.localIp] — the first non-loopback **non-tailnet**
  ///     IPv4 address (the LAN NIC). Tailnet addresses are skipped: on a
  ///     Tailscale-enabled host the first non-loopback IPv4 is
  ///     non-deterministic between the LAN NIC and the `100.x` tailnet
  ///     address, which phones on the LAN cannot necessarily reach.
  ///   * [WebServerState.tailscaleIp] — the tailnet address (IPv4 CGNAT
  ///     preferred over IPv6 ULA for QR brevity), classified by
  ///     [TailnetDetector.isTailscaleInterfaceAddress].
  ///   * [WebServerState.tailscaleReachable] — true iff a tailnet address was
  ///     found AND the server isn't bound loopback-only.
  ///
  /// Fail-closed: if enumeration throws or finds no tailnet interface, the
  /// tailnet fields collapse to `('', false)` rather than retaining a stale
  /// value, so the UI can never advertise a tailnet host that is no longer up.
  Future<void> _resolveLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(includeLoopback: false);

      String? lanIp;
      String? tailscaleV4;
      String? tailscaleV6;

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.isLoopback) {
            continue;
          }
          final isTailnet = TailnetDetector.isTailscaleInterfaceAddress(addr);
          if (isTailnet) {
            if (addr.type == InternetAddressType.IPv4) {
              tailscaleV4 ??= addr.address;
            } else if (addr.type == InternetAddressType.IPv6) {
              tailscaleV6 ??= addr.address;
            }
            continue;
          }
          // First non-loopback, non-tailnet IPv4 is the LAN address. IPv6 LAN
          // addresses are not used for `localIp` (the legacy networkUrl getter
          // assumes a bare IPv4 host) — only the tailnet IPv6 ULA is surfaced,
          // and tailscaleUrl brackets it.
          if (addr.type == InternetAddressType.IPv4) {
            lanIp ??= addr.address;
          }
        }
      }

      final tailscaleIp = tailscaleV4 ?? tailscaleV6 ?? '';
      final tailscaleReachable = tailscaleIp.isNotEmpty && !state.bindLocalOnly;

      state = state.copyWith(
        localIp: lanIp ?? '',
        tailscaleIp: tailscaleIp,
        tailscaleReachable: tailscaleReachable,
      );
    } catch (_) {
      // Network interface enumeration is best-effort. Fail closed on the
      // tailnet signal so a transient enumeration error never leaves a stale
      // "reachable over Tailscale" claim standing.
      state = state.copyWith(tailscaleIp: '', tailscaleReachable: false);
    }
  }
}

final webServerStateProvider =
    StateNotifierProvider<WebServerStateNotifier, WebServerState>(
      (ref) => WebServerStateNotifier(),
    );

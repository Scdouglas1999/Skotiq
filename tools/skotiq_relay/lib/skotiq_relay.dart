/// Skotiq relay — zero-config remote access beyond the LAN.
///
/// Three pieces share this package so the wire protocol can never drift:
///   * [RelayServer]       — the self-hostable relay (see bin/relay.dart)
///   * [RelayUplink]       — appliance side: outbound WS + local proxying
///   * [RelayTunnelClient] — phone side: relay tunnel as a loopback port
///
/// Pure Dart (dart:io only + `crypto`); no Flutter. The Flutter apps consume
/// the client classes through the `skotiq_remote_protocol` re-export.
library;

export 'src/mux/frame.dart';
export 'src/mux/mux_session.dart';
export 'src/relay_credentials.dart';
export 'src/relay_server.dart';
export 'src/relay_tunnel_client.dart';
export 'src/relay_uplink.dart';
export 'src/socket_bridge.dart';
